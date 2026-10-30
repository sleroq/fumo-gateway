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

/// Provider state borrows Config and Account; owns only the model catalog.
pub const Provider = struct {
    upstream: Upstream,
    catalog: models.Cache,
    account: ?*Account = null,

    pub fn deinit(self: *Provider) void {
        self.catalog.deinit();
        self.* = undefined;
    }

    pub fn authorization(self: *Provider, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.account) |account| return try account.session.authorization(allocator);

        return switch (self.upstream.auth) {
            .api_key => |key| try allocator.print("Bearer {s}", .{key}),
            else => null,
        };
    }

    fn appendModels(self: *Provider, client: *std.http.Client, arena_allocator: std.mem.Allocator, list: *std.ArrayList(models.Model)) !bool {
        const upstream = self.upstream;
        var discovered_models: std.ArrayList(models.Model) = .empty;
        const discovered = try self.catalog.append(client, arena_allocator, .{
            .url = try arena_allocator.print("{s}/models", .{upstream.base_url}),
            .authorization = self.authorization(arena_allocator),
            .headers = upstream.requiredHeaders(),
            .namespace = upstream.name,
            .format = if (upstream.auth == .codex) .siwc else .openai,
        }, &discovered_models);

        // Aliases inherit only their native target's metadata, never a shadowed
        // model's. They remain usable even without a discovery endpoint.
        for (upstream.aliases.map.keys(), upstream.aliases.map.values()) |alias, target| {
            var model: models.Model = .{ .id = undefined, .owned_by = upstream.name };
            for (discovered_models.items) |native| {
                if (std.mem.eql(u8, native.id[upstream.name.len + 1 ..], target)) {
                    model = native;
                    break;
                }
            }
            model.id = try arena_allocator.print("{s}/{s}", .{ upstream.name, alias });
            try list.append(arena_allocator, model);
        }
        try list.appendSlice(arena_allocator, discovered_models.items);

        return discovered or upstream.aliases.map.count() != 0;
    }
};

/// Owns the credential session shared by providers using the same directory.
pub const Account = struct {
    id: []const u8,
    directory: []u8,
    configured: bool,
    session: Session,
};

