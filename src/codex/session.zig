const std = @import("std");
const storage = @import("credentials.zig");
const codex = @import("../codex.zig");
const Refresh = codex.Refresh;
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
    login_mutex: Io.Mutex = .init,
    workers: Io.Group = .init,
    refreshing: bool = false,
    retry_at: ?Io.Timestamp = null,
    generation: u64 = 0,
    pending: ?Pending = null,

    const redirect_uri = "http://127.0.0.1:1455/auth/callback";
    const Pending = struct {
        arena: std.heap.ArenaAllocator,
        authorization: codex.Authorization,
        expires: Io.Timestamp,
    };
    pub const LoginStart = struct { authorization_url: []const u8, expires_in: u64 };

    pub const Status = struct { status: enum { connected, login_required }, pending: bool };

    pub fn status(self: *Session) !Status {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const now: i64 = @intCast(Io.Clock.real.now(self.io).toSeconds());
        const credentials = self.current.value;
        return .{
            .status = if (credentials.refresh_status != .invalid_client and
                (credentials.expires_at > now or credentials.refresh_token.len != 0))
                .connected
            else
                .login_required,
            .pending = if (self.pending) |pending| Io.Timestamp.compare(Io.Clock.awake.now(self.io), .lt, pending.expires) else false,
        };
    }

    pub fn disconnect(self: *Session) !void {
        try self.login_mutex.lock(self.io);
        defer self.login_mutex.unlock(self.io);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const retained = self.current.value.registration();
        storage.save(self.allocator, self.io, self.directory, retained) catch |err| switch (err) {
            error.Canceled => return err,
            else => return error.CredentialSaveFailed,
        };
        // Registration borrows the current arena; retain it until replacement.
        self.current.value = retained;
        self.generation += 1;
        self.retry_at = null;
        if (self.pending) |*pending| pending.arena.deinit();
        self.pending = null;
    }

    pub fn startAuth(self: *Session, allocator: std.mem.Allocator) !LoginStart {
        try self.login_mutex.lock(self.io);
        defer self.login_mutex.unlock(self.io);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending) |*pending| {
            pending.arena.deinit();
            self.pending = null;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const saved = self.current.value;
        const device = if (saved.device_id.len != 0) saved.device_id else &(try codex.deviceId(self.io));
        const owned = try arena.allocator().dupe(u8, device);
        const client = try arena.allocator().dupe(u8, saved.client_id);
        const authorization_state = try codex.Authorization.init(self.io, .{ .device_id = owned, .client_id = client });
        const url = try authorization_state.url(allocator, self.options.origin, redirect_uri);
        self.pending = .{ .arena = arena, .authorization = authorization_state, .expires = Io.Clock.awake.now(self.io).addDuration(.fromSeconds(300)) };
        return .{ .authorization_url = url, .expires_in = 300 };
    }

    pub fn completeAuth(self: *Session, callback_url: []const u8) !void {
        try self.login_mutex.lock(self.io);
        defer self.login_mutex.unlock(self.io);
        try self.mutex.lock(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);
        const pending = if (self.pending) |*value| value else return error.NoPendingLogin;
        if (!Io.Timestamp.compare(Io.Clock.awake.now(self.io), .lt, pending.expires)) {
            pending.arena.deinit();
            self.pending = null;
            return error.LoginExpired;
        }
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const grant = try @import("callback.zig").pasted(arena.allocator(), callback_url, &pending.authorization.state, pending.authorization.client_id);
        var exchange: codex.Login = .{ .http = .{ .allocator = self.allocator, .io = self.io }, .origin = self.options.origin };
        defer exchange.http.deinit();
        self.mutex.unlock(self.io);
        locked = false;
        var completed: Io.Semaphore = .{};
        var task = try self.io.concurrent(exchangeLogin, .{ &exchange, arena.allocator(), grant, &pending.authorization, &completed });
        defer _ = task.cancel(self.io) catch {};
        completed.waitTimeout(self.io, .{ .deadline = .{ .raw = pending.expires, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => return error.LoginExpired,
            else => return err,
        };
        const credentials = try task.await(self.io);
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.mutex.lockUncancelable(self.io);
        locked = true;
        storage.save(self.allocator, self.io, self.directory, credentials) catch |err| switch (err) {
            error.Canceled => return err,
            else => return error.CredentialSaveFailed,
        };
        const previous = self.current;
        self.current = .{ .arena = arena, .value = credentials };
        self.generation += 1;
        self.retry_at = null;
        pending.arena.deinit();
        self.pending = null;
        previous.deinit();
    }

    fn exchangeLogin(exchange: *codex.Login, allocator: std.mem.Allocator, grant: @import("callback.zig").Grant, authorization_state: *const codex.Authorization, completed: *Io.Semaphore) !storage.Credentials {
        defer completed.post(exchange.http.io);
        return exchange.exchange(allocator, grant, authorization_state, redirect_uri);
    }

    pub const Options = struct {
        origin: []const u8 = "https://auth.openai.com",
        timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake },
        refresh_lead_seconds: i64 = 300,
        retry_delay: Io.Duration = .fromSeconds(30),
    };

    pub fn init(allocator: std.mem.Allocator, io: Io, directory: []const u8) !Session {
        const owned_directory = try allocator.dupe(u8, directory);
        errdefer allocator.free(owned_directory);
        const current = storage.load(allocator, io, directory) catch |err| switch (err) {
            error.FileNotFound => try std.json.parseFromSlice(storage.Credentials, allocator, "{\"device_id\":\"\"}", .{ .allocate = .alloc_always }),
            else => return err,
        };
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
        if (self.pending) |*pending| pending.arena.deinit();
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
        self.mutex.lockUncancelable(self.io);
        const generation = self.generation;
        // The exchange owns a deep snapshot: login may replace current while
        // this worker is waiting for the token endpoint.
        const bytes = std.json.Stringify.valueAlloc(self.allocator, self.current.value, .{}) catch |err| {
            self.finishFailure(err);
            self.mutex.unlock(self.io);
            return;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(bytes);
        const snapshot = std.json.parseFromSlice(storage.Credentials, self.allocator, bytes, .{ .allocate = .alloc_always }) catch |err| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.finishFailure(err);
            return;
        };
        defer snapshot.deinit();
        self.rotate(snapshot.value, generation) catch |err| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (generation != self.generation) {
                self.refreshing = false;
                return;
            }
            if (Refresh.recovery(self.current.value, err)) |retained| {
                const protection = self.io.swapCancelProtection(.blocked);
                defer _ = self.io.swapCancelProtection(protection);
                storage.save(self.allocator, self.io, self.directory, retained) catch |save_err| {
                    self.finishFailure(save_err);
                    return;
                };
                self.current.value = retained;
            }
            self.finishFailure(err);
            std.log.warn("event=siwc_refresh_failed error={s}", .{@errorName(err)});
        };
    }

    fn rotate(self: *Session, snapshot: storage.Credentials, generation: u64) !void {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        var published = false;
        defer if (!published) {
            arena.deinit();
            self.allocator.destroy(arena);
        };
        var exchange: Refresh = .{
            .http = .{ .allocator = self.allocator, .io = self.io },
            .origin = self.options.origin,
            .timeout = self.options.timeout,
        };
        defer exchange.http.deinit();
        const replacement = try exchange.exchange(arena.allocator(), snapshot);
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (generation != self.generation) {
            self.refreshing = false;
            return;
        }
        try storage.save(self.allocator, self.io, self.directory, replacement);
        const previous = self.current;
        self.current = .{ .arena = arena, .value = replacement };
        published = true;
        self.refreshing = false;
        self.retry_at = null;
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
