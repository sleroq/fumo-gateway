const std = @import("std");
const storage = @import("codex/credentials.zig");
const Callback = @import("codex/callback.zig").Callback;
const Grant = @import("codex/callback.zig").Grant;

const auth_origin = "https://auth.openai.com";
const resource = "https://api.openai.com/v1";
const scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

pub fn login(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    var auth: Login = .{ .http = .{ .allocator = allocator, .io = io } };
    defer auth.http.deinit();
    try auth.run(directory);
}

pub fn refresh(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    var auth: Refresh = .{ .http = .{ .allocator = allocator, .io = io } };
    defer auth.http.deinit();
    try auth.run(directory);
}

/// SIWC registration and returning authorization.
/// Origin, port, and deadline injection are for local tests, not CLI options.
pub const Login = struct {
    http: std.http.Client,
    origin: []const u8 = auth_origin,
    callback_port: u16 = 1455,
    timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5 * 60), .clock = .awake },

    pub fn run(self: *Login, directory: []const u8) !void {
        const io = self.http.io;
        const saved = try prepareHost(self.http.allocator, io, directory);
        defer saved.deinit();

        var callback = try Callback.listen(io, self.callback_port);
        defer callback.deinit(io);

        var arena = std.heap.ArenaAllocator.init(self.http.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();
        var authorization = try Authorization.init(io, saved.value);
        const redirect_uri = try callback.redirectUri(allocator);
        const url = try authorization.url(allocator, self.origin, redirect_uri);

        try showAuthorization(io, url);
        try self.complete(allocator, directory, &callback, &authorization, redirect_uri);

        showSuccess(io, "SIWC credentials saved.\n") catch {};
    }

    fn complete(self: *Login, allocator: std.mem.Allocator, directory: []const u8, callback: *Callback, authorization: *Authorization, redirect_uri: []const u8) !void {
        const new_registration = authorization.client_id == null;
        const credentials = self.authorizeWithDeadline(allocator, callback, authorization, redirect_uri) catch |err| {
            // A validated callback can establish registration even when its
            // exchange fails. Never replace an active/returning session here.
            if (new_registration and authorization.client_id != null) {
                try storage.save(self.http.allocator, self.http.io, directory, .{
                    .device_id = authorization.device_id,
                    .client_id = authorization.client_id.?,
                });
            }
            return err;
        };
        // Persistence is the commit, outside the authorization deadline. Neither
        // timeout cancellation nor a broken confirmation pipe can undo success.
        try storage.save(self.http.allocator, self.http.io, directory, credentials);
    }

    /// allocator must be arena-backed and outlive the returned credentials.
    /// The caller reclaims all authorization state, including on error.
    fn authorizeWithDeadline(self: *Login, allocator: std.mem.Allocator, callback: *Callback, authorization: *Authorization, redirect_uri: []const u8) !storage.Credentials {
        const io = self.http.io;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, self.timeout);
        var completed: std.Io.Semaphore = .{};
        var task = try io.concurrent(authorize, .{ self, allocator, callback, authorization, redirect_uri, &completed });
        // The result borrows the caller's arena; joining must precede its deinit.
        defer {
            if (task.cancel(io)) |_| {} else |_| {}
        }
        completed.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return error.LoginTimedOut,
            else => return err,
        };
        return try task.await(io);
    }

    fn authorize(self: *Login, allocator: std.mem.Allocator, callback: *Callback, authorization: *Authorization, redirect_uri: []const u8, completed: *std.Io.Semaphore) !storage.Credentials {
        defer completed.post(self.http.io);
        const grant = try callback.wait(allocator, self.http.io, &authorization.state, authorization.client_id);
        authorization.client_id = grant.client_id;
        return self.exchange(allocator, grant, authorization, redirect_uri);
    }

    fn exchange(self: *Login, allocator: std.mem.Allocator, grant: Grant, authorization: *const Authorization, redirect_uri: []const u8) !storage.Credentials {
        const body = try encodeParameters(allocator, &.{
            .{ .name = "grant_type", .value = "authorization_code" },
            .{ .name = "client_id", .value = grant.client_id },
            .{ .name = "code", .value = grant.code },
            .{ .name = "code_verifier", .value = &authorization.verifier },
            .{ .name = "redirect_uri", .value = redirect_uri },
            .{ .name = "resource", .value = resource },
        });

        const reply = try postTokens(&self.http, self.origin, allocator, body);
        if (reply.status != .ok) {
            if (std.mem.eql(u8, tokenError(allocator, reply.body), "invalid_grant")) return error.CodeExchangeInvalidGrant;
            return error.TokenExchangeFailed;
        }

        const now: i64 = @intCast(std.Io.Clock.real.now(self.http.io).toSeconds());
        return parseCredentials(allocator, reply.body, grant.client_id, authorization.device_id, now, null);
    }
};