/// Fixed account storage: sessions cannot move after their workers start.
/// The caller joins all requests before deinit and keeps Config alive until after it.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: []Provider,
    accounts: []Account,
    account_storage: []Account,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, upstreams: []const Upstream) !Registry {
        return initAccounts(allocator, io, upstreams, null);
    }

    pub fn initAccounts(allocator: std.mem.Allocator, io: std.Io, upstreams: []const Upstream, default_directory: ?[]const u8) !Registry {
        const accounts = try allocator.alloc(Account, upstreams.len + 1);
        errdefer allocator.free(accounts);
        var count: usize = 0;
        errdefer for (accounts[0..count]) |*account| {
            account.session.deinit();
            allocator.free(account.directory);
        };
        const entries = try allocator.alloc(Provider, upstreams.len);
        errdefer allocator.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |*entry| entry.deinit();
        for (entries, upstreams) |*entry, upstream| {
            try upstream.validateEndpoint();
            entry.* = .{ .upstream = upstream, .catalog = .{ .allocator = allocator } };
            initialized += 1;
            if (upstream.auth != .codex) continue;
            const directory = try normalizeDirectory(allocator, io, upstream.auth.codex);
            var directory_owned = true;
            defer if (directory_owned) allocator.free(directory);
            var found: ?*Account = null;
            for (accounts[0..count]) |*account| {
                if (std.mem.eql(u8, directory, account.directory)) {
                    found = account;
                    break;
                }
            }
            if (found == null) {
                accounts[count] = .{ .id = upstream.name, .directory = directory, .configured = true, .session = try Session.init(allocator, io, directory) };
                directory_owned = false;
                found = &accounts[count];
                count += 1;
            }
            found.?.configured = true;
            entry.account = found;
        }
        if (count == 0) {
            if (default_directory) |directory| {
                const normalized = try normalizeDirectory(allocator, io, directory);
                errdefer allocator.free(normalized);
                accounts[count] = .{ .id = "codex", .directory = normalized, .configured = false, .session = try Session.init(allocator, io, normalized) };
                count += 1;
            }
        }
        return .{ .allocator = allocator, .entries = entries, .accounts = accounts[0..count], .account_storage = accounts };
    }

    fn normalizeDirectory(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(directory)) return std.fs.path.resolve(allocator, &.{directory});
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        return std.fs.path.resolve(allocator, &.{ cwd, directory });
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries) |*entry| entry.deinit();
        for (self.accounts) |*account| {
            account.session.deinit();
            self.allocator.free(account.directory);
        }
        self.allocator.free(self.entries);
        self.allocator.free(self.account_storage);
        self.* = undefined;
    }

    /// arena_allocator must be arena-backed: lists, deduplication scratch, and
    /// JSON share the request lifetime. No cache/session pointers escape.
    pub fn modelList(self: *Registry, client: *std.http.Client, arena_allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(models.Model) = .empty;
        var available = self.entries.len == 0;
        for (self.entries) |*entry| {
            const start = list.items.len;
            available = try entry.appendModels(client, arena_allocator, &list) or available;
            for (list.items[start..]) |*model|
                model.request_constraints = if (entry.upstream.auth == .codex) models.RequestConstraints.codex else null;
        }
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

test "provider catalog aliases inherit only discovered target metadata" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const body =
        \\{"data":[{"id":"vendor/native","name":"Target","created":23,"context_length":128000,"architecture":{"input_modalities":["text","image"]},"reasoning":{"efforts":["low","high"]}},{"id":"shared","name":"Shadowed","context_length":1000},{"id":"self","max_output_tokens":42}]}
    ;
    const Fixture = @import("fixture").Fixture;
    var fixture = try Fixture.init(a, io, &.{.{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) }});
    defer fixture.deinit();
    try fixture.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    var upstream: Upstream = .{ .name = "test", .base_url = try fixture.origin(ra) };
    try upstream.aliases.map.put(ra, "shared", "vendor/native");
    try upstream.aliases.map.put(ra, "fallback", "unlisted");
    try upstream.aliases.map.put(ra, "self", "self");
    try upstream.aliases.map.put(ra, "chain", "shared");
    var registry = try Registry.init(a, io, &.{upstream});
    defer registry.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    for (0..2) |_| {
        const catalog = try registry.modelList(&client, ra);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ra, catalog, .{});
        const data = parsed.object.get("data").?.array.items;
        try std.testing.expectEqual(@as(usize, 5), data.len);
        const alias = data[0].object;
        try std.testing.expectEqualStrings("test/shared", alias.get("id").?.string);
        try std.testing.expectEqualStrings("Target", alias.get("name").?.string);
        try std.testing.expectEqual(@as(i64, 23), alias.get("created").?.integer);
        try std.testing.expectEqual(@as(i64, 128000), alias.get("context_length").?.integer);
        try std.testing.expectEqualStrings("image", alias.get("architecture").?.object.get("input_modalities").?.array.items[1].string);
        try std.testing.expectEqualStrings("high", alias.get("reasoning").?.object.get("efforts").?.array.items[1].string);
        try std.testing.expectEqualStrings("test/fallback", data[1].object.get("id").?.string);
        try std.testing.expectEqual(@as(usize, 3), data[1].object.count());
        try std.testing.expectEqual(@as(i64, 42), data[2].object.get("max_output_tokens").?.integer);
        // Routing performs one alias lookup, not recursive alias expansion.
        try std.testing.expectEqualStrings("Shadowed", data[3].object.get("name").?.string);
        try std.testing.expectEqual(@as(i64, 1000), data[3].object.get("context_length").?.integer);
        try std.testing.expectEqualStrings("test/vendor/native", data[4].object.get("id").?.string);
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
}

test "provider serialized catalog fixture binds constraints to auth including aliases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const siwc =
        \\{"models":[{"slug":"gpt-6.1-sol","display_name":"Personal Codex","visibility":"list","context_window":272000,"max_output_tokens":16000,"input_modalities":["text","image"],"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high","description":"Thorough"}],"supports_parallel_tool_calls":false,"request_constraints":{"spoofed":true}}]}
    ;
    const api_key =
        \\{"data":[{"id":"gpt-6.1-sol","name":"API-key model","created":23,"context_length":128000,"api":"openai-responses","request_constraints":{"responses":{"required":{"store":true}}}}]}
    ;
    const rich =
        \\{"data":[{"id":"vendor/rich","name":"Rich chat model","created":42,"context_length":200000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"top_provider":{"max_completion_tokens":32000},"supported_parameters":["reasoning","tools"],"reasoning":{"efforts":["low","high"]},"api":"openai-completions","extra":{"enabled":false,"nullable":null,"price":0.1234567890123456789,"precise":18446744073709551617}}]}
    ;
    const Fixture = @import("fixture").Fixture;
    var fixture = try Fixture.init(a, io, &.{
        .{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ siwc.len, siwc }) },
        .{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ api_key.len, api_key }) },
        .{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ rich.len, rich }) },
    });
    defer fixture.deinit();
    try fixture.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    const origin = try fixture.origin(ra);
    var upstreams = [_]Upstream{
        .{ .name = "personal", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/fumo-catalog-fixture" } },
        .{ .name = "codex", .base_url = origin, .auth = .{ .api_key = "fixture-key" } },
        .{ .name = "zen", .base_url = origin },
    };
    try upstreams[0].aliases.map.put(ra, "fast", "gpt-6.1-sol");
    try upstreams[0].aliases.map.put(ra, "future", "unlisted");
    try upstreams[1].aliases.map.put(ra, "quick", "gpt-6.1-sol");
    try upstreams[1].aliases.map.put(ra, "future", "unlisted");
    var registry = try Registry.init(a, io, &upstreams);
    defer registry.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    // Prewarm SIWC via a local server, without bypassing the real endpoint pin
    // or loading private credentials. Registry reads this same cached snapshot.
    var scratch: std.ArrayList(models.Model) = .empty;
    const catalog = &registry.entries[0].catalog;
    try std.testing.expect(try catalog.append(&client, ra, .{ .url = origin, .namespace = "personal", .format = .siwc }, &scratch));
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/model-catalog.json", ra, .limited(64 * 1024));
    for (0..2) |_| {
        const serialized = try registry.modelList(&client, ra);
        try std.testing.expectEqualStrings(expected, serialized);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ra, serialized, .{});
        const data = parsed.object.get("data").?.array.items;
        try std.testing.expectEqual(@as(usize, 7), data.len);
        for (data, 0..) |model, index| {
            try std.testing.expectEqual(index < 3, model.object.contains("request_constraints"));
        }
        try std.testing.expectEqualStrings("personal/future", data[1].object.get("id").?.string);
        try std.testing.expect(!data[1].object.contains("context_window"));
        try std.testing.expect(!data[2].object.contains("api"));
        try std.testing.expectEqualStrings("codex/future", data[4].object.get("id").?.string);
        try std.testing.expectEqual(@as(usize, 3), data[4].object.count());
    }
    try std.testing.expectEqual(@as(usize, 3), fixture.count.load(.acquire));
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

