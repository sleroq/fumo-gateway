const std = @import("std");

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMapUnmanaged([64]u8, bool) = .empty,

    pub fn deinit(self: *Session) void {
        self.entries.deinit(self.allocator);
    }

    pub fn create(self: *Session, secure: bool) ![64]u8 {
        var bytes: [32]u8 = undefined;
        try self.io.randomSecure(&bytes);
        const token = std.fmt.bytesToHex(bytes, .lower);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.entries.put(self.allocator, token, secure);
        return token;
    }

    pub fn lookup(self: *Session, token: []const u8, revoke: bool) !?bool {
        if (token.len != 64) return null;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const key: [64]u8 = token[0..64].*;
        const secure = self.entries.get(key) orelse return null;
        if (revoke) _ = self.entries.remove(key);
        return secure;
    }
};
