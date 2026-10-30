const std = @import("std");
const Session = @import("provider").Session;
const local = @import("fixture");
const a = std.testing.allocator;
const io = std.testing.io;
const success_body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"id_token\":\"new-id\",\"expires_in\":3600,\"scope\":\"chatgpt.tokens.use.direct\"}";
const success = response("200 OK", success_body);
const transient = response("500 Internal Server Error", "{\"error\":\"server_error\"}");
const invalid = response("400 Bad Request", "{\"error\":\"refresh_token_reused\"}");
const invalid_client = response("400 Bad Request", "{\"error\":\"invalid_client\"}");

fn response(comptime status: []const u8, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body });
}

const Storage = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    fn init(lifetime: i64) !Storage {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.setPermissions(io, .fromMode(0o700));
        const path = try tmp.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(path);
        const now: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
        const json = try a.print("{{\"access_token\":\"old-access\",\"refresh_token\":\"old-refresh\",\"id_token\":\"old-id\",\"client_id\":\"client\",\"device_id\":\"device\",\"scope\":\"chatgpt.tokens.use.direct\",\"obtained_at\":{d},\"expires_at\":{d}}}", .{ now - 3600, now + lifetime });
        defer a.free(json);
        const file = try tmp.dir.createFile(io, "codex.json", .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, json);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Storage) void {
        a.free(self.path);
        self.tmp.cleanup();
    }

    fn expectSaved(self: *Storage, token: []const u8) !void {
        const file = try self.tmp.dir.openFile(io, "codex.json", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        const n = try file.readPositionalAll(io, &buffer, 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, buffer[0..n], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(token, parsed.value.object.get("access_token").?.string);
    }
};

fn authorize(session: *Session, expected: []const u8) anyerror!void {
    const header = try session.authorization(a);
    defer a.free(header);
    try std.testing.expectEqualStrings(expected, header);
}

fn configure(session: *Session, origin: []const u8) void {
    session.options.origin = origin;
    session.options.timeout = .{ .raw = .fromSeconds(2), .clock = .awake };
}

test "session registry accounts own credentials and providers borrow authorization" {
    const Registry = @import("provider").Registry;
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var registry = try Registry.init(a, io, &.{
        .{ .name = "codex", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = storage.path } },
        .{ .name = "public", .base_url = "http://localhost/v1" },
    });
    defer registry.deinit();
    try std.testing.expectEqual(1, registry.accounts.len);
    try std.testing.expect(registry.entries[0].account == &registry.accounts[0]);
    const header = (try registry.entries[0].authorization(a)).?;
    defer a.free(header);
    try std.testing.expectEqualStrings("Bearer old-access", header);
    try std.testing.expect(!registry.accounts[0].session.refreshing);
    try std.testing.expectEqual(null, registry.entries[1].account);
    try std.testing.expectEqual(null, try registry.entries[1].authorization(a));
    try registry.accounts[0].session.disconnect();
    try std.testing.expectError(error.CredentialsUnavailable, registry.entries[0].authorization(a));
    try std.testing.expectEqualStrings("Bearer old-access", header);
}

test "session fresh session stays idle" {
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    for (0..4) |_| try authorize(&session, "Bearer old-access");
    try std.testing.expect(!session.refreshing);
    try storage.expectSaved("old-access");
}

