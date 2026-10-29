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
        var tmp = std.testing.tmpDir(.{});
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

test "session provider owns credential loading and authorization snapshots" {
    const Provider = @import("provider").Provider;
    var storage = try Storage.init(3600);
    defer storage.deinit();
    var provider = try Provider.init(a, io, .{
        .url = "https://api.openai.com/v1/responses",
        .models = .{},
        .auth = .{ .provider = .codex, .credentials_dir = storage.path },
    });
    defer provider.deinit();
    const header = (try provider.authorization(a)).?;
    defer a.free(header);
    try std.testing.expectEqualStrings("Bearer old-access", header);
    try std.testing.expect(!provider.session.?.refreshing);
    var plain = try Provider.init(a, io, .{ .url = "http://localhost/v1/responses", .models = .{} });
    defer plain.deinit();
    try std.testing.expectEqual(null, try plain.authorization(a));
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
    for (0..4) |_| try std.testing.expectError(error.CredentialsUnavailable, session.authorization(a));
    try fixture.waitRequest();
    gate.post(io);
    try session.workers.await(io);
    try authorize(&session, "Bearer new-access");
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
            },
            .invalid_client => {
                try storage.expectSaved("old-access");
                var restarted = try Session.init(a, io, storage.path);
                defer restarted.deinit();
                configure(&restarted, origin);
                try authorize(&restarted, "Bearer old-access");
                try std.testing.expect(!restarted.refreshing);
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
