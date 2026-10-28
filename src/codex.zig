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

/// SIWC only, following CLIProxyAPI's siwc_auth.go and siwc_bind.go.
/// Origin, port, and deadline injection are for local tests, not CLI options.
pub const Login = struct {
    http: std.http.Client,
    origin: []const u8 = auth_origin,
    callback_port: u16 = 1455,
    timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(5 * 60), .clock = .awake },

    pub fn run(self: *Login, directory: []const u8) !void {
        const io = self.http.io;
        try storage.preflight(io, directory);
        var callback = try Callback.listen(io, self.callback_port);
        defer callback.deinit(io);
        var arena = std.heap.ArenaAllocator.init(self.http.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const authorization = try Authorization.init(io);
        const redirect_uri = try callback.redirectUri(allocator);
        const url = try authorization.url(allocator, self.origin, redirect_uri);
        try showAuthorization(io, url);
        const credentials = try self.authorizeWithDeadline(allocator, &callback, authorization, redirect_uri);
        // Persistence is the commit, outside the authorization deadline. Neither
        // timeout cancellation nor a broken confirmation pipe can undo success.
        try storage.save(self.http.allocator, io, directory, credentials);
        showSuccess(io, "SIWC credentials saved.\n") catch {};
    }

    fn authorizeWithDeadline(self: *Login, allocator: std.mem.Allocator, callback: *Callback, authorization: Authorization, redirect_uri: []const u8) !storage.Credentials {
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

    fn authorize(self: *Login, allocator: std.mem.Allocator, callback: *Callback, authorization: Authorization, redirect_uri: []const u8, completed: *std.Io.Semaphore) !storage.Credentials {
        defer completed.post(self.http.io);
        const grant = try callback.wait(allocator, self.http.io, &authorization.state);
        return self.exchange(allocator, grant, authorization, redirect_uri);
    }

    fn exchange(self: *Login, allocator: std.mem.Allocator, grant: Grant, authorization: Authorization, redirect_uri: []const u8) !storage.Credentials {
        const body = try encodeParameters(allocator, &.{
            .{ .name = "grant_type", .value = "authorization_code" },
            .{ .name = "client_id", .value = grant.client_id },
            .{ .name = "code", .value = grant.code },
            .{ .name = "code_verifier", .value = &authorization.verifier },
            .{ .name = "redirect_uri", .value = redirect_uri },
            .{ .name = "resource", .value = resource },
        });
        const reply = try postTokens(&self.http, self.origin, allocator, body);
        if (reply.status != .ok) return error.TokenExchangeFailed;
        const now: i64 = @intCast(std.Io.Clock.real.now(self.http.io).toSeconds());
        return parseCredentials(allocator, reply.body, grant.client_id, &authorization.device_id, now, null);
    }
};

/// One explicit refresh, without retries. Automatic inference-time refresh and
/// coordination belong to the future running credential owner, not this command.
pub const Refresh = struct {
    http: std.http.Client,
    origin: []const u8 = auth_origin,
    timeout: std.Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake },

    pub fn run(self: *Refresh, directory: []const u8) !void {
        var current = try storage.load(self.http.allocator, self.http.io, directory);
        defer current.deinit();
        var arena = std.heap.ArenaAllocator.init(self.http.allocator);
        defer arena.deinit();
        const credentials = try self.refreshWithDeadline(arena.allocator(), current.value);
        // Saving is the commit, outside the network deadline, just as for login.
        try storage.save(self.http.allocator, self.http.io, directory, credentials);
        showSuccess(self.http.io, "SIWC credentials refreshed.\n") catch {};
    }

    fn refreshWithDeadline(self: *Refresh, allocator: std.mem.Allocator, current: storage.Credentials) !storage.Credentials {
        const io = self.http.io;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, self.timeout);
        var completed: std.Io.Semaphore = .{};
        var task = try io.concurrent(request, .{ self, allocator, current, &completed });
        defer {
            if (task.cancel(io)) |_| {} else |_| {}
        }
        completed.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return error.RefreshTimedOut,
            else => return err,
        };
        return try task.await(io);
    }

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
            const failure = std.json.parseFromSliceLeaky(struct { @"error": []const u8 = "" }, allocator, reply.body, .{ .ignore_unknown_fields = true }) catch return error.TokenRefreshFailed;
            if (std.mem.eql(u8, failure.@"error", "invalid_grant")) return error.ReauthenticationRequired;
            return error.TokenRefreshFailed;
        }
        const now: i64 = @intCast(std.Io.Clock.real.now(self.http.io).toSeconds());
        return parseCredentials(allocator, reply.body, current.client_id, current.device_id, now, current.id_token);
    }
};