test "session concurrent near-expiry requests are nonblocking singleflight and own headers across durable rotation" {
    var storage = try Storage.init(60);
    defer storage.deinit();
    var gate: std.Io.Semaphore = .{};
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = "", .gate = &gate, .tail = success }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    const retained = try session.authorization(a);
    defer a.free(retained);
    try fixture.waitRequest();
    var requests: [8]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (requests[0..started]) |*request| {
        _ = request.cancel(io) catch {};
    };
    for (&requests) |*request| {
        request.* = try io.concurrent(authorize, .{ &session, "Bearer old-access" });
        started += 1;
    }
    for (&requests) |*request| try request.await(io);
    try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
    const raw = fixture.requests[0].?;
    try std.testing.expect(std.mem.startsWith(u8, raw, "POST /api/accounts/oauth/token HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.find(u8, raw, "refresh_token=old-refresh") != null);
    try std.testing.expect(std.mem.find(u8, raw, "Authorization:") == null);
    gate.post(io);
    try session.workers.await(io);
    try authorize(&session, "Bearer new-access");
    try storage.expectSaved("new-access");
    try std.testing.expectEqualStrings("Bearer old-access", retained);
}

test "session expired session remains unavailable until successful rotation" {
    var storage = try Storage.init(-1);
    defer storage.deinit();
    var gate: std.Io.Semaphore = .{};
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = "", .gate = &gate, .tail = success }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    try std.testing.expectEqual(.connected, (try session.status()).status);
    try std.testing.expect(!session.refreshing);
    for (0..4) |_| try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
    try fixture.waitRequest();
    try std.testing.expectEqual(.connected, (try session.status()).status);
    gate.post(io);
    try session.workers.await(io);
    try authorize(&session, "Bearer new-access");
    try std.testing.expectEqual(.connected, (try session.status()).status);
}

test "session status distinguishes refreshable credentials from reauthentication" {
    var storage = try Storage.init(-1);
    defer storage.deinit();
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    const saved = session.current.value;
    const State = @FieldType(Session.Status, "status");
    const cases = [_]struct { access: []const u8, refresh: []const u8, client: []const u8, invalid_client: bool = false, fresh: bool = false, expected: State }{
        .{ .access = "access", .refresh = "refresh", .client = "client", .fresh = true, .expected = .connected },
        .{ .access = "access", .refresh = "refresh", .client = "client", .expected = .connected },
        .{ .access = "access", .refresh = "", .client = "client", .expected = .login_required },
        .{ .access = "access", .refresh = "refresh", .client = "client", .invalid_client = true, .expected = .login_required },
        .{ .access = "access", .refresh = "refresh", .client = "client", .invalid_client = true, .fresh = true, .expected = .login_required },
        .{ .access = "", .refresh = "", .client = "client", .expected = .login_required },
        .{ .access = "", .refresh = "", .client = "", .expected = .login_required },
    };
    for (cases) |case| {
        session.current.value = saved;
        session.current.value.access_token = case.access;
        session.current.value.refresh_token = case.refresh;
        session.current.value.client_id = case.client;
        session.current.value.refresh_status = if (case.invalid_client) .invalid_client else .ready;
        session.current.value.expires_at = if (case.fresh) saved.expires_at + 3600 else saved.expires_at;
        try std.testing.expectEqual(case.expected, (try session.status()).status);
        try std.testing.expect(!session.refreshing);
    }
}

test "session expired credentials remain refreshable after transient failure" {
    var storage = try Storage.init(-1);
    defer storage.deinit();
    var fixture = try local.Fixture.init(a, io, &.{ .{ .bytes = transient }, .{ .bytes = success } });
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
    try session.workers.await(io);
    try std.testing.expectEqual(.connected, (try session.status()).status);
    try std.testing.expect(session.retry_at != null);
    try storage.expectSaved("old-access");
    session.retry_at = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(-1));
    try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
    try session.workers.await(io);
    try std.testing.expectEqual(.connected, (try session.status()).status);
}

test "session failed durable save never publishes replacement" {
    var storage = try Storage.init(60);
    defer storage.deinit();
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = success }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    try storage.tmp.dir.rename("codex.json", storage.tmp.dir, "backup.json", io);
    try storage.tmp.dir.createDir(io, "codex.json", .default_dir);
    try authorize(&session, "Bearer old-access");
    try session.workers.await(io);
    try authorize(&session, "Bearer old-access");
    try storage.tmp.dir.deleteDir(io, "codex.json");
    try storage.tmp.dir.rename("backup.json", storage.tmp.dir, "codex.json", io);
    try storage.expectSaved("old-access");
    try std.testing.expect(session.retry_at != null);
}

