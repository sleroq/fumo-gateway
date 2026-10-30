const std = @import("std");
const auth = @import("auth.zig");
pub const Config = @import("config.zig").Config;
const inference = @import("inference.zig");
const Registry = @import("provider.zig").Registry;
const Protocol = @import("provider.zig").Protocol;

const Route = enum { health, models, responses, chat_completions, unknown };
const routes = std.StaticStringMap(Route).initComptime(.{
    .{ "/healthz", .health },
    .{ "/v1/models", .models },
    .{ "/v1/responses", .responses },
    .{ "/v1/chat/completions", .chat_completions },
});

const max_connections = 64;
const request_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

/// The caller owns Config. Provider storage never moves after requests begin.
/// Shutdown joins requests first, then HTTP connections, then credential workers
/// and model caches; only afterward may the caller release configuration.
pub fn serve(allocator: std.mem.Allocator, io: std.Io, config: *const Config) !void {
    var providers = try Registry.init(allocator, io, config.upstreams);
    defer providers.deinit();

    var listener = try config.address.listen(io, .{});
    defer listener.deinit(io);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var active: std.atomic.Value(usize) = .init(0);
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    std.log.info("event=listening address={f}", .{config.address});

    while (true) {
        const stream = try listener.accept(io);
        if (active.fetchAdd(1, .monotonic) >= max_connections) {
            _ = active.fetchSub(1, .monotonic);
            stream.close(io);
            continue;
        }
        const deadline = std.Io.Clock.Timestamp.fromNow(io, request_timeout);
        connections.concurrent(io, handleConnection, .{ allocator, &client, stream, config, &providers, &active, deadline }) catch |err| {
            stream.close(io);
            _ = active.fetchSub(1, .monotonic);
            std.log.warn("event=connection_dispatch_failed error={s}", .{@errorName(err)});
        };
    }
}

const Action = union(enum) {
    inference: inference.Pending,
    models: struct { request: std.http.Server.Request, client: []const u8 },
};

fn handleConnection(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    stream: std.Io.net.Stream,
    config: *const Config,
    providers: *Registry,
    active: *std.atomic.Value(usize),
    deadline: std.Io.Clock.Timestamp,
) void {
    const io = client.io;
    defer _ = active.fetchSub(1, .monotonic);
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var action = (prepareRequestWithDeadline(io, allocator, arena.allocator(), &http, config, deadline) catch |err| {
        std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
        return;
    }) orelse return;

    switch (action) {
        .models => |*pending| {
            const body = providers.modelList(client, arena.allocator()) catch |err| {
                if (err == error.Canceled) return;
                std.log.warn("event=model_list_failed error={s}", .{@errorName(err)});
                respond(&pending.request, .bad_gateway, "{\"error\":\"model_discovery_unavailable\"}\n", pending.client) catch {};
                return;
            };
            respond(&pending.request, .ok, body, pending.client) catch {};
        },
        .inference => |*pending| {
            pending.authorization = providers.entries[pending.upstream].authorization(arena.allocator()) catch |err| {
                std.log.warn("event=upstream_credentials_unavailable error={s}", .{@errorName(err)});
                respond(&pending.request, .service_unavailable, "{\"error\":\"upstream_credentials_unavailable\"}\n", pending.client) catch {};
                return;
            };
            const status = inference.forward(client, arena.allocator(), stream, pending) catch |err| {
                std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
                return;
            };
            logRequest(status, pending.client);
        },
    }
}

fn prepareRequestWithDeadline(
    io: std.Io,
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    http: *std.http.Server,
    config: *const Config,
    deadline: std.Io.Clock.Timestamp,
) !?Action {
    var completed: std.Io.Semaphore = .{};
    var task = try io.concurrent(prepareRequest, .{ io, gpa, allocator, http, config, &completed });
    // Only request reception is timed; discovery has its own bounded exchange
    // and long-lived inference streams are not cut off.
    defer _ = task.cancel(io) catch null;
    try completed.waitTimeout(io, .{ .deadline = deadline });
    return try task.await(io);
}

fn prepareRequest(io: std.Io, gpa: std.mem.Allocator, allocator: std.mem.Allocator, http: *std.http.Server, config: *const Config, completed: *std.Io.Semaphore) !?Action {
    defer completed.post(io);

    var request = try http.receiveHead();
    const path = request.head.target[0 .. std.mem.findScalar(u8, request.head.target, '?') orelse request.head.target.len];
    const client = if (std.mem.startsWith(u8, path, "/v1/") or std.mem.eql(u8, path, "/v1"))
        auth.authenticate(config.clients, authorizationHeader(&request))
    else
        null;
    if ((std.mem.startsWith(u8, path, "/v1/") or std.mem.eql(u8, path, "/v1")) and client == null) {
        try respond(&request, .unauthorized, "{\"error\":\"unauthorized\"}\n", null);
        return null;
    }

    switch (routes.get(path) orelse .unknown) {
        .health => if (request.head.method == .GET) {
            try respond(&request, .ok, "{\"status\":\"ok\"}\n", null);
            return null;
        },
        .models => if (request.head.method == .GET) {
            return .{ .models = .{ .request = request, .client = client.? } };
        },
        .responses, .chat_completions => |route| if (request.head.method == .POST) {
            const protocol: Protocol = if (route == .responses) .responses else .chat_completions;
            const pending = inference.prepare(gpa, allocator, &request, config.upstreams, protocol, client.?) catch |err| {
                const status: std.http.Status, const body: []const u8 = switch (err) {
                    error.InvalidRequest => .{ .bad_request, "{\"error\":\"invalid_request\"}\n" },
                    error.UnknownUpstream => .{ .bad_request, "{\"error\":\"unknown_upstream\"}\n" },
                    error.StreamTooLong => .{ .payload_too_large, "{\"error\":\"request_too_large\"}\n" },
                    error.HttpExpectationFailed => .{ .expectation_failed, "{\"error\":\"unsupported_expectation\"}\n" },
                    else => return err,
                };
                try respond(&request, status, body, client);
                return null;
            };
            return .{ .inference = pending };
        },
        .unknown => {},
    }
    try respond(&request, .not_found, "{\"error\":\"not_found\"}\n", client);
    return null;
}

