const std = @import("std");
const auth = @import("auth.zig");
pub const Config = @import("config.zig").Config;
const responses = @import("responses.zig");
const Provider = @import("provider.zig").Provider;

const Route = enum { health, responses, unknown };
const routes = std.StaticStringMap(Route).initComptime(.{
    .{ "/healthz", .health },
    .{ "/v1/responses", .responses },
});

const max_connections = 64;
const request_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

/// allocator must be thread-safe. The HTTP client is service-owned; all
/// connections finish before it or the provider is deinitialized.
pub fn serve(allocator: std.mem.Allocator, io: std.Io, config: *const Config) !void {
    var provider = if (config.upstream) |upstream| try Provider.init(allocator, io, upstream) else null;
    defer if (provider) |*value| value.deinit();

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
        connections.concurrent(io, handleConnection, .{ allocator, &client, stream, config, if (provider) |*value| value else null, &active, deadline }) catch |err| {
            stream.close(io);
            _ = active.fetchSub(1, .monotonic);
            std.log.warn("event=connection_dispatch_failed error={s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    stream: std.Io.net.Stream,
    config: *const Config,
    provider: ?*Provider,
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
    var pending = (prepareRequestWithDeadline(io, allocator, arena.allocator(), &http, config, deadline) catch |err| {
        std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
        return;
    }) orelse return;
    if (provider) |upstream| {
        pending.authorization = upstream.authorization(arena.allocator()) catch |err| {
            std.log.warn("event=upstream_credentials_unavailable error={s}", .{@errorName(err)});
            pending.request.respond("{\"error\":\"upstream_credentials_unavailable\"}\n", .{
                .status = .service_unavailable,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            }) catch return;
            logRequest(.service_unavailable, pending.client);
            return;
        };
    }
    const status = responses.forward(client, arena.allocator(), stream, &pending) catch |err| {
        std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
        return;
    };
    logRequest(status, pending.client);
}

fn prepareRequestWithDeadline(
    io: std.Io,
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    http: *std.http.Server,
    config: *const Config,
    deadline: std.Io.Clock.Timestamp,
) !?responses.Pending {
    var completed: std.Io.Semaphore = .{};
    var task = try io.concurrent(prepareRequest, .{ io, gpa, allocator, http, config, &completed });
    // Only request reception is timed; long-lived SSE is not cut off.
    defer _ = task.cancel(io) catch null;
    try completed.waitTimeout(io, .{ .deadline = deadline });
    return try task.await(io);
}

fn prepareRequest(io: std.Io, gpa: std.mem.Allocator, allocator: std.mem.Allocator, http: *std.http.Server, config: *const Config, completed: *std.Io.Semaphore) !?responses.Pending {
    defer completed.post(io);

    var request = try http.receiveHead();
    const path = request.head.target[0 .. std.mem.findScalar(u8, request.head.target, '?') orelse request.head.target.len];
    var status: std.http.Status = .not_found;
    var body: []const u8 = "{\"error\":\"not_found\"}\n";
    var client: ?[]const u8 = null;

    if (std.mem.startsWith(u8, path, "/v1/") or std.mem.eql(u8, path, "/v1")) {
        client = auth.authenticate(config.clients, authorizationHeader(&request));
        if (client == null) {
            status = .unauthorized;
            body = "{\"error\":\"unauthorized\"}\n";
        }
    }

    switch (routes.get(path) orelse .unknown) {
        .health => if (request.head.method == .GET) {
            status = .ok;
            body = "{\"status\":\"ok\"}\n";
        },
        .responses => if (client != null and request.head.method == .POST) {
            if (config.upstream) |upstream| {
                if (responses.prepare(gpa, allocator, &request, upstream, client.?)) |pending| {
                    return pending;
                } else |err| switch (err) {
                    error.InvalidRequest => {
                        status = .bad_request;
                        body = "{\"error\":\"invalid_request\"}\n";
                    },
                    error.UnknownModel => {
                        status = .bad_request;
                        body = "{\"error\":\"unknown_model\"}\n";
                    },
                    error.StreamTooLong => {
                        status = .payload_too_large;
                        body = "{\"error\":\"request_too_large\"}\n";
                    },
                    error.HttpExpectationFailed => {
                        status = .expectation_failed;
                        body = "{\"error\":\"unsupported_expectation\"}\n";
                    },
                    else => return err,
                }
            }
        },
        .unknown => {},
    }

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "www-authenticate", .value = "Bearer" },
    };

    // Send the final response without inviting or reading a body; this connection closes.
    request.head.expect = null;
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = if (status == .unauthorized) &headers else headers[0..1],
    });

    logRequest(status, client);
    return null;
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
        .{ "POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer first-secret\r\nContent-Length: 1000000\r\nExpect: 100-continue\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer first-secret\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1/models?limit=1 HTTP/1.1\r\naUtHoRiZaTiOn: bearer second-secret\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1 HTTP/1.1\r\n\r\n", "401 Unauthorized", "unauthorized" },
        .{ "GET /unknown HTTP/1.1\r\n\r\n", "404 Not Found", "not_found" },
        .{ "GET /v1/models HTTP/1.1\r\nAuthorization: Bearer first-secret\r\nAuthorization: Bearer second-secret\r\n\r\n", "401 Unauthorized", "unauthorized" },
    };
    const clients = [_]auth.Client{ auth.Client.init("pi", "first-secret"), auth.Client.init("dev", "second-secret") };
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = null };
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
    const payload = "{\"model\":\"demo\",\"stream\":true,\"opaque\":{\"nested\":[1,null,true]}}";
    const first = "data: {\"delta\":\"first\"}\n\n";

    fn connect(upstream_client: *std.http.Client, config: *const Config, active: *std.atomic.Value(usize), tasks: *std.Io.Group) !std.Io.net.Stream {
        return connectWithProvider(upstream_client, config, null, active, tasks);
    }

    fn connectWithProvider(upstream_client: *std.http.Client, config: *const Config, provider: ?*Provider, active: *std.atomic.Value(usize), tasks: *std.Io.Group) !std.Io.net.Stream {
        var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
        defer listener.deinit(io);
        const client = try listener.socket.address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        const accepted = try listener.accept(io);
        errdefer accepted.close(io);
        _ = active.fetchAdd(1, .monotonic);
        try tasks.concurrent(io, handleConnection, .{ allocator, upstream_client, accepted, config, provider, active, std.Io.Clock.Timestamp.fromNow(io, request_timeout) });
        return client;
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
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" },
    });
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(T.allocator);
    defer T.allocator.free(origin);
    var upstream: @import("config.zig").Upstream = .{ .url = origin, .models = .{} };
    defer upstream.models.deinit(T.allocator);
    try upstream.models.map.put(T.allocator, "demo", "fixture-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = upstream };
    var active: std.atomic.Value(usize) = .init(0);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(T.io);
    var payload: std.Io.Writer.Allocating = .init(T.allocator);
    defer payload.deinit();
    try payload.writer.writeAll("{\"model\":\"demo\",\"input\":");
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
        const url = try std.fmt.allocPrint(T.allocator, "{s}/v1/responses", .{origin});
        defer T.allocator.free(url);
        var upstream: @import("config.zig").Upstream = .{ .url = url, .models = .{} };
        defer upstream.models.deinit(T.allocator);
        try upstream.models.map.put(T.allocator, "demo", "fixture-model");
        const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
        const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = upstream };
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
        var upstream: @import("config.zig").Upstream = .{ .url = origin, .models = .{} };
        defer upstream.models.deinit(T.allocator);
        try upstream.models.map.put(T.allocator, "demo", "fixture-model");
        const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
        const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = upstream };
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
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" ++ T.first, .gate = &gate, .tail = tail },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" },
    });
    defer healthy.deinit();
    try healthy.start();
    const stalled_url = try stalled.origin(T.allocator);
    defer T.allocator.free(stalled_url);
    const healthy_url = try healthy.origin(T.allocator);
    defer T.allocator.free(healthy_url);
    var upstream: @import("config.zig").Upstream = .{ .url = stalled_url, .models = .{} };
    defer upstream.models.deinit(T.allocator);
    try upstream.models.map.put(T.allocator, "demo", "fixture-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = upstream };
    var healthy_config = config;
    healthy_config.upstream.?.url = healthy_url;
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
    try std.testing.expectEqual(0, upstream_client.connection_pool.free_len);
}

