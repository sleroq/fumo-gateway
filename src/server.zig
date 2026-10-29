const std = @import("std");
const auth = @import("auth.zig");
pub const Config = @import("config.zig").Config;
pub const Session = @import("codex/session.zig").Session;
const responses = @import("responses.zig");
const provider = @import("provider.zig");

const Route = enum { health, responses, unknown };
const routes = std.StaticStringMap(Route).initComptime(.{
    .{ "/healthz", .health },
    .{ "/v1/responses", .responses },
});

const max_connections = 64;
const request_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

/// session is service-owned; all connections finish before its caller deinitializes it.
pub fn serve(allocator: std.mem.Allocator, io: std.Io, config: *const Config, session: ?*Session) !void {
    var listener = try config.address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

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
        connections.concurrent(io, handleConnection, .{ allocator, io, stream, config, session, &active, deadline }) catch |err| {
            stream.close(io);
            _ = active.fetchSub(1, .monotonic);
            std.log.warn("event=connection_dispatch_failed error={s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    config: *const Config,
    session: ?*Session,
    active: *std.atomic.Value(usize),
    deadline: std.Io.Clock.Timestamp,
) void {
    defer _ = active.fetchSub(1, .monotonic);
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http = std.http.Server.init(&reader.interface, &writer.interface);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var pending = (prepareRequestWithDeadline(io, arena.allocator(), &http, config, deadline) catch |err| {
        std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
        return;
    }) orelse return;
    if (session) |credentials| {
        pending.authorization = credentials.authorization(arena.allocator()) catch |err| {
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
    const status = responses.forward(io, arena.allocator(), stream, config.upstream.?, &pending) catch |err| {
        std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
        return;
    };
    logRequest(status, pending.client);
}

fn prepareRequestWithDeadline(
    io: std.Io,
    allocator: std.mem.Allocator,
    http: *std.http.Server,
    config: *const Config,
    deadline: std.Io.Clock.Timestamp,
) !?responses.Pending {
    var completed: std.Io.Semaphore = .{};
    var task = try io.concurrent(prepareRequest, .{ io, allocator, http, config, &completed });
    // Only request reception is timed; long-lived SSE is not cut off.
    defer _ = task.cancel(io) catch null;
    try completed.waitTimeout(io, .{ .deadline = deadline });
    return try task.await(io);
}

fn prepareRequest(io: std.Io, allocator: std.mem.Allocator, http: *std.http.Server, config: *const Config, completed: *std.Io.Semaphore) !?responses.Pending {
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
                if (responses.prepare(allocator, &request, upstream, provider.responses, client.?)) |pending| {
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
        _ = try prepareRequest(std.testing.io, std.testing.allocator, &http, &config, &completed);
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

    fn connect(config: *const Config, active: *std.atomic.Value(usize), tasks: *std.Io.Group) !std.Io.net.Stream {
        var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
        defer listener.deinit(io);
        const client = try listener.socket.address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        const accepted = try listener.accept(io);
        errdefer accepted.close(io);
        active.store(1, .monotonic);
        try tasks.concurrent(io, handleConnection, .{ allocator, io, accepted, config, null, active, std.Io.Clock.Timestamp.fromNow(io, request_timeout) });
        return client;
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

test "transport socket relay preserves payload, isolates headers, and handles response framing without replay" {
    const T = TransportTest;
    const cases = [_]struct { reply: []const u8, status: []const u8, body: []const u8, chunked: bool = false, header: ?[]const u8 = null }{
        .{ .reply = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nContent-Type: application/json\r\nAuthorization: private\r\nConnection: X-Hop\r\nX-Hop: private\r\n\r\n{\"ok\":true}", .status = "200 OK", .body = "{\"ok\":true}" },
        .{ .reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: X-Hop\r\nX-Hop: private\r\n\r\n5\r\n{\"ok\"\r\n6\r\n:true}\r\n0\r\n\r\n", .status = "200 OK", .body = "{\"ok\":true}", .chunked = true },
        .{ .reply = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 4\r\nRetry-After: 17\r\n\r\nbusy", .status = "429 Too Many Requests", .body = "busy", .header = "retry-after: 17" },
        .{ .reply = "HTTP/1.1 307 Temporary Redirect\r\nContent-Length: 4\r\nLocation: /never-follow\r\n\r\nmove", .status = "307 Temporary Redirect", .body = "move", .header = "location: /never-follow" },
        .{ .reply = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", .status = "200 OK", .body = "ok" },
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
        const client = try T.connect(&config, &active, &tasks);
        defer client.close(T.io);
        try T.send(client, case.chunked);
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

test "transport incremental SSE barrier and disconnect before or after headers close upstream" {
    const T = TransportTest;
    for ([_]enum { complete, disconnect_before_head, disconnect_after_head }{ .complete, .disconnect_before_head, .disconnect_after_head }) |mode| {
        var gate: std.Io.Semaphore = .{};
        const head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
        const tail = "data: [DONE]\n\n";
        var fixture = try T.fixture.Fixture.init(T.allocator, T.io, &.{.{
            .bytes = if (mode == .disconnect_before_head) "" else head ++ T.first,
            .gate = if (mode == .complete) &gate else null,
            .tail = if (mode == .complete) tail else "",
            .peer_eof = mode != .complete,
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
        const client = try T.connect(&config, &active, &tasks);
        var client_open = true;
        defer if (client_open) client.close(T.io);
        try T.send(client, false);
        try fixture.waitRequest();
        if (mode != .disconnect_before_head) {
            var completed: std.Io.Semaphore = .{};
            var task = try T.io.concurrent(T.prefix, .{ client, &completed });
            defer _ = task.cancel(T.io) catch {};
            try completed.waitTimeout(T.io, .{ .duration = request_timeout });
            try task.await(T.io);
        }
        if (mode == .complete) {
            gate.post(T.io);
            const rest = try T.receive(client);
            defer T.allocator.free(rest);
            try std.testing.expect(std.mem.find(u8, rest, tail) != null);
            try std.testing.expect(std.mem.find(u8, rest, "error") == null);
        } else {
            client.close(T.io);
            client_open = false;
            try fixture.waitEof();
        }
        try std.testing.expectEqual(1, fixture.count.load(.acquire));
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
    try std.testing.expectEqual(null, try prepareRequest(std.testing.io, arena.allocator(), &http, &config, &completed));
    try std.testing.expect(std.mem.startsWith(u8, writer.written(), "HTTP/1.1 413 "));
    try std.testing.expect(std.mem.find(u8, writer.written(), "100 Continue") == null);
}
