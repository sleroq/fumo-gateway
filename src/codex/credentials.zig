const std = @import("std");
const Io = std.Io;
const max_size = 1024 * 1024;

/// Structural validation only: persisted tokens are not proof of authentication.
pub const Credentials = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    id_token: []const u8,
    client_id: []const u8,
    device_id: []const u8,
    scope: []const u8,
    expires_at: i64,
    obtained_at: i64,

    pub fn validate(self: Credentials) !void {
        inline for (.{ "access_token", "refresh_token", "id_token", "client_id", "device_id", "scope" }) |field| {
            if (std.mem.trim(u8, @field(self, field), " \t\r\n\x0b\x0c").len == 0)
                return error.InvalidCredentials;
        }
        // Access tokens are inserted into an HTTP Bearer header by the service.
        for (self.access_token) |byte| {
            if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return error.InvalidCredentials;
        }
        if (self.expires_at <= 0) return error.InvalidCredentials;
        var scopes = std.mem.tokenizeAny(u8, self.scope, " \t\r\n\x0b\x0c");
        while (scopes.next()) |scope| {
            if (std.mem.eql(u8, scope, "chatgpt.tokens.use.direct")) return;
        }
        return error.InvalidCredentials;
    }
};

fn openDirectory(io: Io, directory: []const u8, create: bool) !Io.Dir {
    const path = std.mem.trimEnd(u8, directory, "/");
    if (path.len == 0 or std.mem.eql(u8, std.fs.path.basename(path), ".") or
        std.mem.eql(u8, std.fs.path.basename(path), "..")) return error.InvalidDirectory;
    if (create) _ = try Io.Dir.cwd().createDirPathStatus(io, path, .fromMode(0o700));
    const dir = try Io.Dir.cwd().openDir(io, path, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    try privatePermissions(try dir.stat(io));
    return dir;
}

fn privatePermissions(stat: Io.File.Stat) !void {
    if (stat.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
}

fn checkFile(stat: Io.File.Stat) !void {
    if (stat.kind == .sym_link) return error.SymlinkNotAllowed;
    if (stat.kind != .file) return error.InvalidCredentialFile;
    try privatePermissions(stat);
}

fn checkExistingFile(io: Io, dir: Io.Dir) !void {
    if (dir.statFile(io, "codex.json", .{ .follow_symlinks = false })) |stat| {
        try checkFile(stat);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

/// Check private storage before browser authentication without reading or writing credentials.
pub fn preflight(io: Io, directory: []const u8) !void {
    const dir = try openDirectory(io, directory, true);
    defer dir.close(io);
    try checkExistingFile(io, dir);
}

/// Explicit login replaces the one provider credential; no merge or locking policy.
pub fn save(allocator: std.mem.Allocator, io: Io, directory: []const u8, credentials: Credentials) !void {
    try credentials.validate();
    const json = try std.json.Stringify.valueAlloc(allocator, credentials, .{});
    defer allocator.free(json);
    if (json.len > max_size) return error.CredentialsTooLarge;
    const dir = try openDirectory(io, directory, true);
    defer dir.close(io);
    try checkExistingFile(io, dir);
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
    const file = try dir.openFile(io, "codex.json", .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try checkFile(stat);
    if (stat.size > max_size) return error.CredentialsTooLarge;
    // Read at most limit+1, also bounding files that grow after stat.
    const bytes = try allocator.alloc(u8, max_size + 1);
    defer allocator.free(bytes);
    const len = try file.readPositionalAll(io, bytes, 0);
    if (len > max_size) return error.CredentialsTooLarge;
    const parsed = try std.json.parseFromSlice(Credentials, allocator, bytes[0..len], .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
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
    try preflight(io, path);
    try std.testing.expectError(error.FileNotFound, load(a, io, path));
    try save(a, io, path, example);
    try preflight(io, path);
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
    try dir.setFilePermissions(io, "codex.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.InsecurePermissions, load(a, io, path));
    try std.testing.expectError(error.InsecurePermissions, preflight(io, path));
    try dir.setPermissions(io, .fromMode(0o755));
    try std.testing.expectError(error.InsecurePermissions, save(a, io, path, example));
}

test "required values and expiry" {
    var invalid = example;
    invalid.refresh_token = " \t\n";
    try std.testing.expectError(error.InvalidCredentials, invalid.validate());
    invalid = example;
    invalid.expires_at = 0;
    try std.testing.expectError(error.InvalidCredentials, invalid.validate());
    for ([_][]const u8{ "access token", "access\ttoken", "access\r\nx-header: value", "access\x00", "access\x7f" }) |token| {
        invalid = example;
        invalid.access_token = token;
        try std.testing.expectError(error.InvalidCredentials, invalid.validate());
    }
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

test "missing, malformed, oversized and symlink credentials are rejected" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    try std.testing.expectError(error.FileNotFound, load(a, io, path));
    const file = try tmp.dir.createFile(io, "codex.json", .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, "{}");
    try std.testing.expectError(error.MissingField, load(a, io, path));
    try file.writePositionalAll(io, " ", max_size);
    try std.testing.expectError(error.CredentialsTooLarge, load(a, io, path));
    try tmp.dir.deleteFile(io, "codex.json");
    try tmp.dir.symLink(io, "missing", "codex.json", .{});
    try std.testing.expectError(error.SymlinkNotAllowed, save(a, io, path, example));
    try std.testing.expectError(error.SymlinkNotAllowed, preflight(io, path));
    if (load(a, io, path)) |parsed| {
        parsed.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    try tmp.dir.symLink(io, ".", "linked", .{ .is_directory = true });
    const linked = try std.fs.path.join(a, &.{ path, "linked" });
    defer a.free(linked);
    if (save(a, io, linked, example)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "SIWC metadata and exact direct scope are required" {
    inline for (.{ "access_token", "refresh_token", "id_token", "client_id", "device_id", "scope" }) |field| {
        var invalid = example;
        @field(invalid, field) = " \t\r\n";
        try std.testing.expectError(error.InvalidCredentials, invalid.validate());
    }
    var credentials = example;
    for ([_][]const u8{ "openid", "chatgpt.tokens.use.direct.extra", "prefixchatgpt.tokens.use.direct" }) |scope| {
        credentials.scope = scope;
        try std.testing.expectError(error.InvalidCredentials, credentials.validate());
    }
    credentials.scope = "openid\tchatgpt.tokens.use.direct\r\nprofile";
    try credentials.validate();
}

test "private legacy JSON can be replaced but cannot be loaded" {
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
    try preflight(io, path);
    try std.testing.expectError(error.MissingField, load(a, io, path));
    const legacy = try tmp.dir.createFile(io, "codex.json", .{ .permissions = .fromMode(0o600) });
    try legacy.writeStreamingAll(io,
        \\{"access_token":"access","refresh_token":"refresh","id_token":"id","account_id":"account","expires_at":123,"obtained_at":12}
    );
    legacy.close(io);
    try preflight(io, path);
    try std.testing.expectError(error.UnknownField, load(a, io, path));
    try save(a, io, path, example);
    const parsed = try load(a, io, path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(example.client_id, parsed.value.client_id);
}
