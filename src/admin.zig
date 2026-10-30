const std = @import("std");
const auth = @import("auth.zig");
const Config = @import("config.zig").Config;
const Registry = @import("provider.zig").Registry;
pub const Session = @import("admin/session.zig").Session;
const assets = @import("web_assets");

pub fn isLoopback(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip| ip.bytes[0] == 127,
        .ip6 => |ip| std.mem.eql(u8, &ip.bytes, &std.Io.net.Ip6Address.loopback(0).bytes),
    };
}

pub fn respond(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, content_type: []const u8) !void {
    try respondWithCache(request, status, body, content_type, &.{.{ .name = "cache-control", .value = "no-store" }});
}

fn respondWithCache(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, content_type: []const u8, comptime cache_headers: []const std.http.Header) !void {
    request.head.expect = null;
    try request.respond(body, .{ .status = status, .keep_alive = false, .transfer_encoding = if (status == .not_modified) .none else null, .extra_headers = &([_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
    } ++ cache_headers[0..cache_headers.len].* ++ [_]std.http.Header{
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
        .{ .name = "content-security-policy", .value = "default-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'" },
    }) });
}

fn asset(request: *std.http.Server.Request, comptime body: []const u8, content_type: []const u8) !void {
    // Fixed asset URLs must revalidate; hash the embedded bytes once at build time.
    const etag = comptime blk: {
        @setEvalBranchQuota(100_000_000);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        break :blk "\"" ++ std.fmt.bytesToHex(digest, .lower) ++ "\"";
    };
    var unchanged = false;
    var headers = request.iterateHeaders();
    while (headers.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, "if-none-match")) continue;
        var tags = std.mem.splitScalar(u8, item.value, ',');
        while (tags.next()) |raw| {
            const tag = std.mem.trim(u8, raw, " \t");
            const value = if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
            if (std.mem.eql(u8, value, etag) or std.mem.eql(u8, tag, "*")) unchanged = true;
        }
    }
    try respondWithCache(request, if (unchanged) .not_modified else .ok, if (unchanged) "" else body, content_type, &.{
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "etag", .value = etag },
    });
}

fn json(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try respond(request, status, body, "application/json");
}

pub const Pending = struct { request: std.http.Server.Request, path: []const u8, body: ?[]const u8 = null };

/// Runs within the server's request-reception deadline; OAuth exchange does not.
pub fn prepare(request: *std.http.Server.Request, allocator: std.mem.Allocator, config: *const Config, authorization: ?[]const u8, loopback: bool, sessions: ?*Session) !?Pending {
    if (!loopback) {
        try json(request, .forbidden, "{\"error\":\"loopback_required\"}");
        return null;
    }
    const path = request.head.target[0 .. std.mem.findScalar(u8, request.head.target, '?') orelse request.head.target.len];
    if (std.mem.startsWith(u8, path, "/admin/api/")) {
        const admin = config.admin_client orelse {
            try json(request, .service_unavailable, "{\"error\":\"admin_disabled\"}");
            return null;
        };
        const bearer = auth.authenticate(&.{admin}, authorization) != null;
        const session_route = std.mem.eql(u8, path, "/admin/api/session");
        const token = cookieToken(request) catch {
            try json(request, .unauthorized, "{\"error\":\"unauthorized\"}");
            return null;
        };
        if (session_route or (!bearer and token != null)) {
            if (!browserRequest(request)) {
                try json(request, .forbidden, "{\"error\":\"forbidden\"}");
                return null;
            }
        }
        if (session_route and request.head.method == .POST and bearer) {
            const manager = sessions orelse return error.SessionsUnavailable;
            const secure = if (header(request, "origin")) |origin| std.mem.startsWith(u8, origin, "https://") else false;
            const value = try manager.create(secure);
            try sessionResponse(request, allocator, &value, secure, false);
            return null;
        }
        if (session_route and request.head.method == .DELETE) {
            const secure = if (token) |value| if (sessions) |manager| try manager.lookup(value, true) else null else null;
            const flag = secure orelse if (header(request, "origin")) |origin| std.mem.startsWith(u8, origin, "https://") else false;
            try sessionResponse(request, allocator, "", flag, true);
            return null;
        }
        const cookie_valid = if (token) |value| if (sessions) |manager| (try manager.lookup(value, false)) != null else false else false;
        if (!bearer and !cookie_valid) {
            try json(request, .unauthorized, "{\"error\":\"unauthorized\"}");
            return null;
        }
        if (request.head.method == .POST and std.mem.endsWith(u8, path, "/auth/complete")) {
            const owned_path = try allocator.dupe(u8, path);
            const reader = request.readerExpectContinue(&.{}) catch {
                try json(request, .bad_request, "{\"error\":\"invalid_request\"}");
                return null;
            };
            const body = reader.allocRemaining(allocator, .limited(16384)) catch {
                try json(request, .bad_request, "{\"error\":\"invalid_request\"}");
                return null;
            };
            return .{ .request = request.*, .path = owned_path, .body = body };
        }
    }
    return .{ .request = request.*, .path = path };
}