/// One SIWC refresh exchange, shared by the explicit command and service-owned
/// credential session. The caller owns retries, persistence, and coordination.
pub const Refresh = struct {
    http: std.http.Client,
    origin: []const u8 = auth_origin,
    timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake },

    pub fn run(self: *Refresh, directory: []const u8) !void {
        var current = try storage.load(self.http.allocator, self.http.io, directory);
        defer current.deinit();
        var arena = std.heap.ArenaAllocator.init(self.http.allocator);
        defer arena.deinit();
        const credentials = self.exchange(arena.allocator(), current.value) catch |err| {
            if (recovery(current.value, err)) |retained| try storage.save(self.http.allocator, self.http.io, directory, retained);
            return err;
        };
        // Saving is the commit, outside the network deadline, just as for login.
        try storage.save(self.http.allocator, self.http.io, directory, credentials);
        showSuccess(self.http.io, "SIWC credentials refreshed.\n") catch {};
    }

    /// A terminal renewal failure is not a transient infrastructure failure.
    /// Unusable refresh tokens end this token session, not its registration.
    /// invalid_client stops renewal but does not establish access-token revocation.
    pub fn recovery(current: storage.Credentials, err: anyerror) ?storage.Credentials {
        if (err == error.ReauthenticationRequired) return current.registration();
        if (err == error.InvalidClient) {
            var retained = current;
            retained.refresh_status = .invalid_client;
            return retained;
        }
        return null;
    }

    /// Bounded network exchange only. arena_allocator must be arena-backed.
    /// Credentials and intermediate request/response/parsing allocations share
    /// its lifetime. The caller reclaims the arena after use, including on error.
    pub fn exchange(self: *Refresh, arena_allocator: std.mem.Allocator, current: storage.Credentials) !storage.Credentials {
        if (current.refresh_status == .invalid_client) return error.InvalidClient;
        const io = self.http.io;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, self.timeout);
        var completed: std.Io.Semaphore = .{};

        var task = try io.concurrent(request, .{ self, arena_allocator, current, &completed });
        defer {
            if (task.cancel(io)) |_| {} else |_| {}
        }

        completed.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return error.RefreshTimedOut,
            else => return err,
        };
        return try task.await(io);
    }

    /// allocator is the exchange caller's arena for credentials and intermediates.
    fn request(self: *Refresh, allocator: std.mem.Allocator, current: storage.Credentials, completed: *std.Io.Semaphore) !storage.Credentials {
        defer completed.post(self.http.io);
        const body = try encodeParameters(allocator, &.{
            .{ .name = "grant_type", .value = "refresh_token" },
            .{ .name = "client_id", .value = current.client_id },
            .{ .name = "refresh_token", .value = current.refresh_token },
            .{ .name = "resource", .value = resource },
        });

        const reply = try postTokens(&self.http, self.origin, allocator, body);
        if (reply.status != .ok) {
            return refreshError(tokenError(allocator, reply.body));
        }

        const now: i64 = @intCast(std.Io.Clock.real.now(self.http.io).toSeconds());
        return parseCredentials(allocator, reply.body, current.client_id, current.device_id, now, current.id_token);
    }
};

fn tokenError(allocator: std.mem.Allocator, body: []const u8) []const u8 {
    const failure = std.json.parseFromSliceLeaky(struct { @"error": []const u8 = "" }, allocator, body, .{ .ignore_unknown_fields = true }) catch return "";
    return failure.@"error";
}

