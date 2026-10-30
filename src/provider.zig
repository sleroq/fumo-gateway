const std = @import("std");
const credentials = @import("codex/credentials.zig");
pub const Session = @import("codex/session.zig").Session;

const models = @import("models.zig");

// Match std.json.Stringify's fixed nesting capacity, including the root object.
const max_request_depth = 256;

pub const Protocol = enum {
    responses,
    chat_completions,

    pub fn path(self: Protocol) []const u8 {
        return switch (self) {
            .responses => "/responses",
            .chat_completions => "/chat/completions",
        };
    }
};

/// Immutable, config-arena-owned definition. Runtime state lives in Provider.
pub const Upstream = struct {
    name: []const u8,
    base_url: []const u8,
    aliases: std.json.ArrayHashMap([]const u8) = .{},
    auth: union(enum) { none, codex: []const u8, api_key: []const u8 } = .none,

    pub const Options = struct {
        base_url: []const u8,
        aliases: std.json.ArrayHashMap([]const u8) = .{},
        auth: ?struct {
            provider: enum { codex, api_key },
            credentials_dir: ?[]const u8 = null,
            key_env: ?[]const u8 = null,
        } = null,
    };

    pub fn configure(name: []const u8, options: Options, allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !Upstream {
        if (name.len == 0) return error.InvalidUpstreamName;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidUpstreamName;
        }

        const base_url = std.mem.trimEnd(u8, options.base_url, "/");
        const uri = std.Uri.parse(base_url) catch return error.InvalidUpstreamUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUpstreamUrl;
        if (uri.host == null or uri.user != null or uri.query != null or uri.fragment != null or uri.port == 0) return error.InvalidUpstreamUrl;
        var result: Upstream = .{ .name = name, .base_url = base_url, .aliases = options.aliases };

        if (options.auth) |auth| switch (auth.provider) {
            .codex => {
                if (auth.key_env != null) return error.InvalidUpstreamAuth;
                const directory = auth.credentials_dir orelse try credentials.defaultDirectory(allocator, environ);
                if (std.mem.trim(u8, directory, " \t\r\n").len == 0) return error.InvalidDirectory;
                result.auth = .{ .codex = directory };
            },
            .api_key => {
                if (auth.credentials_dir != null) return error.InvalidUpstreamAuth;
                const key_env = auth.key_env orelse return error.InvalidUpstreamAuth;
                if (!std.process.Environ.Map.validateKeyForPut(key_env)) return error.InvalidKeyEnv;
                const key = environ.get(key_env) orelse return error.MissingUpstreamKey;
                if (key.len == 0) return error.EmptyUpstreamKey;
                for (key) |byte| {
                    if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return error.InvalidUpstreamKey;
                }
                result.auth = .{ .api_key = try allocator.dupe(u8, key) };
            },
        };

        try result.validateEndpoint();
        for (result.aliases.map.keys(), result.aliases.map.values()) |alias, model| {
            if (alias.len == 0) return error.EmptyModelAlias;
            if (model.len == 0) return error.EmptyUpstreamModel;
        }

        return result;
    }

    fn validateEndpoint(self: Upstream) !void {
        // SIWC direct-token credentials must never reach a configurable host.
        if (self.auth == .codex and !std.mem.eql(u8, self.base_url, "https://api.openai.com/v1")) return error.InvalidCodexEndpoint;
    }

    pub fn requiredHeaders(self: Upstream) []const std.http.Header {
        return if (self.auth == .codex) &.{.{ .name = "user-agent", .value = "fumo-gateway" }} else &.{};
    }
};

/// Stable-address service state. Definitions borrow Config; requests and cache
/// refreshes must finish before deinit, which joins the credential worker.
pub const Provider = struct {
    upstream: Upstream,
    session: ?Session = null,
    catalog: models.Cache,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, upstream: Upstream) !Provider {
        try upstream.validateEndpoint();
        return .{
            .upstream = upstream,
            .session = if (upstream.auth == .codex) try Session.init(allocator, io, upstream.auth.codex) else null,
            .catalog = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Provider) void {
        if (self.session) |*session| session.deinit();
        self.catalog.deinit();
        self.* = undefined;
    }

    pub fn authorization(self: *Provider, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.session) |*session| return try session.authorization(allocator);

        return switch (self.upstream.auth) {
            .api_key => |key| try allocator.print("Bearer {s}", .{key}),
            else => null,
        };
    }

    fn appendModels(self: *Provider, client: *std.http.Client, arena_allocator: std.mem.Allocator, list: *std.ArrayList(models.Model)) !bool {
        const upstream = self.upstream;
        // Aliases remain usable even if a provider has no discovery endpoint.
        for (upstream.aliases.map.keys()) |alias| {
            try list.append(arena_allocator, .{
                .id = try arena_allocator.print("{s}/{s}", .{ upstream.name, alias }),
                .owned_by = upstream.name,
            });
        }

        const discovered = try self.catalog.append(client, arena_allocator, .{
            .url = try arena_allocator.print("{s}/models", .{upstream.base_url}),
            .authorization = self.authorization(arena_allocator),
            .headers = upstream.requiredHeaders(),
            .namespace = upstream.name,
            .format = if (upstream.auth == .codex) .siwc else .openai,
        }, list);

        return discovered or upstream.aliases.map.count() != 0;
    }
};

