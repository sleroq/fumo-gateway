const std = @import("std");

pub const Grant = struct { code: []const u8, client_id: []const u8 };

pub const Callback = struct {
    server: std.Io.net.Server,

    pub fn listen(io: std.Io, port: u16) !Callback {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var server = try address.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        // std.Io enables both reuse options. Keep REUSEADDR for immediate
        // retries after TIME_WAIT, but never share an active callback port.
        if (@hasDecl(std.posix.SO, "REUSEPORT")) {
            const disabled: c_int = 0;
            try std.posix.setsockopt(server.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, std.mem.asBytes(&disabled));
        }
        return .{ .server = server };
    }

    pub fn deinit(self: *Callback, io: std.Io) void {
        self.server.deinit(io);
    }

    pub fn redirectUri(self: *const Callback, allocator: std.mem.Allocator) ![]u8 {
        return allocator.print("http://127.0.0.1:{d}/auth/callback", .{self.server.socket.address.getPort()});
    }

    /// The caller owns the deadline and must deinit the listener after waiting.
    /// Only the returned grant is allocated in the caller's allocator.
    pub fn wait(self: *Callback, allocator: std.mem.Allocator, io: std.Io, expected_state: []const u8, expected_client: ?[]const u8) !Grant {
        while (true) {
            const stream = try self.server.accept(io);
            defer stream.close(io);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            var read_buffer: [16384]u8 = undefined;
            var write_buffer: [1024]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            var writer = stream.writer(io, &write_buffer);
            var server = std.http.Server.init(&reader.interface, &writer.interface);

            var request = server.receiveHead() catch {
                if (reader.err) |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {},
                };
                // Malformed or oversized HTTP heads also get a static response.
                writer.interface.writeAll("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: 0\r\n\r\n") catch {};
                writer.interface.flush() catch {};
                if (writer.err) |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {},
                };
                try io.checkCancel();
                continue;
            };

            const grant = parse(arena.allocator(), request.head.method, request.head.target, expected_state, expected_client) catch |err| {
                const status: std.http.Status = switch (err) {
                    error.NotFound => .not_found,
                    error.MethodNotAllowed => .method_not_allowed,
                    error.OutOfMemory => return error.OutOfMemory,
                    else => .bad_request,
                };
                try respond(&request, &writer, status, "Invalid authorization callback.");
                if (err == error.AuthorizationDenied) return error.AuthorizationDenied;
                try io.checkCancel();
                continue;
            };

            const code = try allocator.dupe(u8, grant.code);
            errdefer allocator.free(code);
            const client_id = try allocator.dupe(u8, grant.client_id);
            errdefer allocator.free(client_id);

            // A disconnected browser must not discard a valid grant, but the
            // authorization deadline must still be able to cancel this task.
            try respond(&request, &writer, .ok, "Authorization received. Return to the terminal to check login status.");
            return .{ .code = code, .client_id = client_id };
        }
    }
};

fn respond(request: *std.http.Server.Request, writer: *std.Io.net.Stream.Writer, status: std.http.Status, body: []const u8) std.Io.Cancelable!void {
    request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            .{ .name = "Cache-Control", .value = "no-store" },
            .{ .name = "Referrer-Policy", .value = "no-referrer" },
        },
    }) catch {};
    if (writer.err) |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

fn parse(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8, expected_state: []const u8, expected_client: ?[]const u8) !Grant {
    const query_start = std.mem.findScalar(u8, target, '?') orelse target.len;
    if (!std.mem.eql(u8, target[0..query_start], "/auth/callback")) return error.NotFound;
    if (method != .GET) return error.MethodNotAllowed;
    if (query_start == target.len or std.mem.findScalar(u8, target, '#') != null) return error.InvalidQuery;

    var fields: [4]?[]const u8 = .{ null, null, null, null };
    const names = [_][]const u8{ "state", "code", "client_id", "error" };
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.findScalar(u8, pair, '=') orelse return error.InvalidQuery;
        const name = try decode(allocator, pair[0..equals]);
        const value = try decode(allocator, pair[equals + 1 ..]);
        for (names, 0..) |known, i| {
            if (std.mem.eql(u8, name, known)) {
                if (fields[i] != null or std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len == 0) return error.InvalidQuery;
                fields[i] = value;
            }
        }
    }
    const state = fields[0] orelse return error.InvalidState;
    if (!std.mem.eql(u8, state, expected_state)) return error.InvalidState;
    if (fields[3] != null) return error.AuthorizationDenied;

    const client_id = if (expected_client) |selected| blk: {
        if (fields[2]) |supplied| {
            if (!std.mem.eql(u8, supplied, selected)) return error.ClientMismatch;
        }
        break :blk selected;
    } else fields[2] orelse return error.InvalidQuery;

    if (std.mem.eql(u8, client_id, "dynamic_agent_client")) return error.InvalidQuery;

    return .{ .code = fields[1] orelse return error.InvalidQuery, .client_id = client_id };
}