fn respond(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, client: ?[]const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "www-authenticate", .value = "Bearer" },
    };
    // Never invite or read a body for a completed local response.
    request.head.expect = null;
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = if (status == .unauthorized) &headers else headers[0..1],
    });
    logRequest(status, client);
}

fn logRequest(status: std.http.Status, client: ?[]const u8) void {
    std.log.info("event=request status={d} client={f}", .{ @backingInt(status), std.json.fmt(client, .{}) });
}

fn authorizationHeader(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    var value: ?[]const u8 = null;

    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            if (value != null) return null;
            value = header.value;
        }
    }

    return value;
}

test "HTTP health, authentication, and routing" {
    const cases = .{
        .{ "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n", "200 OK", "\"status\":\"ok\"" },
        .{ "POST /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "POST /v1/responses HTTP/1.1\r\nContent-Length: 1000000\r\nExpect: 100-continue\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer wrong\r\nContent-Length: 1000000\r\nExpect: 100-continue\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "POST /v1/responses HTTP/1.1\r\nExpect: unsupported\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer first-secret\r\nContent-Length: 2\r\n\r\n{}", "400 Bad Request", "invalid_request" },
        .{ "POST /v1/models HTTP/1.1\r\nAuthorization: Bearer first-secret\r\n\r\n", "404 Not Found", "not_found" },
        .{ "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer first-secret\r\n\r\n", "404 Not Found", "not_found" },
        .{ "POST /v1/models/model:generateContent HTTP/1.1\r\nAuthorization: Bearer first-secret\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /unknown?limit=1 HTTP/1.1\r\naUtHoRiZaTiOn: bearer second-secret\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1 HTTP/1.1\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "GET /unknown HTTP/1.1\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer first-secret\r\nAuthorization: Bearer second-secret\r\n\r\n", "401 Unauthorized", "unauthorized" },
    };
    const clients = [_]auth.Client{ auth.Client.init("pi", "first-secret"), auth.Client.init("dev", "second-secret") };
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{} };
    inline for (cases) |case| {
        var reader = std.Io.Reader.fixed(case[0]);
        var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer writer.deinit();
        var http = std.http.Server.init(&reader, &writer.writer);
        var completed: std.Io.Semaphore = .{};
        _ = try prepareRequest(std.testing.io, std.testing.allocator, std.testing.allocator, &http, &config, &completed);
        const response = writer.written();
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 " ++ case[1]));
        try std.testing.expect(std.mem.find(u8, response, "100 Continue") == null);
        try std.testing.expect(std.mem.find(u8, response, case[2]) != null);
        try std.testing.expect(std.mem.find(u8, response, "connection: close\r\n") != null);
        try std.testing.expect(std.mem.find(u8, response, "first-secret") == null);
        try std.testing.expect(std.mem.find(u8, response, "second-secret") == null);
    }
}

const TransportTest = struct {
    const fixture = @import("fixture");
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const payload = "{\"model\":\"test/demo\",\"stream\":true,\"opaque\":{\"nested\":[1,null,true]}}";
    const first = "data: {\"delta\":\"first\"}\n\n";

    fn connect(upstream_client: *std.http.Client, config: *const Config, active: *std.atomic.Value(usize), tasks: *std.Io.Group) !std.Io.net.Stream {
        return connectWithRegistry(upstream_client, config, null, active, tasks);
    }

    fn connectWithRegistry(upstream_client: *std.http.Client, config: *const Config, registry: ?*Registry, active: *std.atomic.Value(usize), tasks: *std.Io.Group) !std.Io.net.Stream {
        var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
        defer listener.deinit(io);
        const client = try listener.socket.address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        const accepted = try listener.accept(io);
        errdefer accepted.close(io);
        _ = active.fetchAdd(1, .monotonic);
        try tasks.concurrent(io, handle, .{ upstream_client, accepted, config, registry, active });
        return client;
    }

    fn handle(client: *std.http.Client, stream: std.Io.net.Stream, config: *const Config, registry: ?*Registry, active: *std.atomic.Value(usize)) void {
        if (registry) |providers| {
            handleConnection(allocator, client, stream, config, providers, active, std.Io.Clock.Timestamp.fromNow(io, request_timeout));
        } else {
            var providers = Registry.init(allocator, io, config.upstreams) catch unreachable;
            defer providers.deinit();
            handleConnection(allocator, client, stream, config, &providers, active, std.Io.Clock.Timestamp.fromNow(io, request_timeout));
        }
    }

    fn exchange(upstream_client: *std.http.Client, config: *const Config, registry: *Registry, raw: []const u8) ![]u8 {
        var active: std.atomic.Value(usize) = .init(0);
        var tasks: std.Io.Group = .init;
        defer tasks.cancel(io);
        const client = try connectWithRegistry(upstream_client, config, registry, &active, &tasks);
        defer client.close(io);
        var buffer: [1024]u8 = undefined;
        var writer = client.writer(io, &buffer);
        try writer.interface.writeAll(raw);
        try writer.interface.flush();
        const result = try receive(client);
        errdefer allocator.free(result);
        try tasks.await(io);
        try std.testing.expectEqual(0, active.load(.monotonic));
        return result;
    }

    fn reset(client: std.Io.net.Stream) !void {
        const linger: std.posix.linger = .{ .onoff = 1, .linger = 0 };
        try std.posix.setsockopt(client.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger));
        client.close(io);
    }

    fn send(client: std.Io.net.Stream, chunked: bool) !void {
        var buffer: [1024]u8 = undefined;
        var writer = client.writer(io, &buffer);
        try writer.interface.writeAll("POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer transport-secret\r\nX-Api-Key: private\r\nApi-Key: private\r\nProxy-Authorization: private\r\nCookie: private\r\nSession_id: forward-me\r\nContent-Type: application/json\r\n");
        if (chunked) {
            try writer.interface.print("Transfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ payload.len, payload });
        } else {
            try writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
        }
        try writer.interface.flush();
    }

    fn read(client: std.Io.net.Stream, completed: *std.Io.Semaphore) ![]u8 {
        defer completed.post(io);
        var buffer: [4096]u8 = undefined;
        var reader = client.reader(io, &buffer);
        return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    }

    fn receive(client: std.Io.net.Stream) ![]u8 {
        var completed: std.Io.Semaphore = .{};
        var task = try io.concurrent(read, .{ client, &completed });
        defer _ = task.cancel(io) catch {};
        try completed.waitTimeout(io, .{ .duration = request_timeout });
        return try task.await(io);
    }

    fn prefix(client: std.Io.net.Stream, completed: *std.Io.Semaphore) !void {
        defer completed.post(io);
        var buffer: [4096]u8 = undefined;
        var reader = client.reader(io, &buffer);
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        defer bytes.deinit();
        while (std.mem.find(u8, bytes.written(), first) == null) try bytes.writer.writeByte(try reader.interface.takeByte());
    }
};