fn refreshError(code: []const u8) anyerror {
    inline for (.{ "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused" }) |terminal| {
        if (std.mem.eql(u8, code, terminal)) return error.ReauthenticationRequired;
    }
    if (std.mem.eql(u8, code, "invalid_client")) return error.InvalidClient;
    return error.TokenRefreshFailed;
}

const TokenReply = struct { status: std.http.Status, body: []u8 };

/// Login and refresh share the SIWC endpoint, limits, and redirect policy.
/// Neither request nor response bodies may appear in diagnostics.
/// arena_allocator must be arena-backed; the URL and response body are left
/// for caller-owned bulk reclamation, including on error.
fn postTokens(http: *std.http.Client, origin: []const u8, arena_allocator: std.mem.Allocator, body: []u8) !TokenReply {
    const url = try arena_allocator.print("{s}/api/accounts/oauth/token", .{origin});
    var request = try http.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .omit,
            .user_agent = .omit,
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer request.deinit();

    try request.sendBodyComplete(body);
    var response = try request.receiveHead(&.{});

    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedUpgrade;
        response = try request.receiveHead(&.{});
    }
    const status = response.head.status;

    return .{ .status = status, .body = try response.reader(&.{}).allocRemaining(arena_allocator, .limited(1024 * 1024)) };
}

fn prepareHost(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !std.json.Parsed(storage.Credentials) {
    return storage.load(allocator, io, directory) catch |err| switch (err) {
        error.FileNotFound => {
            const device_id = try deviceId(io);
            try storage.save(allocator, io, directory, .{ .device_id = &device_id });
            return storage.load(allocator, io, directory);
        },
        else => return err,
    };
}

const Authorization = struct {
    state: [43]u8,
    nonce: [43]u8,
    verifier: [43]u8,
    device_id: []const u8,
    client_id: ?[]const u8,

    fn init(io: std.Io, saved: storage.Credentials) !Authorization {
        return .{
            .state = try randomToken(io),
            .nonce = try randomToken(io),
            .verifier = try randomToken(io),
            .device_id = saved.device_id,
            .client_id = if (saved.client_id.len == 0) null else saved.client_id,
        };
    }

    fn url(self: *const Authorization, allocator: std.mem.Allocator, origin: []const u8, redirect_uri: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.verifier, &digest, .{});

        var challenge: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);

        const host_id = try allocator.print("urn:uuid:{s}", .{self.device_id});
        defer allocator.free(host_id);

        const query = try encodeParameters(allocator, &.{
            .{ .name = "client_id", .value = self.client_id orelse "dynamic_agent_client" },
            .{ .name = "ext_agent_host_id", .value = host_id },
            .{ .name = "response_type", .value = "code" },
            .{ .name = "redirect_uri", .value = redirect_uri },
            .{ .name = "resource", .value = resource },
            .{ .name = "scope", .value = scope },
            .{ .name = "state", .value = &self.state },
            .{ .name = "nonce", .value = &self.nonce },
            .{ .name = "code_challenge", .value = &challenge },
            .{ .name = "code_challenge_method", .value = "S256" },
        });
        defer allocator.free(query);

        return allocator.print("{s}/api/accounts/authorize?{s}{s}", .{ origin, query, if (self.client_id == null) "&agent_name_hint=fumo-gateway" else "" });
    }
};

const Parameter = struct { name: []const u8, value: []const u8 };

fn encodeParameters(allocator: std.mem.Allocator, parameters: []const Parameter) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (parameters, 0..) |parameter, index| {
        if (index != 0) try output.writer.writeByte('&');
        try output.writer.print("{s}=", .{parameter.name});
        try (std.Uri.Component{ .raw = parameter.value }).formatEscaped(&output.writer);
    }
    return output.toOwnedSlice();
}

fn randomToken(io: std.Io) ![43]u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    var encoded: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &bytes);
    return encoded;
}

fn deviceId(io: std.Io) ![36]u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var uuid: [36]u8 = undefined;
    _ = std.mem.print(&uuid, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..] }) catch unreachable;
    return uuid;
}