fn decode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, input.len);
    var length: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        output[length] = switch (input[i]) {
            '+' => ' ',
            '%' => blk: {
                if (input.len - i < 3) return error.InvalidQuery;
                const high = std.fmt.charToDigit(input[i + 1], 16) catch return error.InvalidQuery;
                const low = std.fmt.charToDigit(input[i + 2], 16) catch return error.InvalidQuery;
                const byte = high * 16 + low;
                i += 2;
                break :blk byte;
            },
            else => input[i],
        };
        length += 1;
    }
    return output[0..length];
}

test "form decoding preserves code bytes and issued client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grant = try parse(arena.allocator(), .GET, "/auth/callback?state=s%2B+x&code=a%2Bb%2Fc%3D+z&client_id=issued%26id", "s+ x", null);
    try std.testing.expectEqualStrings("a+b/c= z", grant.code);
    try std.testing.expectEqualStrings("issued&id", grant.client_id);
}

test "state, required client, duplicates, malformed queries and fragments are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidState, parse(a, .GET, "/auth/callback?state=wrong&code=c&client_id=i", "s", null));
    try std.testing.expectError(error.InvalidState, parse(a, .GET, "/auth/callback?code=c&client_id=i", "s", null));
    const invalid = [_][]const u8{
        "state=s&code=c",                     "state=s&code=c&client_id=",           "state=s&code=c&client_id=i&client_id=j",
        "state=s&state=s&code=c&client_id=i", "state=s&code=c&code=c&client_id=i",   "state=s&code=%GG&client_id=i",
        "state=s&code=%&client_id=i",         "state=s&code=c&client_id=i#fragment", "state=s&code=c&client_id=i&%63lient_id=j",
        "state=&code=c&client_id=i",          "state=s&code=c&client_id=+",          "state=s&code=%20&client_id=i",
    };
    for (invalid) |query| {
        const target = try a.print("/auth/callback?{s}", .{query});
        try std.testing.expectError(error.InvalidQuery, parse(a, .GET, target, "s", null));
    }
    try std.testing.expectError(error.NotFound, parse(a, .GET, "/favicon.ico", "s", null));
    try std.testing.expectError(error.MethodNotAllowed, parse(a, .POST, "/auth/callback?state=s", "s", null));
}

test "returning callbacks retain the pending client and reject replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grant = try parse(a, .GET, "/auth/callback?state=s&code=c", "s", "issued");
    try std.testing.expectEqualStrings("issued", grant.client_id);
    _ = try parse(a, .GET, "/auth/callback?state=s&code=c&client_id=issued", "s", "issued");
    try std.testing.expectError(error.ClientMismatch, parse(a, .GET, "/auth/callback?state=s&code=c&client_id=other", "s", "issued"));
    try std.testing.expectError(error.InvalidQuery, parse(a, .GET, "/auth/callback?state=s&code=c&client_id=dynamic_agent_client", "s", null));
}

test "OAuth errors require matching state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.AuthorizationDenied, parse(a, .GET, "/auth/callback?state=s&error=access_denied", "s", null));
    try std.testing.expectError(error.InvalidState, parse(a, .GET, "/auth/callback?state=other&error=access_denied", "s", null));
    try std.testing.expectError(error.InvalidState, parse(a, .GET, "/auth/callback?error=access_denied", "s", null));
    try std.testing.expectError(error.InvalidQuery, parse(a, .GET, "/auth/callback?state=s&error=a&error=b", "s", null));
}

test "public listener API compiles and reports assigned loopback port" {
    const io = std.testing.io;
    var callback = try Callback.listen(io, 0);
    defer callback.deinit(io);
    const uri = try callback.redirectUri(std.testing.allocator);
    defer std.testing.allocator.free(uri);
    try std.testing.expect(std.mem.startsWith(u8, uri, "http://127.0.0.1:"));
    try std.testing.expect(callback.server.socket.address.getPort() != 0);
    // Force analysis of the blocking path without starting an authorization flow.
    _ = &Callback.wait;
}

test "callback port is exclusive while active and reusable after connection close" {
    const io = std.testing.io;
    var callback = try Callback.listen(io, 0);
    const port = callback.server.socket.address.getPort();
    {
        defer callback.deinit(io);
        try std.testing.expectError(error.AddressInUse, Callback.listen(io, port));
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        const client = try address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const connection = try callback.server.accept(io);
        connection.close(io);
        // Observe the server's FIN before closing the client, leaving the
        // server endpoint (rather than the client) in TIME_WAIT.
        var buffer: [1]u8 = undefined;
        var slices = [_][]u8{&buffer};
        try std.testing.expectEqual(@as(usize, 0), (try client.readWithControl(io, &slices, &.{})).data_len);
    }
    var retry = try Callback.listen(io, port);
    defer retry.deinit(io);
    try std.testing.expectError(error.AddressInUse, Callback.listen(io, port));
}
