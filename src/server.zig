const std = @import("std");
const auth = @import("auth.zig");
const Config = @import("config.zig").Config;

const max_connections = 64;
const request_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

pub fn serve(io: std.Io, config: *const Config) !void {
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
        connections.concurrent(io, handleConnection, .{ io, stream, config.clients, &active, deadline }) catch |err| {
            stream.close(io);
            _ = active.fetchSub(1, .monotonic);
            std.log.warn("event=connection_dispatch_failed error={s}", .{@errorName(err)});
        };
    }
}

fn handleConnection(
    io: std.Io,
    stream: std.Io.net.Stream,
    clients: []const auth.Client,
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

    handleRequestBefore(io, &http, clients, deadline) catch |err| {
        std.log.warn("event=connection_failed error={s}", .{@errorName(err)});
    };
}

fn handleRequestBefore(
    io: std.Io,
    http: *std.http.Server,
    clients: []const auth.Client,
    deadline: std.Io.Clock.Timestamp,
) !void {
    var completed: std.Io.Semaphore = .{};
    var task = try io.concurrent(handleRequestAndSignal, .{ io, http, clients, &completed });
    // Join canceled I/O before the connection closes or its buffers go out of scope.
    defer task.cancel(io) catch {};
    try completed.waitTimeout(io, .{ .deadline = deadline });
    try task.await(io);
}

fn handleRequestAndSignal(io: std.Io, http: *std.http.Server, clients: []const auth.Client, completed: *std.Io.Semaphore) !void {
    defer completed.post(io);
    try handleRequest(http, clients);
}

fn handleRequest(http: *std.http.Server, clients: []const auth.Client) !void {
    var request = try http.receiveHead();
    const path = request.head.target[0 .. std.mem.findScalar(u8, request.head.target, '?') orelse request.head.target.len];
    var status: std.http.Status = .not_found;
    var body: []const u8 = "{\"error\":\"not_found\"}\n";
    var client: ?[]const u8 = null;

    if (std.mem.eql(u8, path, "/healthz") and request.head.method == .GET) {
        status = .ok;
        body = "{\"status\":\"ok\"}\n";
    } else if (std.mem.startsWith(u8, path, "/v1/") or std.mem.eql(u8, path, "/v1")) {
        client = auth.authenticate(clients, authorizationHeader(&request));
        if (client == null) {
            status = .unauthorized;
            body = "{\"error\":\"unauthorized\"}\n";
        }
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
    inline for (cases) |case| {
        var reader = std.Io.Reader.fixed(case[0]);
        var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer writer.deinit();
        var http = std.http.Server.init(&reader, &writer.writer);
        try handleRequest(&http, &clients);
        const response = writer.written();
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 " ++ case[1]));
        try std.testing.expect(std.mem.find(u8, response, "100 Continue") == null);
        try std.testing.expect(std.mem.find(u8, response, case[2]) != null);
        try std.testing.expect(std.mem.find(u8, response, "connection: close\r\n") != null);
        try std.testing.expect(std.mem.find(u8, response, "first-secret") == null);
        try std.testing.expect(std.mem.find(u8, response, "second-secret") == null);
    }
}