/// Fixed provider storage: sessions cannot move after their workers start.
/// The caller joins all requests before deinit and keeps Config alive until after it.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: []Provider,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, upstreams: []const Upstream) !Registry {
        const entries = try allocator.alloc(Provider, upstreams.len);
        errdefer allocator.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |*entry| entry.deinit();

        for (entries, upstreams) |*entry, upstream| {
            entry.* = try Provider.init(allocator, io, upstream);
            initialized += 1;
        }

        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries) |*entry| entry.deinit();
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    /// arena_allocator must be arena-backed: lists, deduplication scratch, and
    /// JSON share the request lifetime. No cache/session pointers escape.
    pub fn modelList(self: *Registry, client: *std.http.Client, arena_allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(models.Model) = .empty;
        var available = self.entries.len == 0;
        for (self.entries) |*entry| available = try entry.appendModels(client, arena_allocator, &list) or available;
        if (!available) return error.ModelDiscoveryUnavailable;

        // An alias may shadow a discovered name. Advertise it only once.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var unique: std.ArrayList(models.Model) = .empty;
        for (list.items) |model| {
            const slot = try seen.getOrPut(arena_allocator, model.id);
            if (!slot.found_existing) try unique.append(arena_allocator, model);
        }

        return std.json.Stringify.valueAlloc(arena_allocator, .{ .object = "list", .data = unique.items }, .{ .emit_null_optional_fields = false });
    }
};