test "transport rejects deeply nested JSON without forwarding and serves the next request" {
    const T = TransportTest;
    var upstream_client: std.http.Client = .{ .allocator = T.allocator, .io = T.io };
    defer upstream_client.deinit();
    var fixture = try T.fixture.Fixture.init(T.allocator, T.io, &.{
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .reuse = true },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .peer_eof = true },
    });
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(T.allocator);
    defer T.allocator.free(origin);
    var upstream: @import("config.zig").Upstream = .{ .name = "test", .base_url = origin };
    defer upstream.aliases.deinit(T.allocator);
    try upstream.aliases.map.put(T.allocator, "demo", "fixture-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
    var active: std.atomic.Value(usize) = .init(0);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(T.io);
    var payload: std.Io.Writer.Allocating = .init(T.allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"model\":\"test/demo\",\"input\":");
    try payload.writer.splatByteAll('[', 300);
    try payload.writer.writeAll("null");
    try payload.writer.splatByteAll(']', 300);
    try payload.writer.writeAll("}");

    for ([_]bool{ false, true }, 0..) |chunked, count| {
        const rejected = try T.connect(&upstream_client, &config, &active, &tasks);
        defer rejected.close(T.io);
        var buffer: [1024]u8 = undefined;
        var writer = rejected.writer(T.io, &buffer);
        try writer.interface.writeAll("POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\n");
        if (chunked) {
            try writer.interface.print("Transfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n", .{ payload.written().len, payload.written() });
        } else {
            try writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ payload.written().len, payload.written() });
        }
        try writer.interface.flush();
        const rejection = try T.receive(rejected);
        defer T.allocator.free(rejection);
        try std.testing.expect(std.mem.startsWith(u8, rejection, "HTTP/1.1 400 Bad Request\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, rejection, "{\"error\":\"invalid_request\"}\n"));
        try std.testing.expectEqual(count, fixture.count.load(.acquire));

        const next = try T.connect(&upstream_client, &config, &active, &tasks);
        defer next.close(T.io);
        try T.send(next, chunked);
        const raw = try T.receive(next);
        defer T.allocator.free(raw);
        try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, raw, "ok"));
        try std.testing.expectEqual(count + 1, fixture.count.load(.acquire));
    }
    try tasks.await(T.io);
    try std.testing.expectEqual(0, active.load(.monotonic));
}

