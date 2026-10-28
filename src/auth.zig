const std = @import("std");

pub const Client = struct {
    label: []const u8,
    key_hash: [32]u8,

    pub fn init(label: []const u8, key: []const u8) Client {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &hash, .{});
        return .{ .label = label, .key_hash = hash };
    }
};

pub fn authenticate(clients: []const Client, authorization: ?[]const u8) ?[]const u8 {
    const value = authorization orelse return null;
    const prefix = "Bearer ";
    if (value.len < prefix.len or !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix)) return null;
    const key = std.mem.trim(u8, value[prefix.len..], " ");
    if (key.len == 0) return null;

    const candidate = Client.init("", key);
    for (clients) |client| {
        if (std.crypto.timing_safe.eql([32]u8, client.key_hash, candidate.key_hash))
            return client.label;
    }

    return null;
}

test "bearer keys resolve to client labels" {
    const clients = [_]Client{ Client.init("pi", "first-secret"), Client.init("dev", "second-secret") };
    try std.testing.expectEqualStrings("pi", authenticate(&clients, "Bearer first-secret").?);
    try std.testing.expectEqualStrings("dev", authenticate(&clients, "bearer second-secret").?);
    for ([_]?[]const u8{ null, "", "Basic first-secret", "Bearer", "Bearer ", "Bearer wrong", "Bearer first-secret extra" }) |value| {
        try std.testing.expectEqual(null, authenticate(&clients, value));
    }
}