pub fn handle(pending: *Pending, allocator: std.mem.Allocator, registry: *Registry) !void {
    const request = &pending.request;
    const path = pending.path;
    if (!std.mem.startsWith(u8, path, "/admin/api/")) {
        if (request.head.method == .GET) {
            if (std.mem.eql(u8, path, "/admin/") or std.mem.eql(u8, path, "/admin")) return asset(request, assets.index_html, "text/html; charset=utf-8");
            if (std.mem.eql(u8, path, "/admin/logo.svg")) return asset(request, assets.logo_svg, "image/svg+xml");
            if (std.mem.eql(u8, path, "/admin/assets/admin.js")) return asset(request, assets.admin_js, "text/javascript; charset=utf-8");
            if (std.mem.eql(u8, path, "/admin/assets/admin.css")) return asset(request, assets.admin_css, "text/css; charset=utf-8");
        }
        return json(request, .not_found, "{\"error\":\"not_found\"}");
    }
    if (std.mem.eql(u8, path, "/admin/api/accounts") and request.head.method == .GET) {
        const Account = struct { id: []const u8, provider: []const u8 = "codex", status: []const u8, configured: bool, pending: bool };
        const accounts = try allocator.alloc(Account, registry.accounts.len);
        for (accounts, registry.accounts) |*output, *account| {
            const state = try account.session.status();
            output.* = .{ .id = account.id, .status = @tagName(state.status), .configured = account.configured, .pending = state.pending };
        }
        return json(request, .ok, try std.json.Stringify.valueAlloc(allocator, .{ .accounts = accounts }, .{}));
    }
    const prefix = "/admin/api/accounts/";
    if (std.mem.startsWith(u8, path, prefix) and request.head.method == .POST) {
        const tail = path[prefix.len..];
        const slash = std.mem.findScalar(u8, tail, '/') orelse return json(request, .not_found, "{\"error\":\"not_found\"}");
        for (registry.accounts) |*account| {
            if (!std.mem.eql(u8, account.id, tail[0..slash])) continue;
            const action = tail[slash..];
            if (std.mem.eql(u8, action, "/auth/disconnect")) {
                account.session.disconnect() catch |err| {
                    if (err == error.Canceled) return err;
                    return json(request, .internal_server_error, "{\"error\":\"credential_save_failed\"}");
                };
                return json(request, .ok, "{\"status\":\"login_required\"}");
            }
            if (std.mem.eql(u8, action, "/auth/start")) {
                const result = account.session.startAuth(allocator) catch |err| {
                    if (err == error.Canceled) return err;
                    return json(request, .internal_server_error, "{\"error\":\"authentication_start_failed\"}");
                };
                return json(request, .ok, try std.json.Stringify.valueAlloc(allocator, result, .{}));
            }
            if (std.mem.eql(u8, action, "/auth/complete")) {
                const body = pending.body.?;
                const input = std.json.parseFromSliceLeaky(struct { callback_url: []const u8 }, allocator, body, .{}) catch return json(request, .bad_request, "{\"error\":\"invalid_request\"}");
                account.session.completeAuth(input.callback_url) catch |err| {
                    if (err == error.Canceled) return err;
                    const status: std.http.Status, const message: []const u8 = switch (err) {
                        error.NoPendingLogin => .{ .conflict, "{\"error\":\"no_pending_login\"}" },
                        error.LoginExpired => .{ .gone, "{\"error\":\"login_expired\"}" },
                        error.InvalidCallback, error.InvalidQuery, error.InvalidState, error.ClientMismatch, error.NotFound, error.AuthorizationDenied => .{ .bad_request, "{\"error\":\"invalid_callback\"}" },
                        error.CredentialSaveFailed => .{ .internal_server_error, "{\"error\":\"credential_save_failed\"}" },
                        else => .{ .bad_gateway, "{\"error\":\"authentication_exchange_failed\"}" },
                    };
                    return json(request, status, message);
                };
                return json(request, .ok, "{\"status\":\"connected\"}");
            }
        }
    }
    return json(request, .not_found, "{\"error\":\"not_found\"}");
}