/// allocator must be arena-backed; parsed JSON and partial credentials are
/// reclaimed with the arena, not individually, including on error.
fn parseCredentials(allocator: std.mem.Allocator, body: []const u8, client_id: []const u8, device_id: []const u8, now: i64, previous_id_token: ?[]const u8) !storage.Credentials {
    // ID tokens are opaque credentials from the HTTPS token endpoint
    // not locally verified identities or gateway client keys.
    const Tokens = struct { access_token: []const u8, refresh_token: []const u8, id_token: ?[]const u8 = null, scope: []const u8, expires_in: std.json.Value };
    const tokens = try std.json.parseFromSliceLeaky(Tokens, allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    const expires_in = switch (tokens.expires_in) {
        .integer => |seconds| if (seconds > 0) seconds else return error.InvalidTokenExpiry,
        else => return error.InvalidTokenExpiry,
    };

    const received_id = tokens.id_token orelse "";
    const id_token = if (received_id.len != 0) received_id else previous_id_token orelse return error.InvalidCredentials;
    return .{
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .id_token = try allocator.dupe(u8, id_token),
        .scope = tokens.scope,
        .client_id = try allocator.dupe(u8, client_id),
        .device_id = try allocator.dupe(u8, device_id),
        .expires_at = std.math.add(i64, now, expires_in) catch return error.InvalidTokenExpiry,
        .obtained_at = now,
    };
}

fn showAuthorization(io: std.Io, url: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.print("Open this URL in your browser:\n{s}\nWaiting for the SIWC callback (up to 5 minutes)...\n", .{url});
    try output.interface.flush();
}

fn showSuccess(io: std.Io, message: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll(message);
    try output.interface.flush();
}

test "SIWC authorization has fresh proof values and binds the saved host and registration" {
    const host = try deviceId(std.testing.io);
    const authorization = try Authorization.init(std.testing.io, .{ .device_id = &host });
    try std.testing.expect(!std.mem.eql(u8, &authorization.state, &authorization.nonce));
    try std.testing.expect(!std.mem.eql(u8, &authorization.state, &authorization.verifier));
    try std.testing.expectEqual('4', authorization.device_id[14]);
    try std.testing.expect(std.mem.findScalar(u8, "89ab", authorization.device_id[19]) != null);
    const url = try authorization.url(std.testing.allocator, auth_origin, "http://127.0.0.1:1455/auth/callback");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, auth_origin ++ "/api/accounts/authorize?client_id=dynamic_agent_client&"));
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "chatgpt.tokens.use.direct") != null);
    try std.testing.expect(std.mem.find(u8, url, &authorization.verifier) == null);
    try std.testing.expect(std.mem.find(u8, url, "agent_name_hint=fumo-gateway") != null);
    const returning = try Authorization.init(std.testing.io, .{ .device_id = &host, .client_id = "issued-client" });
    const returning_url = try returning.url(std.testing.allocator, auth_origin, "http://127.0.0.1:54321/auth/callback");
    defer std.testing.allocator.free(returning_url);
    try std.testing.expect(std.mem.find(u8, returning_url, "client_id=issued-client&") != null);
    try std.testing.expect(std.mem.find(u8, returning_url, "agent_name_hint") == null);
    try std.testing.expect(std.mem.find(u8, returning_url, "id_token_hint") == null);
    try std.testing.expect(std.mem.find(u8, returning_url, &host) != null);
    try std.testing.expect(!std.mem.eql(u8, &authorization.state, &returning.state));
}

test "documented unusable refresh codes require reauthorization, not temporary retry" {
    for ([_][]const u8{ "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused" }) |code| {
        try std.testing.expectEqual(error.ReauthenticationRequired, refreshError(code));
    }
    try std.testing.expectEqual(error.InvalidClient, refreshError("invalid_client"));
    try std.testing.expectEqual(error.TokenRefreshFailed, refreshError("server_error"));
}

test "form fields are escaped without losing reserved characters" {
    const body = try encodeParameters(std.testing.allocator, &.{.{ .name = "code", .value = "a +/&=?%" }});
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("code=a%20%2B%2F%26%3D%3F%25", body);
}

