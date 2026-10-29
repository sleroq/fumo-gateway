const std = @import("std");
const credentials = @import("codex/credentials.zig");
pub const Session = @import("codex/session.zig").Session;

/// SIWC direct-token credentials are sent only to this approved endpoint.
const siwc_responses_url = "https://api.openai.com/v1/responses";

// Match std.json.Stringify's fixed nesting capacity, including the root object.
const max_request_depth = 256;

pub const Upstream = struct {
    url: []const u8,
    models: std.json.ArrayHashMap([]const u8),
    auth: ?struct {
        provider: enum { codex },
        credentials_dir: ?[]const u8 = null,
    } = null,

    pub fn configure(self: *Upstream, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !void {
        const uri = std.Uri.parse(self.url) catch return error.InvalidUpstreamUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUpstreamUrl;
        const host = uri.host orelse return error.InvalidUpstreamUrl;
        if (host.isEmpty() or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidUpstreamUrl;
        if (uri.port == 0) return error.InvalidUpstreamUrl;
        try self.validateEndpoint();
        if (self.auth) |*options| {
            if (options.credentials_dir) |directory| {
                if (std.mem.trim(u8, directory, " \t\r\n").len == 0) return error.InvalidDirectory;
            } else {
                options.credentials_dir = try credentials.defaultDirectory(allocator, environ);
            }
        }
        if (self.models.map.count() == 0) return error.NoUpstreamModels;
        for (self.models.map.keys(), self.models.map.values()) |alias, model| {
            if (alias.len == 0) return error.EmptyModelAlias;
            if (model.len == 0) return error.EmptyUpstreamModel;
        }
    }

    fn validateEndpoint(self: Upstream) !void {
        if (self.auth != null and !std.mem.eql(u8, self.url, siwc_responses_url)) return error.InvalidCodexEndpoint;
    }

    pub fn requiredHeaders(self: Upstream) []const std.http.Header {
        return if (self.auth != null) &.{.{ .name = "user-agent", .value = "fumo-gateway" }} else &.{};
    }
};

/// Service-owned provider. Keep at a stable address once requests start, and
/// finish them before deinit; the credential session owns refresh independently.
pub const Provider = struct {
    session: ?Session = null,

    /// Expects an upstream already validated and resolved by Upstream.configure.
    /// In particular, auth.credentials_dir must be non-null when auth is enabled.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, upstream: Upstream) !Provider {
        try upstream.validateEndpoint();
        return .{
            .session = if (upstream.auth) |options| try Session.init(allocator, io, options.credentials_dir.?) else null,
        };
    }

    pub fn deinit(self: *Provider) void {
        if (self.session) |*session| session.deinit();
        self.* = undefined;
    }

    pub fn authorization(self: *Provider, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.session) |*session| return try session.authorization(allocator);
        return null;
    }
};

pub fn allowsRequestHeader(name: []const u8) bool {
    for ([_][]const u8{ "accept", "x-request-id", "openai-beta", "session_id", "conversation_id", "x-codex-turn-metadata", "x-codex-turn-state" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    }
    return false;
}

/// gpa must reclaim scratch on free; allocator owns only the returned body.
pub fn rewriteRequest(gpa: std.mem.Allocator, allocator: std.mem.Allocator, body: []const u8, models: std.json.ArrayHashMap([]const u8)) ![]u8 {
    try validateRequestDepth(gpa, body);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    var value = parsed.value;
    if (value != .object) return error.InvalidRequest;
    const model = value.object.getPtr("model") orelse return error.InvalidRequest;
    if (model.* != .string) return error.InvalidRequest;
    const mapped = models.map.get(model.string) orelse return error.UnknownModel;
    model.* = .{ .string = mapped };

    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

// Scan tokens before building the value tree so excessive nesting never reaches
// recursive serialization. The scanner handles quoted/escaped delimiters for us.
fn validateRequestDepth(allocator: std.mem.Allocator, body: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, body);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidRequest,
        };
        if (scanner.stackHeight() > max_request_depth) return error.InvalidRequest;
        if (token == .end_of_document) return;
    }
}

test "provider Responses header allowlist excludes credentials and transport-owned headers" {
    for ([_][]const u8{ "Accept", "X-Request-Id", "OpenAI-Beta", "Session_id", "Conversation_id", "X-Codex-Turn-Metadata", "X-Codex-Turn-State" }) |name| {
        try std.testing.expect(allowsRequestHeader(name));
    }
    for ([_][]const u8{ "Authorization", "Proxy-Authorization", "Cookie", "X-Api-Key", "Api-Key", "Host", "Content-Length", "Connection", "User-Agent", "X-Unrecognized" }) |name| {
        try std.testing.expect(!allowsRequestHeader(name));
    }
}