pub fn allowsRequestHeader(name: []const u8) bool {
    for ([_][]const u8{ "accept", "x-request-id", "openai-beta", "session_id", "conversation_id", "x-codex-turn-metadata", "x-codex-turn-state" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    }
    return false;
}

pub const Routed = struct { upstream: usize, body: []u8 };

/// Discovery is not an allowlist. Resolve the namespace and optional alias;
/// the incoming endpoint selects the protocol. Scratch is freed before relay.
pub fn rewriteRequest(gpa: std.mem.Allocator, allocator: std.mem.Allocator, body: []const u8, upstreams: []const Upstream) !Routed {
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

    const separator = std.mem.findScalar(u8, model.string, '/') orelse return error.UnknownUpstream;
    const name = model.string[0..separator];
    const native = model.string[separator + 1 ..];
    if (native.len == 0) return error.InvalidRequest;

    for (upstreams, 0..) |upstream, index| {
        if (!std.mem.eql(u8, upstream.name, name)) continue;
        model.* = .{ .string = upstream.aliases.map.get(native) orelse native };
        return .{ .upstream = index, .body = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
    }

    return error.UnknownUpstream;
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

test "provider routing preserves native fields and resolves only the namespace and alias" {
    const a = std.testing.allocator;
    var upstreams = [_]Upstream{
        .{ .name = "codex", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/unused" } },
        .{ .name = "zen", .base_url = "https://example.com/v1", .auth = .{ .api_key = "zen-secret" } },
    };
    defer upstreams[0].aliases.deinit(a);
    try upstreams[0].aliases.map.put(a, "fast", "upstream-model");
    const routed = try rewriteRequest(a, a,
        \\{"model":"codex/fast","input":[{"type":"function_call_output","call_id":"123","output":"ok"}],"stream":false,"store":true,"temperature":0.5,"max_output_tokens":99,"reasoning":{"effort":"high"},"previous_response_id":"resp_1","metadata":{"precise":18446744073709551617}}
    , &upstreams);
    defer a.free(routed.body);
    try std.testing.expectEqual(0, routed.upstream);
    try std.testing.expect(std.mem.find(u8, routed.body, "18446744073709551617") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, routed.body, .{});
    defer parsed.deinit();
    const value = parsed.value;
    try std.testing.expectEqualStrings("upstream-model", value.object.get("model").?.string);
    try std.testing.expectEqualStrings("function_call_output", value.object.get("input").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("resp_1", value.object.get("previous_response_id").?.string);
    try std.testing.expect(!value.object.get("stream").?.bool);
    try std.testing.expect(value.object.get("store").?.bool);
    try std.testing.expectEqual(@as(i64, 99), value.object.get("max_output_tokens").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), value.object.get("temperature").?.float);

    // New and nested model IDs work without ever querying discovery.
    const direct = try rewriteRequest(a, a, "{\"model\":\"zen/vendor/new-model\",\"messages\":[]}", &upstreams);
    defer a.free(direct.body);
    try std.testing.expectEqual(1, direct.upstream);
    try std.testing.expectEqualStrings("{\"model\":\"vendor/new-model\",\"messages\":[]}", direct.body);
    try std.testing.expectError(error.UnknownUpstream, rewriteRequest(a, a, "{\"model\":\"missing/model\"}", &upstreams));
    try std.testing.expectError(error.UnknownUpstream, rewriteRequest(a, a, "{\"model\":\"unqualified\"}", &upstreams));
    const responses = try rewriteRequest(a, a, "{\"model\":\"zen/vendor/another-model\",\"input\":[]}", &upstreams);
    defer a.free(responses.body);
    try std.testing.expectEqual(1, responses.upstream);
    try std.testing.expectEqualStrings("{\"model\":\"vendor/another-model\",\"input\":[]}", responses.body);
    for ([_][]const u8{ "invalid", "[]", "{}", "{\"model\":1}", "{\"model\":\"codex/\"}" }) |invalid| {
        try std.testing.expectError(error.InvalidRequest, rewriteRequest(a, a, invalid, &upstreams));
    }
}

test "provider request depth bounds arrays, objects, and mixed containers" {
    const a = std.testing.allocator;
    const upstreams = [_]Upstream{.{ .name = "test", .base_url = "http://localhost/v1" }};
    for ([_]enum { arrays, objects, mixed }{ .arrays, .objects, .mixed }) |kind| {
        for ([_]usize{ max_request_depth, max_request_depth + 1, 301 }) |depth| {
            var input: std.Io.Writer.Allocating = .init(a);
            defer input.deinit();
            try input.writer.writeAll("{\"model\":\"test/model\",\"input\":");
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
                try std.testing.expectError(error.InvalidRequest, rewriteRequest(a, a, input.written(), &upstreams));
            } else {
                const routed = try rewriteRequest(a, a, input.written(), &upstreams);
                defer a.free(routed.body);
                try std.testing.expect(std.mem.find(u8, routed.body, "\"model\":\"model\"") != null);
            }
        }
    }
}

test "provider request depth ignores string delimiters and counts nesting rather than siblings" {
    const a = std.testing.allocator;
    const upstreams = [_]Upstream{.{ .name = "test", .base_url = "http://localhost/v1" }};
    var input: std.Io.Writer.Allocating = .init(a);
    defer input.deinit();
    try input.writer.writeAll(
        \\{"model":"test/model","input":["escaped quote: \" backslash: \\ brackets:
    );
    try input.writer.splatByteAll('[', 300);
    try input.writer.splatByteAll('}', 300);
    try input.writer.writeAll("\"");
    for (0..300) |_| try input.writer.writeAll(",[{},[]]");
    try input.writer.writeAll("]}");
    const routed = try rewriteRequest(a, a, input.written(), &upstreams);
    defer a.free(routed.body);
    try std.testing.expect(std.mem.find(u8, routed.body, "\"model\":\"model\"") != null);
}

test "provider credential initialization cannot bypass endpoint pinning" {
    try std.testing.expectError(error.InvalidCodexEndpoint, Provider.init(std.testing.allocator, std.testing.io, .{
        .name = "codex",
        .base_url = "http://127.0.0.1/v1",
        .auth = .{ .codex = "/unused" },
    }));
}

test "provider registry frees already initialized providers on credential load failure" {
    const a = std.testing.allocator;
    const upstreams = [_]Upstream{
        .{ .name = "public", .base_url = "http://localhost/v1" },
        .{ .name = "codex", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/fumo-gateway-credentials" } },
    };
    try std.testing.expectError(error.FileNotFound, Registry.init(a, std.testing.io, &upstreams));
}