test "only refresh may preserve a previous ID token and owns the preserved value" {
    const body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"scope\":\"chatgpt.tokens.use.direct\",\"expires_in\":3600}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidCredentials, parseCredentials(allocator, body, "client", "device", 100, null));
    const credentials = blk: {
        const previous_id = try std.testing.allocator.dupe(u8, "previous-id");
        defer std.testing.allocator.free(previous_id);
        break :blk try parseCredentials(allocator, body, "client", "device", 100, previous_id);
    };
    try std.testing.expectEqualStrings("previous-id", credentials.id_token);
    try std.testing.expectEqualStrings("new-refresh", credentials.refresh_token);
    try std.testing.expectEqual(3700, credentials.expires_at);
}

test "token expiry must be a positive JSON integer without timestamp overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "\"3600\"", "null", "true", "3600.5", "0", "-1", "9223372036854775807" }) |expiry| {
        const body = try allocator.print("{{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"id\",\"scope\":\"chatgpt.tokens.use.direct\",\"expires_in\":{s}}}", .{expiry});
        try std.testing.expectError(error.InvalidTokenExpiry, parseCredentials(allocator, body, "client", "device", 100, null));
    }
}

// Network contracts live here so the login test can supply the private PKCE
// state directly, without capturing process-global stdout or launching a CLI.
const AuthFixture = @import("fixture").Fixture;
const auth_test_tokens = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"id_token\":\"new-id\",\"scope\":\"chatgpt.tokens.use.direct\",\"expires_in\":1234}";
const auth_test_current: storage.Credentials = .{
    .access_token = "old-access",
    .refresh_token = "old-refresh +/&=?%",
    .id_token = "old-id",
    .client_id = "issued-client",
    .device_id = "device",
    .scope = "chatgpt.tokens.use.direct",
    .expires_at = 1700003600,
    .obtained_at = 1700000000,
};

fn authTestReply(allocator: std.mem.Allocator, status: []const u8, body: []const u8) ![]u8 {
    return allocator.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body });
}

fn authTestCallback(io: std.Io, uri: []const u8, state: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const url = try arena.allocator().print("{s}?state={s}&code=code%20%2B%2F%26%3D%3F%25&client_id=issued-client", .{ uri, state });
    var http: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer http.deinit();
    var request = try http.request(.GET, try std.Uri.parse(url), .{ .keep_alive = false });
    defer request.deinit();
    try request.sendBodiless();
    const response = try request.receiveHead(&.{});
    try std.testing.expectEqual(std.http.Status.ok, response.head.status);
}

fn authTestPrivate(dir: std.Io.Dir) !void {
    const io = std.testing.io;
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try dir.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try dir.statFile(io, "codex.json", .{})).permissions.toMode() & 0o777);
    var iterator = dir.iterate();
    const entry = (try iterator.next(io)).?;
    try std.testing.expectEqualStrings("codex.json", entry.name);
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try iterator.next(io));
}

test "login callback exchanges issued grant and commits private replacement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const reply = try authTestReply(a, "200 OK", auth_test_tokens);
    defer a.free(reply);
    var fixture = try AuthFixture.init(a, io, &.{.{ .bytes = reply }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    var login_test: Login = .{ .http = .{ .allocator = a, .io = io }, .origin = origin, .timeout = .{ .raw = .fromSeconds(2), .clock = .awake } };
    defer login_test.http.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const host = try prepareHost(a, io, path);
    defer host.deinit();
    var callback = try Callback.listen(io, 0);
    defer callback.deinit(io);
    const uri = try callback.redirectUri(a);
    defer a.free(uri);
    var authorization = try Authorization.init(io, host.value);
    var browser = try io.concurrent(authTestCallback, .{ io, uri, &authorization.state });
    defer _ = browser.cancel(io) catch {};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try login_test.complete(arena.allocator(), path, &callback, &authorization, uri);
    try browser.await(io);
    try fixture.waitRequest();
    const expected = try encodeParameters(a, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "client_id", .value = "issued-client" },
        .{ .name = "code", .value = "code +/&=?%" },
        .{ .name = "code_verifier", .value = &authorization.verifier },
        .{ .name = "redirect_uri", .value = uri },
        .{ .name = "resource", .value = resource },
    });
    defer a.free(expected);
    try authTestRequest(fixture.requests[0].?, expected);
    const saved = try prepareHost(a, io, path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("new-access", saved.value.access_token);
    try std.testing.expectEqualStrings("issued-client", saved.value.client_id);
    try std.testing.expectEqualStrings(authorization.device_id, saved.value.device_id);
    try std.testing.expectEqual(@as(i64, 1234), saved.value.expires_at - saved.value.obtained_at);
    try authTestPrivate(tmp.dir);
}