test "transport socket relay preserves payload, isolates headers, and handles response framing without replay" {
    const T = TransportTest;
    var upstream_client: std.http.Client = .{ .allocator = T.allocator, .io = T.io };
    defer upstream_client.deinit();
    const cases = [_]struct { reply: []const u8, status: []const u8, body: []const u8, chunked: bool = false, half_close: bool = false, header: ?[]const u8 = null }{
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nContent-Type: application/json\r\nAuthorization: private\r\nConnection: X-Hop\r\nX-Hop: private\r\n\r\n{\"ok\":true}", .status = "200 OK", .body = "{\"ok\":true}" },
        .{ .reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: X-Hop\r\nX-Hop: private\r\n\r\n5\r\n{\"ok\"\r\n6\r\n:true}\r\n0\r\n\r\n", .status = "200 OK", .body = "{\"ok\":true}", .chunked = true },
        .{ .reply = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 4\r\nRetry-After: 17\r\n\r\nbusy", .status = "429 Too Many Requests", .body = "busy", .header = "retry-after: 17" },
        .{ .reply = "HTTP/1.1 307 Temporary Redirect\r\nContent-Length: 4\r\nLocation: /never-follow\r\n\r\nmove", .status = "307 Temporary Redirect", .body = "move", .header = "location: /never-follow" },
        .{ .reply = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .status = "200 OK", .body = "ok" },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .status = "200 OK", .body = "ok", .half_close = true },
        .{ .reply = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", .status = "502 Bad Gateway", .body = "{\"error\":\"bad_gateway\"}\n" },
        .{ .reply = "not HTTP\r\n\r\n", .status = "502 Bad Gateway", .body = "{\"error\":\"bad_gateway\"}\n" },
        .{ .reply = "HTTP/1.1 204 No Content\r\n\r\n", .status = "204 No Content", .body = "" },
        .{ .reply = "HTTP/1.1 304 Not Modified\r\n\r\n", .status = "304 Not Modified", .body = "" },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 1000\r\n\r\n" ++ T.first, .status = "200 OK", .body = T.first },
    };
    for (cases) |case| {
        var fixture = try T.fixture.Fixture.init(T.allocator, T.io, &.{.{ .bytes = case.reply }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(T.allocator);
        defer T.allocator.free(origin);
        const url = try T.allocator.print("{s}/v1", .{origin});
        defer T.allocator.free(url);
        var upstream: @import("config.zig").Upstream = .{ .name = "test", .base_url = url };
        defer upstream.aliases.deinit(T.allocator);
        try upstream.aliases.map.put(T.allocator, "demo", "fixture-model");
        const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
        const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
        var active: std.atomic.Value(usize) = .init(0);
        var tasks: std.Io.Group = .init;
        defer tasks.cancel(T.io);
        const client = try T.connect(&upstream_client, &config, &active, &tasks);
        defer client.close(T.io);
        try T.send(client, case.chunked);
        if (case.half_close) try client.shutdown(T.io, .send);
        const raw = try T.receive(client);
        defer T.allocator.free(raw);
        try fixture.waitRequest();
        const request = fixture.requests[0].?;
        try std.testing.expect(std.mem.startsWith(u8, request, "POST /v1/responses HTTP/1.1\r\n"));
        try std.testing.expect(std.mem.find(u8, request, "forward-me") != null);
        try std.testing.expect(std.mem.find(u8, request, "private") == null);
        try std.testing.expect(std.mem.find(u8, request, "transport-secret") == null);
        const body = request[(std.mem.find(u8, request, "\r\n\r\n").? + 4)..];
        try std.testing.expectEqualStrings("{\"model\":\"fixture-model\",\"stream\":true,\"opaque\":{\"nested\":[1,null,true]}}", body);
        const head_end = std.mem.find(u8, raw, "\r\n\r\n").?;
        const head_bytes = raw[0..head_end];
        var response_reader = std.Io.Reader.fixed(raw[head_end + 4 ..]);
        try std.testing.expect(std.mem.find(u8, head_bytes, case.status) != null);
        try std.testing.expect(std.mem.find(u8, head_bytes, "private") == null);
        if (case.body.len == 0) try std.testing.expect(std.ascii.findIgnoreCase(head_bytes, "transfer-encoding") == null);
        if (case.header) |header| try std.testing.expect(std.ascii.findIgnoreCase(head_bytes, header) != null);
        // Chunk framing is generated by the gateway; compare decoded body bytes.
        if (std.ascii.findIgnoreCase(head_bytes, "transfer-encoding: chunked") != null) {
            var decoded: std.Io.Writer.Allocating = .init(T.allocator);
            defer decoded.deinit();
            while (true) {
                const line = try response_reader.takeDelimiterInclusive('\n');
                const length = try std.fmt.parseInt(usize, std.mem.trim(u8, line, "\r\n"), 16);
                if (length == 0) break;
                try decoded.writer.writeAll(try response_reader.take(length));
                try response_reader.discardAll(2);
            }
            try std.testing.expectEqualStrings(case.body, decoded.written());
        } else try std.testing.expectEqualStrings(case.body, response_reader.buffered());
        try std.testing.expectEqual(1, fixture.count.load(.acquire));
    }
}

test "transport incremental SSE survives half-close and resets before or after headers close upstream" {
    const T = TransportTest;
    var upstream_client: std.http.Client = .{ .allocator = T.allocator, .io = T.io };
    defer upstream_client.deinit();
    for ([_]enum { complete, half_close_before_head, half_close_after_head, reset_before_head, reset_after_head }{ .complete, .half_close_before_head, .half_close_after_head, .reset_before_head, .reset_after_head }) |mode| {
        const before_head = mode == .half_close_before_head or mode == .reset_before_head;
        const reset = mode == .reset_before_head or mode == .reset_after_head;
        var gate: std.Io.Semaphore = .{};
        const head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
        const tail = "data: [DONE]\n\n";
        var fixture = try T.fixture.Fixture.init(T.allocator, T.io, &.{.{
            .bytes = if (before_head) "" else head ++ T.first,
            .gate = if (reset) null else &gate,
            .tail = if (reset) "" else if (before_head) head ++ T.first ++ tail else tail,
            .peer_eof = reset,
        }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(T.allocator);
        defer T.allocator.free(origin);
        var upstream: @import("config.zig").Upstream = .{ .name = "test", .base_url = origin };
        defer upstream.aliases.deinit(T.allocator);
        try upstream.aliases.map.put(T.allocator, "demo", "fixture-model");
        const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
        const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
        var active: std.atomic.Value(usize) = .init(0);
        var tasks: std.Io.Group = .init;
        defer tasks.cancel(T.io);
        const client = try T.connect(&upstream_client, &config, &active, &tasks);
        var client_open = true;
        defer if (client_open) client.close(T.io);
        try T.send(client, false);
        try fixture.waitRequest();
        if (mode == .half_close_before_head) try client.shutdown(T.io, .send);
        if (!before_head) {
            var completed: std.Io.Semaphore = .{};
            var task = try T.io.concurrent(T.prefix, .{ client, &completed });
            defer _ = task.cancel(T.io) catch {};
            try completed.waitTimeout(T.io, .{ .duration = request_timeout });
            try task.await(T.io);
        }
        if (!reset) {
            if (mode == .half_close_after_head) try client.shutdown(T.io, .send);
            gate.post(T.io);
            const rest = try T.receive(client);
            defer T.allocator.free(rest);
            try std.testing.expect(std.mem.find(u8, rest, tail) != null);
            try std.testing.expect(std.mem.find(u8, rest, "error") == null);
            if (before_head) {
                try std.testing.expect(std.mem.startsWith(u8, rest, "HTTP/1.1 200 OK\r\n"));
                try std.testing.expect(std.mem.find(u8, rest, T.first) != null);
            }
        } else {
            try T.reset(client);
            client_open = false;
            try fixture.waitEof();
        }
        try std.testing.expectEqual(1, fixture.count.load(.acquire));
    }
}

test "transport sequential inferences reuse only complete persistent upstream connections without replay" {
    const T = TransportTest;
    const cases = [_]struct { reply: []const u8, reusable: bool = true }{
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" },
        .{ .reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nX-Trailer: done\r\n\r\n" },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" },
        .{ .reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" },
        .{ .reply = "HTTP/1.1 204 No Content\r\n\r\n" },
        .{ .reply = "HTTP/1.1 304 Not Modified\r\nContent-Length: 123\r\n\r\n" },
        .{ .reply = "HTTP/1.1 307 Temporary Redirect\r\nLocation: /never-follow\r\nContent-Length: 4\r\n\r\nmove" },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok", .reusable = false },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive, cLoSe\r\n\r\nok", .reusable = false },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\nConnection: X-Hop\r\n\r\nok", .reusable = false },
        .{ .reply = "HTTP/1.1 200 OK\r\n\r\nconnection-delimited", .reusable = false },
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort", .reusable = false },
        .{ .reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\ninvalid\r\n", .reusable = false },
        .{ .reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nx", .reusable = false },
    };
    for (cases) |case| {
        var upstream_client: std.http.Client = .{ .allocator = T.allocator, .io = T.io };
        defer upstream_client.deinit();
        var fixture = try T.fixture.Fixture.init(T.allocator, T.io, &.{
            .{ .bytes = case.reply, .reuse = case.reusable },
            .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .peer_eof = true },
        });
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(T.allocator);
        defer T.allocator.free(origin);
        var upstream: @import("config.zig").Upstream = .{ .name = "test", .base_url = origin };
        defer upstream.aliases.deinit(T.allocator);
        try upstream.aliases.map.put(T.allocator, "demo", "fixture-model");
        const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
        const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
        var active: std.atomic.Value(usize) = .init(0);
        var tasks: std.Io.Group = .init;
        defer tasks.cancel(T.io);

        for (0..2) |index| {
            const downstream = try T.connect(&upstream_client, &config, &active, &tasks);
            defer downstream.close(T.io);
            try T.send(downstream, false);
            const raw = try T.receive(downstream);
            defer T.allocator.free(raw);
            try tasks.await(T.io);
            try fixture.waitRequest();
            try std.testing.expectEqual(index + 1, fixture.count.load(.acquire));
            try std.testing.expectEqual(if (case.reusable) 1 else index + 1, fixture.accepted.load(.acquire));
            try std.testing.expectEqual(0, active.load(.monotonic));
            try std.testing.expect(upstream_client.connection_pool.used.first == null);
            try std.testing.expectEqual(@as(usize, if (index == 1 or case.reusable) 1 else 0), upstream_client.connection_pool.free_len);
            if (index == 1) {
                try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
                try std.testing.expect(std.mem.endsWith(u8, raw, "ok"));
            }
        }
    }
}

test "transport an upstream closing an idle pooled socket fails the next inference without replay" {
    const T = TransportTest;
    var upstream_client: std.http.Client = .{ .allocator = T.allocator, .io = T.io };
    defer upstream_client.deinit();
    // Advertise persistence, then close after the complete first response.
    var fixture = try T.fixture.Fixture.init(T.allocator, T.io, &.{.{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(T.allocator);
    defer T.allocator.free(origin);
    var upstream: @import("config.zig").Upstream = .{ .name = "test", .base_url = origin };
    defer upstream.aliases.deinit(T.allocator);
    try upstream.aliases.map.put(T.allocator, "demo", "fixture-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
    var active: std.atomic.Value(usize) = .init(0);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(T.io);

    for (0..2) |index| {
        const downstream = try T.connect(&upstream_client, &config, &active, &tasks);
        defer downstream.close(T.io);
        try T.send(downstream, false);
        const raw = try T.receive(downstream);
        defer T.allocator.free(raw);
        try tasks.await(T.io);
        if (index == 0) {
            try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
            try fixture.waitRequest();
            // Join the fixture to ensure the pooled socket is closed before request two.
            // Its listener stays open; an automatic reconnect/retry would time out.
            try fixture.tasks.await(T.io);
            try std.testing.expectEqual(1, upstream_client.connection_pool.free_len);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 502 Bad Gateway\r\n"));
            try std.testing.expectEqual(0, upstream_client.connection_pool.free_len);
        }
        try std.testing.expectEqual(1, fixture.count.load(.acquire));
        try std.testing.expectEqual(1, fixture.accepted.load(.acquire));
        try std.testing.expect(upstream_client.connection_pool.used.first == null);
    }
}

test "transport shared client isolates concurrent cancellation and remains usable" {
    const T = TransportTest;
    var upstream_client: std.http.Client = .{ .allocator = T.allocator, .io = T.io };
    defer upstream_client.deinit();
    var stalled = try T.fixture.Fixture.init(T.allocator, T.io, &.{.{ .bytes = "", .peer_eof = true }});
    defer stalled.deinit();
    try stalled.start();
    var gate: std.Io.Semaphore = .{};
    const tail = "data: [DONE]\n\n";
    var healthy = try T.fixture.Fixture.init(T.allocator, T.io, &.{
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: " ++ std.fmt.comptimePrint("{d}", .{T.first.len + tail.len}) ++ "\r\n\r\n" ++ T.first, .gate = &gate, .tail = tail, .reuse = true },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .peer_eof = true },
    });
    defer healthy.deinit();
    try healthy.start();
    const stalled_url = try stalled.origin(T.allocator);
    defer T.allocator.free(stalled_url);
    const healthy_url = try healthy.origin(T.allocator);
    defer T.allocator.free(healthy_url);
    var upstream: @import("config.zig").Upstream = .{ .name = "test", .base_url = stalled_url };
    defer upstream.aliases.deinit(T.allocator);
    try upstream.aliases.map.put(T.allocator, "demo", "fixture-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
    var healthy_config = config;
    var healthy_upstream = upstream;
    healthy_upstream.base_url = healthy_url;
    healthy_config.upstreams = &.{healthy_upstream};
    var active: std.atomic.Value(usize) = .init(0);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(T.io);

    const canceled = try T.connect(&upstream_client, &config, &active, &tasks);
    var canceled_open = true;
    defer if (canceled_open) canceled.close(T.io);
    try T.send(canceled, false);
    try stalled.waitRequest();
    const streaming = try T.connect(&upstream_client, &healthy_config, &active, &tasks);
    defer streaming.close(T.io);
    try T.send(streaming, false);
    try healthy.waitRequest();
    var completed: std.Io.Semaphore = .{};
    var prefix = try T.io.concurrent(T.prefix, .{ streaming, &completed });
    defer _ = prefix.cancel(T.io) catch {};
    try completed.waitTimeout(T.io, .{ .duration = request_timeout });
    try prefix.await(T.io);

    try T.reset(canceled);
    canceled_open = false;
    try stalled.waitEof();
    gate.post(T.io);
    const rest = try T.receive(streaming);
    defer T.allocator.free(rest);
    try std.testing.expect(std.mem.find(u8, rest, tail) != null);
    try tasks.await(T.io);
    try std.testing.expectEqual(0, active.load(.monotonic));
    try std.testing.expect(upstream_client.connection_pool.used.first == null);
    try std.testing.expectEqual(1, upstream_client.connection_pool.free_len);

    const next = try T.connect(&upstream_client, &healthy_config, &active, &tasks);
    defer next.close(T.io);
    try T.send(next, false);
    const raw = try T.receive(next);
    defer T.allocator.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, raw, "ok"));
    try healthy.waitRequest();
    try tasks.await(T.io);
    try std.testing.expectEqual(0, active.load(.monotonic));
    try std.testing.expect(upstream_client.connection_pool.used.first == null);
    try std.testing.expectEqual(1, upstream_client.connection_pool.free_len);
    try std.testing.expectEqual(1, healthy.accepted.load(.acquire));
    try std.testing.expectEqual(2, healthy.count.load(.acquire));
    try std.testing.expectEqual(1, stalled.count.load(.acquire));
}

test "transport unavailable SIWC credentials return 503 without sending inference" {
    const T = TransportTest;
    const a = T.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(T.io, .fromMode(0o700));
    const directory = try tmp.dir.realPathFileAlloc(T.io, ".", a);
    defer a.free(directory);
    {
        const file = try tmp.dir.createFile(T.io, "codex.json", .{ .permissions = .fromMode(0o600) });
        defer file.close(T.io);
        try file.writeStreamingAll(T.io,
            \\{"access_token":"expired-access","refresh_token":"refresh","id_token":"id","client_id":"client","device_id":"device","scope":"chatgpt.tokens.use.direct","obtained_at":1,"expires_at":2}
        );
    }
    var upstream: @import("provider.zig").Upstream = .{
        .name = "test",
        .base_url = "https://api.openai.com/v1",
        .auth = .{ .codex = directory },
    };
    defer upstream.aliases.deinit(a);
    try upstream.aliases.map.put(a, "demo", "fixture-model");
    var providers = try Registry.init(a, T.io, &.{upstream});
    defer providers.deinit();
    // A terminal refresh failure with an expired token must fail closed. No
    // refresh worker or external network is needed to exercise this state.
    providers.entries[0].session.?.current.value = providers.entries[0].session.?.current.value.registration();
    var fixture = try T.fixture.Fixture.init(a, T.io, &.{.{ .bytes = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n" }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    // Any accidentally forwarded inference can only reach this local fixture.
    upstream.base_url = origin;
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
    var upstream_client: std.http.Client = .{ .allocator = a, .io = T.io };
    defer upstream_client.deinit();
    var active: std.atomic.Value(usize) = .init(0);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(T.io);
    const client = try T.connectWithRegistry(&upstream_client, &config, &providers, &active, &tasks);
    defer client.close(T.io);
    try T.send(client, false);
    const raw = try T.receive(client);
    defer a.free(raw);
    try tasks.await(T.io);
    try std.testing.expect(std.mem.find(u8, raw, "503 Service Unavailable") != null);
    try std.testing.expect(std.mem.find(u8, raw, "upstream_credentials_unavailable") != null);
    try std.testing.expectEqual(0, fixture.count.load(.acquire));
    try std.testing.expect(!providers.entries[0].session.?.refreshing);
}

test "transport SIWC validates caller auth, JSON, and model aliases locally" {
    const a = std.testing.allocator;
    var upstream: @import("provider.zig").Upstream = .{
        .name = "test",
        .base_url = "https://api.openai.com/v1",
        .auth = .{ .codex = "/unused" },
    };
    defer upstream.aliases.deinit(a);
    try upstream.aliases.map.put(a, "demo", "upstream-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{upstream} };
    const cases = .{
        .{ "wrong-key", "{\"model\":\"test/demo\",\"stream\":false,\"store\":true}", "401 Unauthorized", "unauthorized" },
        .{ "transport-secret", "invalid", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "[]", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "{}", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "{\"model\":null}", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "{\"model\":\"unknown\"}", "400 Bad Request", "unknown_upstream" },
    };
    inline for (cases) |case| {
        const raw = try a.print("POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ case[0], case[1].len, case[1] });
        defer a.free(raw);
        var reader = std.Io.Reader.fixed(raw);
        var writer: std.Io.Writer.Allocating = .init(a);
        defer writer.deinit();
        var http = std.http.Server.init(&reader, &writer.writer);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var completed: std.Io.Semaphore = .{};
        try std.testing.expectEqual(null, try prepareRequest(std.testing.io, std.testing.allocator, arena.allocator(), &http, &config, &completed));
        try std.testing.expect(std.mem.find(u8, writer.written(), case[2]) != null);
        try std.testing.expect(std.mem.find(u8, writer.written(), case[3]) != null);
    }
}

test "transport oversized request is rejected before reading or inviting body" {
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{
        .arena = undefined,
        .address = undefined,
        .clients = &clients,
        .upstreams = &.{.{ .name = "test", .base_url = "http://localhost/v1" }},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\nContent-Length: 16777217\r\nExpect: 100-continue\r\n\r\n");
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var http = std.http.Server.init(&reader, &writer.writer);
    var completed: std.Io.Semaphore = .{};
    try std.testing.expectEqual(null, try prepareRequest(std.testing.io, std.testing.allocator, arena.allocator(), &http, &config, &completed));
    try std.testing.expect(std.mem.startsWith(u8, writer.written(), "HTTP/1.1 413 "));
    try std.testing.expect(std.mem.find(u8, writer.written(), "100 Continue") == null);
}

test "transport models aggregate namespaces aliases and cached metadata while inference bypasses discovery" {
    const T = TransportTest;
    const a = T.allocator;
    const catalog = "{\"object\":\"list\",\"data\":[{\"id\":\"shared\",\"created\":42,\"limits\":{\"context\":200000,\"output\":32000},\"input_modalities\":[\"text\",\"image\"],\"reasoning\":{\"efforts\":[\"low\",\"high\"]}},{\"id\":\"vendor/new-model\"}]}";
    const catalog_reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ catalog.len, catalog });
    var responses_fixture = try T.fixture.Fixture.init(a, T.io, &.{
        .{ .bytes = catalog_reply },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" },
    });
    defer responses_fixture.deinit();
    var chat_fixture = try T.fixture.Fixture.init(a, T.io, &.{
        .{ .bytes = catalog_reply },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: [DONE]\n\n" },
    });
    defer chat_fixture.deinit();
    try responses_fixture.start();
    try chat_fixture.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    var upstreams = [_]@import("provider.zig").Upstream{
        .{ .name = "responses", .base_url = try ra.print("{s}/v1", .{try responses_fixture.origin(ra)}), .auth = .{ .api_key = "responses-secret" } },
        .{ .name = "chat", .base_url = try ra.print("{s}/v1", .{try chat_fixture.origin(ra)}), .auth = .{ .api_key = "chat-secret" } },
    };
    try upstreams[0].aliases.map.put(ra, "shared", "aliased-native");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &upstreams };
    var registry = try Registry.init(a, T.io, config.upstreams);
    defer registry.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = T.io };
    defer client.deinit();

    // Startup and unauthorized discovery must never contact upstreams.
    const rejected = try T.exchange(&client, &config, &registry, "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n");
    defer a.free(rejected);
    try std.testing.expect(std.mem.startsWith(u8, rejected, "HTTP/1.1 401 "));
    try std.testing.expectEqual(0, responses_fixture.count.load(.acquire));
    try std.testing.expectEqual(0, chat_fixture.count.load(.acquire));

    for (0..2) |_| {
        const raw = try T.exchange(&client, &config, &registry, "GET /v1/models?ignored=true HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\n\r\n");
        defer a.free(raw);
        try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 "));
        const parsed = try std.json.parseFromSlice(std.json.Value, a, raw[std.mem.find(u8, raw, "\r\n\r\n").? + 4 ..], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("list", parsed.value.object.get("object").?.string);
        const data = parsed.value.object.get("data").?.array.items;
        try std.testing.expectEqual(4, data.len);
        try std.testing.expectEqualStrings("responses/shared", data[0].object.get("id").?.string);
        try std.testing.expectEqualStrings("responses/vendor/new-model", data[1].object.get("id").?.string);
        try std.testing.expectEqualStrings("chat/shared", data[2].object.get("id").?.string);
        for (data) |model| try std.testing.expect(!model.object.contains("api"));
        try std.testing.expectEqual(@as(i64, 42), data[2].object.get("created").?.integer);
        try std.testing.expectEqual(@as(i64, 200000), data[2].object.get("limits").?.object.get("context").?.integer);
        try std.testing.expectEqualStrings("image", data[2].object.get("input_modalities").?.array.items[1].string);
        try std.testing.expectEqualStrings("high", data[2].object.get("reasoning").?.object.get("efforts").?.array.items[1].string);
        // The shadowing alias points at an undiscovered target, not shared.
        try std.testing.expect(!data[0].object.contains("limits"));
        try std.testing.expect(!data[0].object.contains("created"));
        try std.testing.expect(!data[1].object.contains("input_modalities"));
        try std.testing.expect(std.mem.find(u8, raw, "secret") == null);
        try std.testing.expectEqual(1, responses_fixture.count.load(.acquire));
        try std.testing.expectEqual(1, chat_fixture.count.load(.acquire));
    }

    const cases = [_]struct { path: []const u8, payload: []const u8 }{
        .{ .path = "/v1/responses", .payload = "{\"model\":\"responses/shared\",\"input\":[],\"stream\":false}" },
        .{ .path = "/v1/chat/completions", .payload = "{\"model\":\"chat/vendor/not-in-catalog\",\"messages\":[],\"stream\":true,\"tools\":[]}" },
    };
    for (cases) |case| {
        const request = try ra.print("POST {s} HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\nContent-Length: {d}\r\n\r\n{s}", .{ case.path, case.payload.len, case.payload });
        const raw = try T.exchange(&client, &config, &registry, request);
        defer a.free(raw);
        try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 "));
    }
    try responses_fixture.waitRequest();
    try responses_fixture.waitRequest();
    try chat_fixture.waitRequest();
    try chat_fixture.waitRequest();
    const responses_request = responses_fixture.requests[1].?;
    const chat_request = chat_fixture.requests[1].?;
    try std.testing.expect(std.mem.startsWith(u8, responses_request, "POST /v1/responses "));
    try std.testing.expect(std.mem.find(u8, responses_request, "\"model\":\"aliased-native\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, chat_request, "POST /v1/chat/completions "));
    try std.testing.expect(std.mem.find(u8, chat_request, "\"model\":\"vendor/not-in-catalog\"") != null);
    for (responses_fixture.requests) |request| {
        try std.testing.expect(std.mem.find(u8, request.?, "Bearer responses-secret") != null);
        try std.testing.expect(std.mem.find(u8, request.?, "chat-secret") == null);
        try std.testing.expect(std.mem.find(u8, request.?, "transport-secret") == null);
    }
    for (chat_fixture.requests) |request| {
        try std.testing.expect(std.mem.find(u8, request.?, "Bearer chat-secret") != null);
        try std.testing.expect(std.mem.find(u8, request.?, "responses-secret") == null);
        try std.testing.expect(std.mem.find(u8, request.?, "transport-secret") == null);
    }
}

test "transport discovery failure permits alias fallback and never gates inference or health" {
    const T = TransportTest;
    const a = T.allocator;
    var fixture = try T.fixture.Fixture.init(a, T.io, &.{
        .{ .bytes = "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n" },
        .{ .bytes = "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n" },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" },
    });
    defer fixture.deinit();
    try fixture.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    const upstreams = [_]@import("provider.zig").Upstream{
        .{ .name = "offline", .base_url = try ra.print("{s}/v1", .{try fixture.origin(ra)}) },
    };
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &upstreams };
    var registry = try Registry.init(a, T.io, config.upstreams);
    defer registry.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = T.io };
    defer client.deinit();
    const failed = try T.exchange(&client, &config, &registry, "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\n\r\n");
    defer a.free(failed);
    try std.testing.expect(std.mem.startsWith(u8, failed, "HTTP/1.1 502 "));
    var alias_upstream = upstreams[0];
    try alias_upstream.aliases.map.put(ra, "fallback", "native");
    const alias_config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &.{alias_upstream} };
    var alias_registry = try Registry.init(a, T.io, alias_config.upstreams);
    defer alias_registry.deinit();
    const partial = try T.exchange(&client, &alias_config, &alias_registry, "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\n\r\n");
    defer a.free(partial);
    try std.testing.expect(std.mem.startsWith(u8, partial, "HTTP/1.1 200 "));
    try std.testing.expect(std.mem.find(u8, partial, "offline/fallback") != null);
    try std.testing.expectEqual(2, fixture.count.load(.acquire));
    const health = try T.exchange(&client, &config, &registry, "GET /healthz HTTP/1.1\r\n\r\n");
    defer a.free(health);
    try std.testing.expect(std.mem.startsWith(u8, health, "HTTP/1.1 200 "));
    const payload = "{\"model\":\"offline/new-model\",\"input\":[]}";
    const request = try ra.print("POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    const inference_response = try T.exchange(&client, &config, &registry, request);
    defer a.free(inference_response);
    try std.testing.expect(std.mem.startsWith(u8, inference_response, "HTTP/1.1 200 "));
    try std.testing.expectEqual(3, fixture.count.load(.acquire));
}

test "transport models keep healthy upstreams when another discovery fails" {
    const T = TransportTest;
    const a = T.allocator;
    const body = "{\"data\":[{\"id\":\"model\"}]}";
    var healthy = try T.fixture.Fixture.init(a, T.io, &.{.{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) }});
    defer healthy.deinit();
    var failed = try T.fixture.Fixture.init(a, T.io, &.{.{ .bytes = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n" }});
    defer failed.deinit();
    try healthy.start();
    try failed.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    const upstreams = [_]@import("provider.zig").Upstream{
        .{ .name = "failed", .base_url = try failed.origin(ra) },
        .{ .name = "healthy", .base_url = try healthy.origin(ra) },
    };
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &upstreams };
    var registry = try Registry.init(a, T.io, config.upstreams);
    defer registry.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = T.io };
    defer client.deinit();
    const raw = try T.exchange(&client, &config, &registry, "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\n\r\n");
    defer a.free(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 "));
    const parsed = try std.json.parseFromSlice(std.json.Value, a, raw[std.mem.find(u8, raw, "\r\n\r\n").? + 4 ..], .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.array.items;
    try std.testing.expectEqual(1, data.len);
    try std.testing.expectEqualStrings("healthy/model", data[0].object.get("id").?.string);
}

test "transport one OpenCode upstream serves both native endpoints with shared credentials and no discovery" {
    const T = TransportTest;
    const a = T.allocator;
    const plain = "{\"ok\":true}";
    const sse = "data: {\"delta\":\"native\"}\n\n";
    const plain_reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ plain.len, plain });
    const sse_reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ sse.len, sse });
    const cases = [_]struct { path: []const u8, fields: []const u8, reply: []const u8, response: []const u8 }{
        .{ .path = "/responses", .fields = ",\"input\":[],\"stream\":false,\"reasoning\":{\"effort\":\"high\"}}", .reply = plain_reply, .response = plain },
        .{ .path = "/chat/completions", .fields = ",\"messages\":[],\"stream\":true,\"tools\":[]}", .reply = sse_reply, .response = sse },
        .{ .path = "/responses", .fields = ",\"input\":[],\"stream\":true,\"tools\":[]}", .reply = sse_reply, .response = sse },
        .{ .path = "/chat/completions", .fields = ",\"messages\":[],\"stream\":false,\"temperature\":0.5}", .reply = plain_reply, .response = plain },
    };
    for ([_][]const u8{ "go", "zen" }) |name| {
        const prefix = if (std.mem.eql(u8, name, "go")) "/zen/go/v1" else "/zen/v1";
        var replies: [cases.len]T.fixture.Reply = undefined;
        for (&replies, cases) |*reply, case| reply.* = .{ .bytes = case.reply };
        var fixture = try T.fixture.Fixture.init(a, T.io, &replies);
        defer fixture.deinit();
        try fixture.start();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ra = arena.allocator();
        const upstreams = [_]@import("provider.zig").Upstream{.{
            .name = name,
            .base_url = try ra.print("{s}{s}", .{ try fixture.origin(ra), prefix }),
            .auth = .{ .api_key = "opencode-secret" },
        }};
        const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
        const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstreams = &upstreams };
        var registry = try Registry.init(a, T.io, config.upstreams);
        defer registry.deinit();
        var client: std.http.Client = .{ .allocator = a, .io = T.io };
        defer client.deinit();
        for (cases, 0..) |case, index| {
            const payload = try ra.print("{{\"model\":\"{s}/vendor/new-model\"{s}", .{ name, case.fields });
            const request = try ra.print("POST /v1{s} HTTP/1.1\r\nAuthorization: Bearer transport-secret\r\nContent-Length: {d}\r\n\r\n{s}", .{ case.path, payload.len, payload });
            const result = try T.exchange(&client, &config, &registry, request);
            defer a.free(result);
            try std.testing.expect(std.mem.startsWith(u8, result, "HTTP/1.1 200 "));
            try std.testing.expect(std.mem.endsWith(u8, result, case.response));
            try fixture.waitRequest();
            const captured = fixture.requests[index].?;
            try std.testing.expect(std.mem.startsWith(u8, captured, try ra.print("POST {s}{s} HTTP/1.1\r\n", .{ prefix, case.path })));
            const expected_body = try ra.print("{{\"model\":\"vendor/new-model\"{s}", .{case.fields});
            try std.testing.expectEqualStrings(expected_body, captured[std.mem.find(u8, captured, "\r\n\r\n").? + 4 ..]);
            try std.testing.expect(std.mem.find(u8, captured, "Bearer opencode-secret") != null);
            try std.testing.expect(std.mem.find(u8, captured, "transport-secret") == null);
        }
        try std.testing.expectEqual(1, registry.entries.len);
        try std.testing.expectEqual(cases.len, fixture.count.load(.acquire));
        try std.testing.expect(registry.entries[0].catalog.arena == null);
    }
}