fn header(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    var result: ?[]const u8 = null;
    while (it.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
        if (result != null) return null;
        result = item.value;
    }
    return result;
}

fn browserRequest(request: *std.http.Server.Request) bool {
    inline for (.{ "origin", "host", "sec-fetch-site", "x-requested-with" }) |name| {
        var it = request.iterateHeaders();
        var seen = false;
        while (it.next()) |item| {
            if (!std.ascii.eqlIgnoreCase(item.name, name)) continue;
            if (seen) return false;
            seen = true;
        }
    }
    const requested = header(request, "x-requested-with") orelse return false;
    if (!std.mem.eql(u8, requested, "fumo-admin")) return false;
    if (header(request, "sec-fetch-site")) |site| {
        if (std.mem.eql(u8, site, "cross-site")) return false;
    }
    if (header(request, "origin")) |origin| {
        const prefix: usize = if (std.mem.startsWith(u8, origin, "https://")) 8 else if (std.mem.startsWith(u8, origin, "http://")) 7 else return false;
        const host = header(request, "host") orelse return false;
        if (!std.ascii.eqlIgnoreCase(origin[prefix..], host)) return false;
    }
    return true;
}

fn cookieToken(request: *std.http.Server.Request) !?[]const u8 {
    var result: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |item| {
        if (!std.ascii.eqlIgnoreCase(item.name, "cookie")) continue;
        var cookies = std.mem.splitScalar(u8, item.value, ';');
        while (cookies.next()) |raw| {
            const cookie = std.mem.trim(u8, raw, " \t");
            const eq = std.mem.findScalar(u8, cookie, '=') orelse continue;
            if (!std.mem.eql(u8, cookie[0..eq], "fumo_admin_session")) continue;
            if (result != null) return error.DuplicateCookie;
            result = cookie[eq + 1 ..];
        }
    }
    return result;
}

fn sessionResponse(request: *std.http.Server.Request, allocator: std.mem.Allocator, token: []const u8, secure: bool, clear: bool) !void {
    const cookie = try std.fmt.allocPrint(allocator, "fumo_admin_session={s}; HttpOnly; SameSite=Strict; Path=/admin/{s}{s}", .{ token, if (secure) "; Secure" else "", if (clear) "; Max-Age=0" else "" });
    request.head.expect = null;
    try request.respond("{}", .{ .keep_alive = false, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = cookie },
    } });
}