test "failed code exchange retains new registration but never replaces an active session" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Case = struct { returning: bool, transient: bool };
    for ([_]Case{
        .{ .returning = false, .transient = false },
        .{ .returning = false, .transient = true },
        .{ .returning = true, .transient = true },
    }) |case| {
        const returning = case.returning;
        const reply = try authTestReply(a, if (case.transient) "500 Internal Server Error" else "400 Bad Request", if (case.transient) "{\"error\":\"server_error\"}" else "{\"error\":\"invalid_grant\"}");
        defer a.free(reply);
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.setPermissions(io, .fromMode(0o700));
        const path = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(path);
        if (returning) try storage.save(a, io, path, auth_test_current);
        const before = try prepareHost(a, io, path);
        defer before.deinit();
        const retry = try prepareHost(a, io, path);
        defer retry.deinit();
        try std.testing.expectEqualStrings(before.value.device_id, retry.value.device_id);
        const original = try tmp.dir.readFileAlloc(io, "codex.json", a, .limited(4096));
        defer a.free(original);
        var fixture = try AuthFixture.init(a, io, &.{.{ .bytes = reply }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var auth: Login = .{ .http = .{ .allocator = a, .io = io }, .origin = origin };
        defer auth.http.deinit();
        var callback = try Callback.listen(io, 0);
        defer callback.deinit(io);
        const uri = try callback.redirectUri(a);
        defer a.free(uri);
        var pending = try Authorization.init(io, before.value);
        var browser = try io.concurrent(authTestCallback, .{ io, uri, &pending.state });
        defer _ = browser.cancel(io) catch {};
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try std.testing.expectError(if (case.transient) error.TokenExchangeFailed else error.CodeExchangeInvalidGrant, auth.complete(arena.allocator(), path, &callback, &pending, uri));
        try browser.await(io);
        const after = try prepareHost(a, io, path);
        defer after.deinit();
        try std.testing.expectEqualStrings(before.value.device_id, after.value.device_id);
        try std.testing.expectEqualStrings("issued-client", after.value.client_id);
        if (returning) {
            const unchanged = try tmp.dir.readFileAlloc(io, "codex.json", a, .limited(4096));
            defer a.free(unchanged);
            try std.testing.expectEqualStrings(original, unchanged);
        } else try std.testing.expectEqualStrings("", after.value.access_token);
    }
}

fn authTestRequest(raw: []const u8, body: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, raw, "POST /api/accounts/oauth/token HTTP/1.1\r\n"));
    try std.testing.expect(std.ascii.findIgnoreCase(raw, "content-type: application/x-www-form-urlencoded\r\n") != null);
    const start = (std.mem.find(u8, raw, "\r\n\r\n") orelse return error.TestUnexpectedResult) + 4;
    try std.testing.expectEqualStrings(body, raw[start..]);
}

