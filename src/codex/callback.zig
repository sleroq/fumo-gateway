const std = @import("std");

pub const Grant = struct { code: []const u8, client_id: []const u8 };

pub fn parse(allocator: std.mem.Allocator, method: std.http.Method, target: []const u8, expected_state: []const u8, expected_client: ?[]const u8) !Grant {
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

/// Parse a pasted callback locally; never follows or fetches the supplied URL.
pub fn pasted(allocator: std.mem.Allocator, url: []const u8, state: []const u8, client: ?[]const u8) !Grant {
    const prefix = "http://127.0.0.1:1455";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidCallback;
    return parse(allocator, .GET, url[prefix.len..], state, client);
}

test "pasted callback validates origin and path without fetching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const grant = try pasted(a, "http://127.0.0.1:1455/auth/callback?state=s&code=c&client_id=issued", "s", null);
    try std.testing.expectEqualStrings("c", grant.code);
    try std.testing.expectEqualStrings("issued", grant.client_id);
    try std.testing.expectError(error.InvalidCallback, pasted(a, "https://example.com/auth/callback?state=s&code=c&client_id=issued", "s", null));
    try std.testing.expectError(error.NotFound, pasted(a, "http://127.0.0.1:14550/auth/callback?state=s&code=c&client_id=issued", "s", null));
}