test "session transient failures retry; unusable renewal and invalid client survive restart without retry" {
    const Failure = enum { transient, unusable, invalid_client };
    for (std.enums.values(Failure)) |failure| {
        const terminal = failure != .transient;
        var storage = try Storage.init(60);
        defer storage.deinit();
        var fixture = try local.Fixture.init(a, io, &.{ .{ .bytes = switch (failure) {
            .transient => transient,
            .unusable => invalid,
            .invalid_client => invalid_client,
        } }, .{ .bytes = success } });
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var session = try Session.init(a, io, storage.path);
        defer session.deinit();
        configure(&session, origin);
        try authorize(&session, "Bearer old-access");
        try session.workers.await(io);
        const expected_status: @FieldType(Session.Status, "status") = if (terminal) .login_required else .connected;
        try std.testing.expectEqual(expected_status, (try session.status()).status);
        if (failure == .unusable) {
            try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
            try std.testing.expectEqualStrings("client", session.current.value.client_id);
            try std.testing.expectEqualStrings("device", session.current.value.device_id);
        } else for (0..4) |_| try authorize(&session, "Bearer old-access");
        try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
        // Move the recorded deadline into the past instead of sleeping through
        // a wall-clock cooldown. There is no worker after the join above.
        session.retry_at = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(-1));
        try std.testing.expect(!session.refreshing);
        try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
        if (failure == .unusable) {
            try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
        } else try authorize(&session, "Bearer old-access");
        try session.workers.await(io);
        try std.testing.expectEqual(@as(usize, if (terminal) 1 else 2), fixture.count.load(.acquire));
        switch (failure) {
            .unusable => {
                try storage.expectSaved("");
                var restarted = try Session.init(a, io, storage.path);
                defer restarted.deinit();
                try std.testing.expectError(error.CredentialsUnavailable, restarted.authorization(a));
                try std.testing.expectEqual(.login_required, (try restarted.status()).status);
            },
            .invalid_client => {
                try storage.expectSaved("old-access");
                var restarted = try Session.init(a, io, storage.path);
                defer restarted.deinit();
                configure(&restarted, origin);
                try authorize(&restarted, "Bearer old-access");
                try std.testing.expect(!restarted.refreshing);
                try std.testing.expectEqual(.login_required, (try restarted.status()).status);
            },
            .transient => {
                try authorize(&session, "Bearer new-access");
                try storage.expectSaved("new-access");
            },
        }
    }
}

test "session shutdown cancels hung exchange and closes peer without opening response gate" {
    var storage = try Storage.init(60);
    defer storage.deinit();
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = "", .peer_eof = true }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    configure(&session, origin);
    try authorize(&session, "Bearer old-access");
    try fixture.waitRequest();
    const shutdown_started = std.Io.Clock.awake.now(io);
    session.deinit();
    try std.testing.expect(shutdown_started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1000);
    try fixture.waitEof();
    try storage.expectSaved("old-access");
}

fn pastedCallback(url: []const u8) ![]u8 {
    const start = (std.mem.find(u8, url, "&state=") orelse return error.TestUnexpectedResult) + 7;
    const end = std.mem.findScalarPos(u8, url, start, '&') orelse url.len;
    return a.print("http://127.0.0.1:1455/auth/callback?state={s}&code=local-code&client_id=client", .{url[start..end]});
}