test "refresh rotates credentials and preserves bytes on HTTP parse and timeout failures without retry" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Case = struct { status: []const u8 = "200 OK", body: []const u8, failure: ?anyerror = null, stall: bool = false };
    for ([_]Case{
        .{ .body = auth_test_tokens },
        .{ .body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"scope\":\"chatgpt.tokens.use.direct\",\"expires_in\":1234}" },
        .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_grant\"}", .failure = error.ReauthenticationRequired },
        .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid_client\"}", .failure = error.InvalidClient },
        .{ .status = "302 Found", .body = "", .failure = error.TokenRefreshFailed },
        .{ .body = "not json", .failure = error.SyntaxError },
        .{ .body = "", .stall = true, .failure = error.RefreshTimedOut },
    }) |case| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.setPermissions(io, .fromMode(0o700));
        const path = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(path);
        try storage.save(a, io, path, auth_test_current);
        const original = try tmp.dir.readFileAlloc(io, "codex.json", a, .limited(4096));
        defer a.free(original);
        const reply = try authTestReply(a, case.status, case.body);
        defer a.free(reply);
        var gate: std.Io.Semaphore = .{};
        var fixture = try AuthFixture.init(a, io, &.{.{ .bytes = if (case.stall) "" else reply, .gate = if (case.stall) &gate else null }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var refresh_test: Refresh = .{ .http = .{ .allocator = a, .io = io }, .origin = origin, .timeout = .{ .raw = .fromMilliseconds(250), .clock = .awake } };
        defer refresh_test.http.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        if (case.failure) |failure| {
            try std.testing.expectError(failure, refresh_test.exchange(arena.allocator(), auth_test_current));
            const after = try tmp.dir.readFileAlloc(io, "codex.json", a, .limited(4096));
            defer a.free(after);
            try std.testing.expectEqualStrings(original, after);
        } else {
            const rotated = try refresh_test.exchange(arena.allocator(), auth_test_current);
            try storage.save(a, io, path, rotated);
            const saved = try storage.load(a, io, path);
            defer saved.deinit();
            try std.testing.expectEqualStrings("new-access", saved.value.access_token);
            try std.testing.expectEqualStrings("new-refresh", saved.value.refresh_token);
            try std.testing.expectEqualStrings(if (std.mem.find(u8, case.body, "id_token") != null) "new-id" else "old-id", saved.value.id_token);
            try std.testing.expectEqualStrings(auth_test_current.client_id, saved.value.client_id);
            try std.testing.expectEqualStrings(auth_test_current.device_id, saved.value.device_id);
            try std.testing.expectEqual(@as(i64, 1234), saved.value.expires_at - saved.value.obtained_at);
        }
        try fixture.waitRequest();
        try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
        try authTestRequest(fixture.requests[0].?, "grant_type=refresh_token&client_id=issued-client&refresh_token=old-refresh%20%2B%2F%26%3D%3F%25&resource=https%3A%2F%2Fapi.openai.com%2Fv1");
        try authTestPrivate(tmp.dir);
    }
}

test "login deadline cancels idle callback partial headers and stalled exchange" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for (0..3) |phase| {
        var gate: std.Io.Semaphore = .{};
        var fixture = try AuthFixture.init(a, io, &.{.{ .bytes = "", .gate = &gate }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var auth: Login = .{ .http = .{ .allocator = a, .io = io }, .origin = origin, .timeout = .{ .raw = .fromMilliseconds(250), .clock = .awake } };
        defer auth.http.deinit();
        var callback = try Callback.listen(io, 0);
        defer callback.deinit(io);
        const uri = try callback.redirectUri(a);
        defer a.free(uri);
        var authorization = try Authorization.init(io, auth_test_current.registration());
        const partial = if (phase == 1) try callback.server.socket.address.connect(io, .{ .mode = .stream }) else null;
        defer if (partial) |stream| stream.close(io);
        if (partial) |stream| {
            var buffer: [128]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            try writer.interface.writeAll("GET /auth/callback HTTP/1.1\r\nHost: localhost\r\n");
            try writer.interface.flush();
        }
        var browser = if (phase == 2) try io.concurrent(authTestCallback, .{ io, uri, &authorization.state }) else null;
        defer {
            if (browser) |*task| {
                _ = task.cancel(io) catch {};
            }
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const before = std.Io.Clock.awake.now(io);
        try std.testing.expectError(error.LoginTimedOut, auth.authorizeWithDeadline(arena.allocator(), &callback, &authorization, uri));
        try std.testing.expect(before.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);
        // The deadline may win before the callback is accepted under load.
        // Never await a browser request after its server task was canceled.
        if (browser) |*task| _ = task.cancel(io) catch {};
        if (phase == 2) try fixture.waitRequest();
        try std.testing.expectEqual(@as(usize, if (phase == 2) 1 else 0), fixture.count.load(.acquire));
    }
}
