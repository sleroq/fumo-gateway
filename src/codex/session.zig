const std = @import("std");
const storage = @import("credentials.zig");
const Refresh = @import("../codex.zig").Refresh;
const Io = std.Io;

/// Service-owned credentials. Keep at a stable address after init, use a
/// thread-safe allocator, and finish request calls before deinit. Options may
/// only be changed before the first authorization call.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: Io,
    directory: []const u8,
    current: std.json.Parsed(storage.Credentials),
    options: Options = .{},
    mutex: Io.Mutex = .init,
    workers: Io.Group = .init,
    refreshing: bool = false,
    retry_at: ?Io.Timestamp = null,

    pub const Options = struct {
        origin: []const u8 = "https://auth.openai.com",
        timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake },
        refresh_lead_seconds: i64 = 300,
        retry_delay: Io.Duration = .fromSeconds(30),
    };

    pub fn init(allocator: std.mem.Allocator, io: Io, directory: []const u8) !Session {
        const owned_directory = try allocator.dupe(u8, directory);
        errdefer allocator.free(owned_directory);
        const current = try storage.load(allocator, io, directory);
        errdefer current.deinit();
        return .{ .allocator = allocator, .io = io, .directory = owned_directory, .current = current };
    }

    /// Never waits for token exchange. The returned header belongs to the
    /// request, so rotation cannot invalidate an in-flight upstream request.
    pub fn authorization(self: *Session, request_allocator: std.mem.Allocator) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const now: i64 = @intCast(Io.Clock.real.now(self.io).toSeconds());
        if (needsRefresh(self.current.value.expires_at, now, self.options.refresh_lead_seconds))
            self.startRefresh();
        if (self.current.value.expires_at <= now) return error.CredentialsUnavailable;
        return request_allocator.print("Bearer {s}", .{self.current.value.access_token});
    }

    pub fn deinit(self: *Session) void {
        // Cancellation is limited to the exchange. A successful exchange's
        // persistence and publication finish before this join can return.
        self.workers.cancel(self.io);
        self.current.deinit();
        self.allocator.free(self.directory);
        self.* = undefined;
    }

    /// Called with the mutex held. concurrent, unlike async, cannot execute the
    /// worker inline or tie its lifetime to the requesting task.
    fn startRefresh(self: *Session) void {
        if (self.refreshing or self.current.value.refresh_token.len == 0 or self.current.value.refresh_status == .invalid_client) return;
        if (self.retry_at) |retry_at| {
            if (Io.Timestamp.compare(Io.Clock.awake.now(self.io), .lt, retry_at)) return;
        }
        self.refreshing = true;
        self.workers.concurrent(self.io, refresh, .{self}) catch |err| {
            self.finishFailure(err);
        };
    }

    fn refresh(self: *Session) void {
        self.rotate() catch |err| {
            const retained = Refresh.recovery(self.current.value, err);
            if (retained) |credentials| {
                const protection = self.io.swapCancelProtection(.blocked);
                defer _ = self.io.swapCancelProtection(protection);
                storage.save(self.allocator, self.io, self.directory, credentials) catch |save_err| {
                    std.log.err("event=siwc_recovery_save_failed error={s}", .{@errorName(save_err)});
                };
            }
            self.mutex.lockUncancelable(self.io);
            if (retained) |credentials| self.current.value = credentials;
            self.finishFailure(err);
            self.mutex.unlock(self.io);
            std.log.warn("event=siwc_refresh_failed error={s}", .{@errorName(err)});
            if (err == error.ReauthenticationRequired) std.log.warn("Run auth login codex with the same credentials directory to reauthorize the saved registration.", .{});
            if (err == error.InvalidClient) std.log.warn("SIWC renewal stopped: check the saved client configuration before reauthorizing.", .{});
        };
    }

    fn rotate(self: *Session) !void {
        // No other worker can replace current, and deinit joins us first.
        // Keep a complete replacement arena ready before committing to disk.
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        var exchange: Refresh = .{
            .http = .{ .allocator = self.allocator, .io = self.io },
            .origin = self.options.origin,
            .timeout = self.options.timeout,
        };
        defer exchange.http.deinit();
        const replacement = try exchange.exchange(arena.allocator(), self.current.value);
        // Atomic save and bookkeeping form one uncancelable commit. No mutex
        // is held during network or file I/O; requests still use the old token.
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        try storage.save(self.allocator, self.io, self.directory, replacement);
        self.mutex.lockUncancelable(self.io);
        const previous = self.current;
        self.current = .{ .arena = arena, .value = replacement };
        self.refreshing = false;
        self.retry_at = null;
        self.mutex.unlock(self.io);
        previous.deinit();
    }

    /// Called with the mutex held, including after cancellation.
    fn finishFailure(self: *Session, err: anyerror) void {
        self.refreshing = false;
        if (err == error.ReauthenticationRequired or err == error.InvalidClient) {
            self.retry_at = null;
        } else {
            self.retry_at = Io.Clock.awake.now(self.io).addDuration(self.options.retry_delay);
        }
    }
};

fn needsRefresh(expires_at: i64, now: i64, lead: i64) bool {
    return @as(i128, expires_at) - now <= lead;
}

test "refresh lead includes the boundary and expired credentials" {
    try std.testing.expect(!needsRefresh(1301, 1000, 300));
    try std.testing.expect(needsRefresh(1300, 1000, 300));
    try std.testing.expect(needsRefresh(1001, 1000, 300));
    try std.testing.expect(needsRefresh(1000, 1000, 300));
    try std.testing.expect(needsRefresh(999, 1000, 300));
}