test "session disconnected login validates callback then activates and persists" {
    var storage = try Storage.init(3600);
    defer storage.deinit();
    try storage.tmp.dir.deleteFile(io, "codex.json");
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = success }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    try std.testing.expectEqual(.login_required, (try session.status()).status);
    try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
    const started = try session.startAuth(a);
    defer a.free(started.authorization_url);
    try std.testing.expectEqual(300, started.expires_in);
    try std.testing.expect((try session.status()).pending);
    const replacement = try session.startAuth(a);
    defer a.free(replacement.authorization_url);
    const obsolete_callback = try pastedCallback(started.authorization_url);
    defer a.free(obsolete_callback);
    try std.testing.expectError(error.InvalidState, session.completeAuth(obsolete_callback));
    try std.testing.expectError(error.InvalidState, session.completeAuth("http://127.0.0.1:1455/auth/callback?state=wrong&code=c&client_id=client"));
    try std.testing.expectEqual(@as(usize, 0), fixture.count.load(.acquire));
    const callback = try pastedCallback(replacement.authorization_url);
    defer a.free(callback);
    try session.completeAuth(callback);
    try authorize(&session, "Bearer new-access");
    try storage.expectSaved("new-access");
    try std.testing.expectEqual(.connected, (try session.status()).status);
    try std.testing.expect(!(try session.status()).pending);
    try std.testing.expectError(error.NoPendingLogin, session.completeAuth(callback));
}

test "session expired login and failed persistence preserve active credentials" {
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = success }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    const expired = try session.startAuth(a);
    defer a.free(expired.authorization_url);
    session.pending.?.expires = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(-1));
    try std.testing.expectError(error.LoginExpired, session.completeAuth("unused"));
    try authorize(&session, "Bearer old-access");
    const started = try session.startAuth(a);
    defer a.free(started.authorization_url);
    const callback = try pastedCallback(started.authorization_url);
    defer a.free(callback);
    try storage.tmp.dir.rename("codex.json", storage.tmp.dir, "saved.json", io);
    try storage.tmp.dir.createDir(io, "codex.json", .default_dir);
    try std.testing.expectError(error.CredentialSaveFailed, session.completeAuth(callback));
    try authorize(&session, "Bearer old-access");
    try storage.tmp.dir.deleteDir(io, "codex.json");
    try storage.tmp.dir.rename("saved.json", storage.tmp.dir, "codex.json", io);
    try storage.expectSaved("old-access");
}

test "session reconnect fences stale refresh success and terminal recovery" {
    for ([_][]const u8{ success, invalid }) |old_reply| {
        var storage = try Storage.init(30);
        defer storage.deinit();
        var gate: std.Io.Semaphore = .{};
        var refresh_fixture = try local.Fixture.init(a, io, &.{.{ .bytes = "", .gate = &gate, .tail = old_reply }});
        defer refresh_fixture.deinit();
        try refresh_fixture.start();
        var login_fixture = try local.Fixture.init(a, io, &.{.{ .bytes = response("200 OK", "{\"access_token\":\"login-access\",\"refresh_token\":\"login-refresh\",\"id_token\":\"login-id\",\"expires_in\":3600,\"scope\":\"chatgpt.tokens.use.direct\"}") }});
        defer login_fixture.deinit();
        try login_fixture.start();
        const refresh_origin = try refresh_fixture.origin(a);
        defer a.free(refresh_origin);
        const login_origin = try login_fixture.origin(a);
        defer a.free(login_origin);
        var session = try Session.init(a, io, storage.path);
        defer session.deinit();
        configure(&session, refresh_origin);
        const snapshot = try session.authorization(a);
        defer a.free(snapshot);
        try refresh_fixture.waitRequest();
        session.options.origin = login_origin;
        const started = try session.startAuth(a);
        defer a.free(started.authorization_url);
        const callback = try pastedCallback(started.authorization_url);
        defer a.free(callback);
        try session.completeAuth(callback);
        gate.post(io);
        try session.workers.await(io);
        try authorize(&session, "Bearer login-access");
        try std.testing.expectEqualStrings("Bearer old-access", snapshot);
        try storage.expectSaved("login-access");
    }
}

fn completeAuth(session: *Session, callback: []const u8) !void {
    try session.completeAuth(callback);
}