const TokenReply = struct { status: std.http.Status, body: []u8 };

/// Login and refresh share the SIWC endpoint, limits, and redirect policy.
/// Neither request nor response bodies may appear in diagnostics.
fn postTokens(http: *std.http.Client, origin: []const u8, allocator: std.mem.Allocator, body: []u8) !TokenReply {
    const url = try std.fmt.allocPrint(allocator, "{s}/api/accounts/oauth/token", .{origin});
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
    return .{ .status = status, .body = try response.reader(&.{}).allocRemaining(allocator, .limited(1024 * 1024)) };
}

const Authorization = struct {
    state: [43]u8,
    nonce: [43]u8,
    verifier: [43]u8,
    device_id: [36]u8,

    fn init(io: std.Io) !Authorization {
        return .{ .state = try randomToken(io), .nonce = try randomToken(io), .verifier = try randomToken(io), .device_id = try deviceId(io) };
    }

    fn url(self: *const Authorization, allocator: std.mem.Allocator, origin: []const u8, redirect_uri: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.verifier, &digest, .{});
        var challenge: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge, &digest);
        const host_id = try std.fmt.allocPrint(allocator, "urn:uuid:{s}", .{self.device_id});
        defer allocator.free(host_id);
        const query = try encodeParameters(allocator, &.{
            .{ .name = "client_id", .value = "dynamic_agent_client" },
            .{ .name = "agent_name_hint", .value = "fumo-gateway" },
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
        return std.fmt.allocPrint(allocator, "{s}/api/accounts/authorize?{s}", .{ origin, query });
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
    _ = std.fmt.bufPrint(&uuid, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..] }) catch unreachable;
    return uuid;
}

fn parseCredentials(allocator: std.mem.Allocator, body: []const u8, client_id: []const u8, device_id: []const u8, now: i64, previous_id_token: ?[]const u8) !storage.Credentials {
    // Match CLIProxyAPI's SIWC contract: ID tokens are opaque credentials from the
    // HTTPS token endpoint, not locally verified identities or gateway client keys.
    const Tokens = struct { access_token: []const u8, refresh_token: []const u8, id_token: ?[]const u8 = null, scope: []const u8, expires_in: std.json.Value };
    const tokens = try std.json.parseFromSliceLeaky(Tokens, allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    const expires_in = switch (tokens.expires_in) {
        .integer => |seconds| if (seconds > 0) seconds else return error.InvalidTokenExpiry,
        else => return error.InvalidTokenExpiry,
    };
    const received_id = tokens.id_token orelse "";
    const id_token = if (std.mem.trim(u8, received_id, " \t\r\n\x0b\x0c").len != 0) received_id else previous_id_token orelse return error.InvalidCredentials;
    const credentials: storage.Credentials = .{
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .id_token = try allocator.dupe(u8, id_token),
        .scope = tokens.scope,
        .client_id = try allocator.dupe(u8, client_id),
        .device_id = try allocator.dupe(u8, device_id),
        .expires_at = std.math.add(i64, now, expires_in) catch return error.InvalidTokenExpiry,
        .obtained_at = now,
    };
    try credentials.validate();
    return credentials;
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

test "SIWC authorization has independent random state, nonce, verifier, and UUID" {
    const authorization = try Authorization.init(std.testing.io);
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
        const body = try std.fmt.allocPrint(allocator, "{{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"id\",\"scope\":\"chatgpt.tokens.use.direct\",\"expires_in\":{s}}}", .{expiry});
        try std.testing.expectError(error.InvalidTokenExpiry, parseCredentials(allocator, body, "client", "device", 100, null));
    }
}
