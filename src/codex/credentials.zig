const std = @import("std");
const Io = std.Io;

pub const Credentials = struct {
    // Keep the original flat field names so existing SIWC records load without
    // rewriting them. Missing token fields represent a registration, not a session.
    device_id: []const u8,
    client_id: []const u8 = "",
    access_token: []const u8 = "",
    refresh_token: []const u8 = "",
    id_token: []const u8 = "",
    scope: []const u8 = "",
    expires_at: i64 = 0,
    obtained_at: i64 = 0,
    refresh_status: enum { ready, invalid_client } = .ready,

    pub fn registration(self: Credentials) Credentials {
        return .{ .device_id = self.device_id, .client_id = self.client_id };
    }
};

fn openDirectory(io: Io, directory: []const u8, create: bool) !Io.Dir {
    if (create) _ = try Io.Dir.cwd().createDirPathStatus(io, directory, .fromMode(0o700));
    return Io.Dir.cwd().openDir(io, directory, .{});
}

/// One host, one registration, and an optional token session; no locking policy.
pub fn save(allocator: std.mem.Allocator, io: Io, directory: []const u8, credentials: Credentials) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, credentials, .{});
    defer allocator.free(json);
    const dir = try openDirectory(io, directory, true);
    defer dir.close(io);
    // std.Io's atomic file uses an exclusive, unique same-directory temporary
    // for replacement, and removes it on deinit if writing or rename fails.
    var atomic = try dir.createFileAtomic(io, "codex.json", .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, json);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn load(allocator: std.mem.Allocator, io: Io, directory: []const u8) !std.json.Parsed(Credentials) {
    const dir = try openDirectory(io, directory, false);
    defer dir.close(io);

    const bytes = try dir.readFileAlloc(io, "codex.json", allocator, .unlimited);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(Credentials, allocator, bytes, .{ .allocate = .alloc_always });
}

/// Reject nonempty relative XDG_STATE_HOME rather than silently writing elsewhere.
/// Empty/unset XDG_STATE_HOME uses an absolute HOME; caller owns the result.
pub fn defaultDirectory(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |xdg| {
        if (xdg.len != 0) {
            if (!std.fs.path.isAbsolute(xdg)) return error.InvalidStateHome;
            return std.fs.path.join(allocator, &.{ xdg, "fumo-gateway" });
        }
    }

    const home = environ.get("HOME") orelse return error.HomeNotFound;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "fumo-gateway" });
}

const example: Credentials = .{ .access_token = "access", .refresh_token = "refresh", .id_token = "id", .client_id = "client", .device_id = "device", .scope = "chatgpt.tokens.use.direct", .expires_at = 123, .obtained_at = 12 };

test "roundtrip, replacement, directory and file permissions" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "credentials" });
    defer a.free(path);
    try save(a, io, path, example);
    var parsed = try load(a, io, path);
    try std.testing.expectEqualStrings("access", parsed.value.access_token);
    parsed.deinit();
    var replacement = example;
    replacement.access_token = "new";
    try save(a, io, path, replacement);
    parsed = try load(a, io, path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("new", parsed.value.access_token);
    const dir = try tmp.dir.openDir(io, "credentials", .{});
    defer dir.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try dir.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try dir.statFile(io, "codex.json", .{})).permissions.toMode() & 0o777);
}

test "default state paths" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectError(error.HomeNotFound, defaultDirectory(a, &env));
    try env.put("HOME", "/home/test");
    const home_path = try defaultDirectory(a, &env);
    defer a.free(home_path);
    try std.testing.expectEqualStrings("/home/test/.local/state/fumo-gateway", home_path);
    try env.put("XDG_STATE_HOME", "relative");
    try std.testing.expectError(error.InvalidStateHome, defaultDirectory(a, &env));
    try env.put("XDG_STATE_HOME", "/state");
    const xdg_path = try defaultDirectory(a, &env);
    defer a.free(xdg_path);
    try std.testing.expectEqualStrings("/state/fumo-gateway", xdg_path);
    try env.put("XDG_STATE_HOME", "");
    const empty_path = try defaultDirectory(a, &env);
    defer a.free(empty_path);
    try std.testing.expectEqualStrings(home_path, empty_path);
}

test "missing and malformed credentials retain JSON schema checks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    try std.testing.expectError(error.FileNotFound, load(a, io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "codex.json", .data = "{}" });
    try std.testing.expectError(error.MissingField, load(a, io, path));
}

test "saved contents are trusted without semantic or size validation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const token = try a.alloc(u8, 1024 * 1024 + 1);
    defer a.free(token);
    @memset(token, ' ');
    const saved: Credentials = .{ .device_id = "", .access_token = token };
    try save(a, io, path, saved);
    const parsed = try load(a, io, path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(saved.device_id, parsed.value.device_id);
    try std.testing.expectEqualStrings(token, parsed.value.access_token);
}

test "current flat SIWC records retain registration without usable tokens" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const file = try tmp.dir.createFile(io, "codex.json", .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io,
        \\{"device_id":"saved-host","client_id":"issued-client","access_token":"old-access","refresh_token":"old-refresh","id_token":"old-id","scope":"openid","expires_at":0,"obtained_at":12}
    );
    file.close(io);
    const old = try load(a, io, path);
    defer old.deinit();
    try save(a, io, path, old.value.registration());
    const retained = try load(a, io, path);
    defer retained.deinit();
    try std.testing.expectEqualStrings("saved-host", retained.value.device_id);
    try std.testing.expectEqualStrings("issued-client", retained.value.client_id);
    try std.testing.expectEqualStrings("", retained.value.refresh_token);
}

test "pre-SIWC records without registration metadata cannot be loaded" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const file = try tmp.dir.createFile(io, "codex.json", .{ .permissions = .fromMode(0o600) });
    try file.writeStreamingAll(io,
        \\{"access_token":"access","refresh_token":"refresh","id_token":"id","expires_at":123,"obtained_at":12}
    );
    file.close(io);
    try std.testing.expectError(error.MissingField, load(a, io, path));
    const legacy = try tmp.dir.createFile(io, "codex.json", .{ .permissions = .fromMode(0o600) });
    try legacy.writeStreamingAll(io,
        \\{"access_token":"access","refresh_token":"refresh","id_token":"id","account_id":"account","expires_at":123,"obtained_at":12}
    );
    legacy.close(io);
    try std.testing.expectError(error.UnknownField, load(a, io, path));
    try save(a, io, path, example);
    const parsed = try load(a, io, path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(example.client_id, parsed.value.client_id);
}