test "provider registry initialization cannot bypass endpoint pinning" {
    try std.testing.expectError(error.InvalidCodexEndpoint, Registry.init(std.testing.allocator, std.testing.io, &.{.{
        .name = "codex",
        .base_url = "http://127.0.0.1/v1",
        .auth = .{ .codex = "/unused" },
    }}));
}

test "provider registry allows disconnected credential storage" {
    const a = std.testing.allocator;
    const upstreams = [_]Upstream{
        .{ .name = "public", .base_url = "http://localhost/v1" },
        .{ .name = "codex", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/fumo-gateway-credentials" } },
    };
    var registry = try Registry.init(a, std.testing.io, &upstreams);
    defer registry.deinit();
    try std.testing.expectEqual(1, registry.accounts.len);
}

test "provider registry deduplicates credential storage and gives custom accounts unique ids" {
    const upstreams = [_]Upstream{
        .{ .name = "codex", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/fumo-custom" } },
        .{ .name = "shared", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/unused/../fumo-custom/" } },
        .{ .name = "default", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/fumo-default" } },
    };
    var registry = try Registry.initAccounts(std.testing.allocator, std.testing.io, &upstreams, "/nonexistent/fumo-default");
    defer registry.deinit();
    try std.testing.expectEqual(2, registry.accounts.len);
    try std.testing.expectEqualStrings("codex", registry.accounts[0].id);
    try std.testing.expectEqualStrings("default", registry.accounts[1].id);
    try std.testing.expect(registry.entries[0].account == registry.entries[1].account);
    try std.testing.expect(registry.entries[2].account == &registry.accounts[1]);
    try std.testing.expect(registry.accounts[0].configured);
    try std.testing.expect(registry.accounts[1].configured);
}

test "provider registry falls back only without configured Codex upstreams" {
    const api_key_only = [_]Upstream{
        .{ .name = "public", .base_url = "http://localhost/v1", .auth = .{ .api_key = "test-key" } },
    };
    for ([_][]const Upstream{ &.{}, &api_key_only }) |upstreams| {
        var registry = try Registry.initAccounts(std.testing.allocator, std.testing.io, upstreams, "/nonexistent/fumo-default");
        defer registry.deinit();
        try std.testing.expectEqual(1, registry.accounts.len);
        try std.testing.expectEqualStrings("codex", registry.accounts[0].id);
        try std.testing.expect(!registry.accounts[0].configured);
    }
}

test "provider registry uses configured codex account instead of default directory" {
    const upstreams = [_]Upstream{
        .{ .name = "codex", .base_url = "https://api.openai.com/v1", .auth = .{ .codex = "/nonexistent/fumo-custom" } },
    };
    var registry = try Registry.initAccounts(std.testing.allocator, std.testing.io, &upstreams, "/nonexistent/fumo-default");
    defer registry.deinit();
    try std.testing.expectEqual(1, registry.accounts.len);
    try std.testing.expectEqualStrings("codex", registry.accounts[0].id);
    try std.testing.expectEqualStrings("/nonexistent/fumo-custom", registry.accounts[0].directory);
    try std.testing.expect(registry.accounts[0].configured);
    try std.testing.expect(registry.entries[0].account == &registry.accounts[0]);
}