test "session reconnect exchange leaves healthy authorization and status available" {
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var gate: std.Io.Semaphore = .{};
    var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = "", .gate = &gate, .tail = success }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    configure(&session, origin);
    const started = try session.startAuth(a);
    defer a.free(started.authorization_url);
    try std.testing.expectEqual(300, started.expires_in);
    const pending_seconds = std.Io.Clock.awake.now(io).durationTo(session.pending.?.expires).toSeconds();
    try std.testing.expect(pending_seconds >= 299 and pending_seconds <= 300);
    const callback = try pastedCallback(started.authorization_url);
    defer a.free(callback);
    var login = try io.concurrent(completeAuth, .{ &session, callback });
    defer _ = login.cancel(io) catch {};
    try fixture.waitRequest();
    try authorize(&session, "Bearer old-access");
    try std.testing.expectEqual(.connected, (try session.status()).status);
    try std.testing.expect((try session.status()).pending);
    gate.post(io);
    try login.await(io);
    try authorize(&session, "Bearer new-access");
}

test "session disconnect persists registration invalidates pending and survives restart" {
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    const snapshot = try session.authorization(a);
    defer a.free(snapshot);
    const started = try session.startAuth(a);
    defer a.free(started.authorization_url);
    session.retry_at = std.Io.Clock.awake.now(io);
    try session.disconnect();
    try std.testing.expectEqual(.login_required, (try session.status()).status);
    try std.testing.expect(!(try session.status()).pending);
    try std.testing.expect(session.retry_at == null);
    try std.testing.expectError(error.NoPendingLogin, session.completeAuth("unused"));
    try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
    try std.testing.expectEqualStrings("Bearer old-access", snapshot);
    var restarted = try Session.init(a, io, storage.path);
    defer restarted.deinit();
    try std.testing.expectEqual(.login_required, (try restarted.status()).status);
    try std.testing.expectEqualStrings("client", restarted.current.value.client_id);
    try std.testing.expectEqualStrings("device", restarted.current.value.device_id);
    try std.testing.expectEqualStrings("", restarted.current.value.refresh_token);
    try std.testing.expectEqualStrings("", restarted.current.value.access_token);
}

test "session disconnect failed save preserves credentials pending and retry" {
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var session = try Session.init(a, io, storage.path);
    defer session.deinit();
    const started = try session.startAuth(a);
    defer a.free(started.authorization_url);
    session.retry_at = std.Io.Clock.awake.now(io);
    const generation = session.generation;
    try storage.tmp.dir.rename("codex.json", storage.tmp.dir, "saved.json", io);
    try storage.tmp.dir.createDir(io, "codex.json", .default_dir);
    try std.testing.expectError(error.CredentialSaveFailed, session.disconnect());
    try authorize(&session, "Bearer old-access");
    try std.testing.expect((try session.status()).pending);
    try std.testing.expect(session.retry_at != null);
    try std.testing.expectEqual(generation, session.generation);
    try storage.tmp.dir.deleteDir(io, "codex.json");
    try storage.tmp.dir.rename("saved.json", storage.tmp.dir, "codex.json", io);
    try storage.expectSaved("old-access");
}

test "session disconnect fences stale refresh success and terminal recovery" {
    for ([_][]const u8{ success, invalid, invalid_client }) |reply| {
        var storage = try Storage.init(30);
        defer storage.deinit();
        var gate: std.Io.Semaphore = .{};
        var fixture = try local.Fixture.init(a, io, &.{.{ .bytes = "", .gate = &gate, .tail = reply }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var session = try Session.init(a, io, storage.path);
        defer session.deinit();
        configure(&session, origin);
        try authorize(&session, "Bearer old-access");
        try fixture.waitRequest();
        try session.disconnect();
        gate.post(io);
        try session.workers.await(io);
        try std.testing.expectEqual(.login_required, (try session.status()).status);
        try std.testing.expectEqualStrings("client", session.current.value.client_id);
        var restarted = try Session.init(a, io, storage.path);
        defer restarted.deinit();
        try std.testing.expectEqual(.login_required, (try restarted.status()).status);
        try std.testing.expectEqualStrings("client", restarted.current.value.client_id);
    }
}