test "provider model rewrite preserves native request fields" {
    var models: std.json.ArrayHashMap([]const u8) = .{};
    defer models.deinit(std.testing.allocator);
    try models.map.put(std.testing.allocator, "demo", "upstream-model");
    const body = try rewriteRequest(std.testing.allocator, std.testing.allocator,
        \\{"model":"demo","input":[{"type":"function_call_output","call_id":"123","output":"ok"}],"stream":false,"store":true,"temperature":0.5,"max_output_tokens":99,"reasoning":{"effort":"high"},"previous_response_id":"resp_1","metadata":{"precise":18446744073709551617}}
    , models);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "18446744073709551617") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const value = parsed.value;
    try std.testing.expectEqualStrings("upstream-model", value.object.get("model").?.string);
    try std.testing.expectEqualStrings("function_call_output", value.object.get("input").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("resp_1", value.object.get("previous_response_id").?.string);
    try std.testing.expect(!value.object.get("stream").?.bool);
    try std.testing.expect(value.object.get("store").?.bool);
    try std.testing.expectEqual(@as(i64, 99), value.object.get("max_output_tokens").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), value.object.get("temperature").?.float);
    try std.testing.expectError(error.UnknownModel, rewriteRequest(std.testing.allocator, std.testing.allocator, "{\"model\":\"unknown\"}", models));
    for ([_][]const u8{ "invalid", "[]", "{}", "{\"model\":1}" }) |invalid| {
        try std.testing.expectError(error.InvalidRequest, rewriteRequest(std.testing.allocator, std.testing.allocator, invalid, models));
    }
}

test "provider request depth bounds arrays, objects, and mixed containers" {
    const a = std.testing.allocator;
    var models: std.json.ArrayHashMap([]const u8) = .{};
    defer models.deinit(a);
    try models.map.put(a, "demo", "upstream-model");
    for ([_]enum { arrays, objects, mixed }{ .arrays, .objects, .mixed }) |kind| {
        for ([_]usize{ max_request_depth, max_request_depth + 1, 301 }) |depth| {
            var input: std.Io.Writer.Allocating = .init(a);
            defer input.deinit();
            try input.writer.writeAll("{\"model\":\"demo\",\"stream\":true,\"input\":");
            for (1..depth) |level| {
                try input.writer.writeAll(if (kind == .objects or (kind == .mixed and level % 2 == 0)) "{\"nested\":" else "[");
            }
            try input.writer.writeAll("null");
            var level = depth;
            while (level > 1) {
                level -= 1;
                try input.writer.writeAll(if (kind == .objects or (kind == .mixed and level % 2 == 0)) "}" else "]");
            }
            try input.writer.writeAll("}");
            if (depth > max_request_depth) {
                try std.testing.expectError(error.InvalidRequest, rewriteRequest(a, a, input.written(), models));
            } else {
                const body = try rewriteRequest(a, a, input.written(), models);
                defer a.free(body);
                try std.testing.expect(std.mem.find(u8, body, "\"model\":\"upstream-model\"") != null);
            }
        }
    }
}

test "provider request depth ignores string delimiters and counts nesting rather than siblings" {
    const a = std.testing.allocator;
    var models: std.json.ArrayHashMap([]const u8) = .{};
    defer models.deinit(a);
    try models.map.put(a, "demo", "upstream-model");
    var input: std.Io.Writer.Allocating = .init(a);
    defer input.deinit();
    try input.writer.writeAll(
        \\{"model":"demo","input":["escaped quote: \" backslash: \\ brackets:
    );
    try input.writer.splatByteAll('[', 300);
    try input.writer.splatByteAll('}', 300);
    try input.writer.writeAll("\"");
    for (0..300) |_| try input.writer.writeAll(",[{},[]]");
    try input.writer.writeAll("]}");
    const body = try rewriteRequest(a, a, input.written(), models);
    defer a.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"upstream-model\"") != null);
}

test "provider credential initialization cannot bypass endpoint pinning" {
    try std.testing.expectError(error.InvalidCodexEndpoint, Provider.init(std.testing.allocator, std.testing.io, .{
        .url = "http://127.0.0.1/v1/responses",
        .models = .{},
        .auth = .{ .provider = .codex, .credentials_dir = "/unused" },
    }));
}
