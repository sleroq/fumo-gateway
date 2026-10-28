const std = @import("std");
const auth = @import("auth.zig");
const Config = @import("config.zig").Config;
const responses = @import("responses.zig");
const provider = @import("provider.zig");

const Route = enum { health, responses, unknown };
const routes = std.StaticStringMap(Route).initComptime(.{
    .{ "/healthz", .health },
    .{ "/v1/responses", .responses },
});

const max_connections = 64;
const request_timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake };

pub fn serve(allocator: std.mem.Allocator, io: std.Io, config: *const Config) !void {
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
        connections.concurrent(io, handleConnection, .{ allocator, io, stream, config, &active, deadline }) catch |err| {
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