test "browser sessions login reload logout and request boundaries" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sessions: Session = .{ .allocator = a, .io = std.testing.io };
    defer sessions.deinit();
    const config: Config = .{ .arena = undefined, .address = undefined, .clients = &.{}, .upstreams = &.{}, .admin_client = auth.Client.init("admin", "admin-secret") };
    const Harness = struct {
        fn run(alloc: std.mem.Allocator, manager: *Session, cfg: *const Config, method: []const u8, path: []const u8, headers: []const u8, bearer: ?[]const u8) !struct { accepted: bool, response: []const u8 } {
            const raw = try std.fmt.allocPrint(alloc, "{s} {s} HTTP/1.1\r\nHost: localhost\r\n{s}\r\n", .{ method, path, headers });
            var reader = std.Io.Reader.fixed(raw);
            var writer = std.Io.Writer.Allocating.init(alloc);
            var http = std.http.Server.init(&reader, &writer.writer);
            var request = try http.receiveHead();
            const pending = try prepare(&request, alloc, cfg, bearer, true, manager);
            return .{ .accepted = pending != null, .response = writer.written() };
        }
    };
    const login = try Harness.run(allocator, &sessions, &config, "POST", "/admin/api/session", "X-Requested-With: fumo-admin\r\nOrigin: https://localhost\r\n", "Bearer admin-secret");
    try std.testing.expect(std.mem.startsWith(u8, login.response, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.find(u8, login.response, "HttpOnly; SameSite=Strict; Path=/admin/; Secure") != null);
    try std.testing.expect(std.mem.find(u8, login.response, "no-store") != null);
    try std.testing.expect(std.mem.find(u8, login.response, "Max-Age") == null);
    try std.testing.expect(std.mem.find(u8, login.response, "Domain=") == null);
    const start = (std.mem.find(u8, login.response, "fumo_admin_session=") orelse return error.TestUnexpectedResult) + "fumo_admin_session=".len;
    const token = login.response[start .. start + 64];
    const cookie = try std.fmt.allocPrint(allocator, "Cookie: fumo_admin_session={s}\r\n", .{token});
    const headers = try std.fmt.allocPrint(allocator, "{s}X-Requested-With: fumo-admin\r\n", .{cookie});
    try std.testing.expect((try Harness.run(allocator, &sessions, &config, "GET", "/admin/api/accounts", headers, null)).accepted);
    const missing = try Harness.run(allocator, &sessions, &config, "GET", "/admin/api/accounts", cookie, null);
    try std.testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 403"));
    const duplicate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ headers, cookie });
    try std.testing.expect(!(try Harness.run(allocator, &sessions, &config, "GET", "/admin/api/accounts", duplicate, null)).accepted);
    const cross = try std.fmt.allocPrint(allocator, "{s}Origin: https://evil.example\r\n", .{headers});
    try std.testing.expect(!(try Harness.run(allocator, &sessions, &config, "GET", "/admin/api/accounts", cross, null)).accepted);
    const logout = try Harness.run(allocator, &sessions, &config, "DELETE", "/admin/api/session", headers, null);
    try std.testing.expect(std.mem.find(u8, logout.response, "; Secure; Max-Age=0") != null);
    try std.testing.expect(!(try Harness.run(allocator, &sessions, &config, "GET", "/admin/api/accounts", headers, null)).accepted);
    const forged = "X-Requested-With: fumo-admin\r\nCookie: fumo_admin_session=forged\r\n";
    try std.testing.expect(!(try Harness.run(allocator, &sessions, &config, "GET", "/admin/api/accounts", forged, null)).accepted);
    const rejected = try Harness.run(allocator, &sessions, &config, "POST", "/admin/api/session", "X-Requested-With: fumo-admin\r\n", "Bearer inference-secret");
    try std.testing.expect(std.mem.startsWith(u8, rejected.response, "HTTP/1.1 401"));
    const http_login = try Harness.run(allocator, &sessions, &config, "POST", "/admin/api/session", "X-Requested-With: fumo-admin\r\nOrigin: http://localhost\r\n", "Bearer admin-secret");
    try std.testing.expect(std.mem.find(u8, http_login.response, "; Secure") == null);
    const repeated = try Harness.run(allocator, &sessions, &config, "DELETE", "/admin/api/session", "X-Requested-With: fumo-admin\r\n", null);
    try std.testing.expect(std.mem.startsWith(u8, repeated.response, "HTTP/1.1 200"));
}