test "transport unavailable SIWC credentials return 503 without sending inference" {
    const T = TransportTest;
    const a = T.allocator;
    var tmp = std.testing.tmpDir(.{});
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
        .url = "https://api.openai.com/v1/responses",
        .models = .{},
        .auth = .{ .provider = .codex, .credentials_dir = directory },
    };
    defer upstream.models.deinit(a);
    try upstream.models.map.put(a, "demo", "fixture-model");
    var provider = try Provider.init(a, T.io, upstream);
    defer provider.deinit();
    // A terminal refresh failure with an expired token must fail closed. No
    // refresh worker or external network is needed to exercise this state.
    provider.session.?.reauthentication_required = true;
    var fixture = try T.fixture.Fixture.init(a, T.io, &.{.{ .bytes = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n" }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    // Any accidentally forwarded inference can only reach this local fixture.
    upstream.url = origin;
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = upstream };
    var upstream_client: std.http.Client = .{ .allocator = a, .io = T.io };
    defer upstream_client.deinit();
    var active: std.atomic.Value(usize) = .init(0);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(T.io);
    const client = try T.connectWithProvider(&upstream_client, &config, &provider, &active, &tasks);
    defer client.close(T.io);
    try T.send(client, false);
    const raw = try T.receive(client);
    defer a.free(raw);
    try tasks.await(T.io);
    try std.testing.expect(std.mem.find(u8, raw, "503 Service Unavailable") != null);
    try std.testing.expect(std.mem.find(u8, raw, "upstream_credentials_unavailable") != null);
    try std.testing.expectEqual(0, fixture.count.load(.acquire));
    try std.testing.expect(!provider.session.?.refreshing);
}

test "transport SIWC invalid contracts fail locally after gateway authentication" {
    const a = std.testing.allocator;
    var upstream: @import("provider.zig").Upstream = .{
        .url = "https://api.openai.com/v1/responses",
        .models = .{},
        .auth = .{ .provider = .codex },
    };
    defer upstream.models.deinit(a);
    try upstream.models.map.put(a, "demo", "upstream-model");
    const clients = [_]auth.Client{auth.Client.init("transport", "transport-secret")};
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &clients, .upstream = upstream };
    const cases = .{
        .{ "wrong-key", "{\"model\":\"demo\",\"stream\":true}", "401 Unauthorized", "unauthorized" },
        .{ "transport-secret", "{\"model\":\"demo\"}", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "{\"model\":\"demo\",\"stream\":false}", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "{\"model\":\"demo\",\"stream\":true,\"store\":true}", "400 Bad Request", "invalid_request" },
        .{ "transport-secret", "{\"model\":\"demo\",\"stream\":true,\"max_output_tokens\":99}", "400 Bad Request", "invalid_request" },
    };
    inline for (cases) |case| {
        const raw = try std.fmt.allocPrint(a, "POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ case[0], case[1].len, case[1] });
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
        .upstream = .{ .url = "http://localhost/v1/responses", .models = .{} },
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
