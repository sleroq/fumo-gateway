const std = @import("std");
const Io = std.Io;

// SIWC credentials use the same /v1/models path but an account-specific schema:
// https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
pub const Format = enum { openai, siwc };

/// Borrows request-owned credentials and immutable provider definitions only
/// until append returns. Credential errors can preserve a previous catalog.
pub const Source = struct {
    url: []const u8,
    authorization: anyerror!?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    namespace: []const u8,
    format: Format = .openai,
};

/// Gateway-owned HTTP Responses policy, independent of native model metadata.
pub const RequestConstraints = struct {
    responses: struct {
        omit: []const []const u8,
        function_tools: []const u8,
        unsupported_tools: []const []const u8,
    },

    // https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
    pub const codex: RequestConstraints = .{ .responses = .{
        .omit = &.{ "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id" },
        .function_tools = "namespaced-or-additional",
        .unsupported_tools = &.{ "image_generation", "file_search", "code_interpreter", "computer_use_preview", "mcp", "tool_search", "programmatic_tool_calling" },
    } };
};

pub const Model = struct {
    name: ?[]const u8 = null,
    id: []const u8,
    object: []const u8 = "model",
    created: ?i64 = null,
    owned_by: []const u8,
    /// Omitted means unknown/no gateway policy, not unrestricted support.
    request_constraints: ?RequestConstraints = null,
    /// Native discovery extensions, emitted at the catalog entry's top level.
    metadata: std.json.ObjectMap = .empty,

    pub fn jsonStringify(self: Model, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("id");
        try writer.write(self.id);
        try writer.objectField("object");
        try writer.write(self.object);
        try writer.objectField("owned_by");
        try writer.write(self.owned_by);
        if (self.name) |name| {
            try writer.objectField("name");
            try writer.write(name);
        }
        if (self.created) |created| {
            try writer.objectField("created");
            try writer.write(created);
        }
        if (self.request_constraints) |constraints| {
            try writer.objectField("request_constraints");
            try writer.write(constraints);
        }
        var fields = self.metadata.iterator();
        while (fields.next()) |field| {
            try writer.objectField(field.key_ptr.*);
            try writer.write(field.value_ptr.*);
        }
        try writer.endObject();
    }

    fn copy(self: Model, allocator: std.mem.Allocator) !Model {
        var result = self;
        result.id = try allocator.dupe(u8, self.id);
        result.name = if (self.name) |name| try allocator.dupe(u8, name) else null;
        result.object = try allocator.dupe(u8, self.object);
        result.owned_by = try allocator.dupe(u8, self.owned_by);
        result.metadata = (try copyValue(allocator, .{ .object = self.metadata })).object;
        return result;
    }
};

fn copyValue(allocator: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        .array => |array| blk: {
            var result = std.json.Array.init(allocator);
            for (array.items) |item| try result.append(try copyValue(allocator, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result: std.json.ObjectMap = .empty;
            var fields = object.iterator();
            while (fields.next()) |field|
                try result.put(allocator, try allocator.dupe(u8, field.key_ptr.*), try copyValue(allocator, field.value_ptr.*));
            break :blk .{ .object = result };
        },
        else => value,
    };
}

/// Service-owned snapshot. Keep at a stable address and join discovery callers
/// before deinit. The mutex protects refresh and copying, not inference.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    arena: ?std.heap.ArenaAllocator = null,
    models: []const Model = &.{},
    next_refresh: i64 = 0,
    ttl: Io.Duration = .fromSeconds(300),
    retry: Io.Duration = .fromSeconds(30),
    timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(5), .clock = .awake },

    pub fn deinit(self: *Cache) void {
        if (self.arena) |*arena| arena.deinit();
    }

    /// request_allocator must be arena-backed, including partial output on error.
    /// The caller's arena owns all output strings. No snapshot pointers escape
    /// the lock, and fetch joins its child before replacing or freeing scratch.
    pub fn append(self: *Cache, client: *std.http.Client, request_allocator: std.mem.Allocator, source: Source, output: *std.ArrayList(Model)) !bool {
        // Credential failures may use stale data, but cancellation/allocation
        // failures belong to this request even when no refresh is necessary.
        if (source.authorization) |_| {} else |err| {
            if (err == error.Canceled or err == error.OutOfMemory) return err;
        }
        const io = client.io;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const now = Io.Clock.awake.now(io).toMilliseconds();
        if (now >= self.next_refresh) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            if (self.fetch(client, arena.allocator(), source)) |models| {
                if (self.arena) |*old| old.deinit();
                self.arena = arena;
                arena = std.heap.ArenaAllocator.init(self.allocator);
                self.models = models;
                self.next_refresh = now + @as(i64, @intCast(self.ttl.toMilliseconds()));
            } else |err| {
                switch (err) {
                    error.OutOfMemory, error.Canceled => return err,
                    else => {},
                }
                std.log.warn("event=model_discovery_failed upstream={s} error={s}", .{ source.namespace, @errorName(err) });
                self.next_refresh = now + @as(i64, @intCast(self.retry.toMilliseconds()));
            }
        }
        if (self.arena == null) return false;
        for (self.models) |model| {
            try output.append(request_allocator, try model.copy(request_allocator));
        }
        return true;
    }

    fn fetch(self: *Cache, client: *std.http.Client, allocator: std.mem.Allocator, source: Source) ![]const Model {
        const io = client.io;
        const deadline = Io.Clock.Timestamp.fromNow(io, self.timeout);
        var completed: Io.Semaphore = .{};
        var task = try io.concurrent(request, .{ client, allocator, source, &completed });
        defer {
            if (task.cancel(io)) |_| {} else |_| {}
        }
        completed.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return error.ModelsTimedOut,
            else => return err,
        };
        return try task.await(io);
    }

    fn request(client: *std.http.Client, allocator: std.mem.Allocator, source: Source, completed: *Io.Semaphore) ![]const Model {
        defer completed.post(client.io);
        return load(client, allocator, source);
    }

    fn load(client: *std.http.Client, allocator: std.mem.Allocator, source: Source) ![]const Model {
        const authorization = try source.authorization;
        var req = try client.request(.GET, try std.Uri.parse(source.url), .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = if (authorization) |value| .{ .override = value } else .omit,
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = source.headers,
        });
        defer req.deinit();
        const body = readBody(&req, allocator) catch |err| {
            const connection = req.connection.?;
            connection.closing = true;
            switch (err) {
                error.ReadFailed => {
                    if (req.reader.body_err == null and (connection.getReadError() orelse err) == error.Canceled)
                        return error.Canceled;
                },
                error.WriteFailed => {
                    if ((connection.stream_writer.err orelse err) == error.Canceled) return error.Canceled;
                },
                else => {},
            }
            return err;
        };
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .parse_numbers = false };
        const entries = switch (source.format) {
            .openai => (try std.json.parseFromSliceLeaky(struct { data: []std.json.Value }, allocator, body, options)).data,
            .siwc => (try std.json.parseFromSliceLeaky(struct { models: []std.json.Value }, allocator, body, options)).models,
        };
        var result: std.ArrayList(Model) = .empty;
        const owner = try allocator.dupe(u8, source.namespace);
        for (entries) |value| {
            const Entry = struct { id: []const u8, created: ?i64 = null, name: ?[]const u8 = null };
            const entry: Entry = switch (source.format) {
                .openai => try std.json.parseFromValueLeaky(Entry, allocator, value, options),
                .siwc => blk: {
                    const SiwcEntry = struct { slug: []const u8, display_name: []const u8, visibility: []const u8, created: ?i64 = null };
                    const siwc = try std.json.parseFromValueLeaky(SiwcEntry, allocator, value, options);
                    if (!std.mem.eql(u8, siwc.visibility, "list")) continue;
                    break :blk .{ .id = siwc.slug, .name = siwc.display_name, .created = siwc.created };
                },
            };
            if (entry.id.len == 0) return error.EmptyModelId;
            var metadata = value.object;
            for ([_][]const u8{ "id", "object", "owned_by", "name", "created", "request_constraints" }) |field| _ = metadata.orderedRemove(field);
            try result.append(allocator, .{
                .id = try allocator.print("{s}/{s}", .{ source.namespace, entry.id }),
                .created = entry.created,
                .name = entry.name,
                .owned_by = owner,
                .metadata = metadata,
            });
        }
        return result.items;
    }

    fn readBody(req: *std.http.Client.Request, allocator: std.mem.Allocator) ![]const u8 {
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        while (response.head.status.class() == .informational) {
            if (response.head.status == .switching_protocols) return error.UnsupportedUpgrade;
            response = try req.receiveHead(&.{});
        }
        if (response.head.status != .ok) return error.ModelsHttpFailure;
        return try response.reader(&.{}).allocRemaining(allocator, .limited(4 * 1024 * 1024));
    }
};

const Fixture = @import("fixture").Fixture;

test "models fetch authorization nested IDs TTL refresh and stale snapshot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const first =
        \\{"data":[{"id":"org/model","name":"Upstream label","created":12,"object":"upstream-model","owned_by":"upstream-owner","context_length":200000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"top_provider":{"max_completion_tokens":32000},"supported_parameters":["reasoning","tools"],"extra":{"enabled":false,"nullable":null,"price":0.1234567890123456789,"precise":18446744073709551617},"metadata":{"native":true}}]}
    ;
    const second = "{\"data\":[{\"id\":\"replacement\"}]}";
    const first_reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ first.len, first });
    const second_reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ second.len, second });
    var fixture = try Fixture.init(a, io, &.{ .{ .bytes = first_reply }, .{ .bytes = second_reply }, .{ .bytes = "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n" } });
    defer fixture.deinit();
    try fixture.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    const url = try ra.print("{s}/prefix/models", .{try fixture.origin(ra)});
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var cache: Cache = .{ .allocator = a };
    defer cache.deinit();
    var output: std.ArrayList(Model) = .empty;
    try std.testing.expect(try cache.append(&client, ra, .{ .url = url, .authorization = "Bearer secret", .headers = &.{.{ .name = "x-test", .value = "yes" }}, .namespace = "provider", .format = .openai }, &output));
    try fixture.waitRequest();
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqualStrings("provider/org/model", output.items[0].id);
    try std.testing.expectEqual(@as(?i64, 12), output.items[0].created);
    try std.testing.expect(std.mem.containsAtLeast(u8, fixture.requests[0].?, 1, "GET /prefix/models "));
    try std.testing.expect(std.mem.containsAtLeast(u8, fixture.requests[0].?, 1, "Bearer secret"));
    var cached: std.ArrayList(Model) = .empty;
    _ = try cache.append(&client, ra, .{ .url = url, .authorization = null, .headers = &.{}, .namespace = "provider", .format = .openai }, &cached);
    try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
    cache.next_refresh = 0;
    cached.clearRetainingCapacity();
    _ = try cache.append(&client, ra, .{ .url = url, .authorization = null, .headers = &.{}, .namespace = "provider", .format = .openai }, &cached);
    try std.testing.expectEqualStrings("provider/replacement", cached.items[0].id);
    try std.testing.expectEqualStrings("provider/org/model", output.items[0].id);
    // Refresh freed the original cache arena. Nested fields in both prior
    // request-owned copies must still serialize without losing numeric precision.
    const serialized = try std.json.Stringify.valueAlloc(ra, output.items[0], .{});
    const copied = try std.json.parseFromSliceLeaky(std.json.Value, ra, serialized, .{});
    try std.testing.expectEqualStrings("model", copied.object.get("object").?.string);
    try std.testing.expectEqualStrings("provider", copied.object.get("owned_by").?.string);
    try std.testing.expectEqualStrings("Upstream label", copied.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 200000), copied.object.get("context_length").?.integer);
    try std.testing.expectEqualStrings("image", copied.object.get("architecture").?.object.get("input_modalities").?.array.items[1].string);
    try std.testing.expectEqual(@as(i64, 32000), copied.object.get("top_provider").?.object.get("max_completion_tokens").?.integer);
    try std.testing.expectEqualStrings("reasoning", copied.object.get("supported_parameters").?.array.items[0].string);
    try std.testing.expect(!copied.object.get("extra").?.object.get("enabled").?.bool);
    try std.testing.expectEqual(.null, copied.object.get("extra").?.object.get("nullable").?);
    try std.testing.expect(copied.object.get("metadata").?.object.get("native").?.bool);
    try std.testing.expect(std.mem.find(u8, serialized, "0.1234567890123456789") != null);
    try std.testing.expect(std.mem.find(u8, serialized, "18446744073709551617") != null);
    cache.next_refresh = 0;
    cached.clearRetainingCapacity();
    try std.testing.expect(try cache.append(&client, ra, .{ .url = url, .authorization = null, .headers = &.{}, .namespace = "provider", .format = .openai }, &cached));
    try std.testing.expectEqualStrings("provider/replacement", cached.items[0].id);
    const sparse = try std.json.Stringify.valueAlloc(ra, cached.items[0], .{});
    try std.testing.expectEqualStrings("{\"id\":\"provider/replacement\",\"object\":\"model\",\"owned_by\":\"provider\"}", sparse);
}

test "models malformed response is not cached and timeout joins socket task" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "{\"data\":[{\"id\":\"\"}]}", "{\"data\":[{\"id\":12}]}", "{\"data\":[{}]}", "" }) |body| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ra = arena.allocator();
        var gate: Io.Semaphore = .{};
        const reply = try ra.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        var fixture = try Fixture.init(a, io, &.{.{ .bytes = if (body.len == 0) "" else reply, .gate = if (body.len == 0) &gate else null }});
        defer fixture.deinit();
        try fixture.start();
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        var cache: Cache = .{ .allocator = a, .timeout = .{ .raw = .fromMilliseconds(100), .clock = .awake } };
        defer cache.deinit();
        var output: std.ArrayList(Model) = .empty;
        try std.testing.expect(!try cache.append(&client, ra, .{ .url = try fixture.origin(ra), .authorization = null, .headers = &.{}, .namespace = "provider", .format = .openai }, &output));
        try std.testing.expect(cache.arena == null);
        try std.testing.expectEqual(@as(usize, 0), output.items.len);
    }
}

test "models SIWC lists visible slugs and labels in server order" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const body =
        \\{"models":[{"slug":"z/model","display_name":"First model","visibility":"list","context_window":272000,"max_output_tokens":16000,"input_modalities":["text","image"],"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high","description":"Thorough"}],"supports_parallel_tool_calls":false},{"slug":"hidden","display_name":"Hidden","visibility":"hidden","context_window":1},{"slug":"alpha","display_name":"Second","visibility":"list"}]}
    ;
    const reply = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    var fixture = try Fixture.init(a, io, &.{.{ .bytes = reply }});
    defer fixture.deinit();
    try fixture.start();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ra = arena.allocator();
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var cache: Cache = .{ .allocator = a };
    defer cache.deinit();
    var output: std.ArrayList(Model) = .empty;
    try std.testing.expect(try cache.append(&client, ra, .{ .url = try fixture.origin(ra), .authorization = "Bearer token", .headers = &.{}, .namespace = "codex", .format = .siwc }, &output));
    try std.testing.expectEqual(@as(usize, 2), output.items.len);
    try std.testing.expectEqualStrings("codex/z/model", output.items[0].id);
    try std.testing.expectEqualStrings("First model", output.items[0].name.?);
    try std.testing.expectEqualStrings("codex/alpha", output.items[1].id);
    cache.deinit();
    cache.arena = null;
    try std.testing.expectEqualStrings("First model", output.items[0].name.?);
    const serialized = try std.json.Stringify.valueAlloc(ra, output.items, .{});
    const copied = try std.json.parseFromSliceLeaky(std.json.Value, ra, serialized, .{});
    const rich = copied.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 272000), rich.get("context_window").?.integer);
    try std.testing.expectEqual(@as(i64, 16000), rich.get("max_output_tokens").?.integer);
    try std.testing.expectEqualStrings("image", rich.get("input_modalities").?.array.items[1].string);
    try std.testing.expectEqualStrings("medium", rich.get("default_reasoning_level").?.string);
    const reasoning = rich.get("supported_reasoning_levels").?.array.items;
    try std.testing.expectEqualStrings("low", reasoning[0].object.get("effort").?.string);
    try std.testing.expectEqualStrings("Thorough", reasoning[1].object.get("description").?.string);
    try std.testing.expect(!rich.get("supports_parallel_tool_calls").?.bool);
    try std.testing.expect(!rich.contains("created"));
    const sparse = copied.array.items[1].object;
    for ([_][]const u8{ "context_window", "max_output_tokens", "input_modalities", "default_reasoning_level", "supported_reasoning_levels", "supports_parallel_tool_calls", "created" }) |field|
        try std.testing.expect(!sparse.contains(field));
}

const Caller = struct {
    cache: *Cache,
    client: *std.http.Client,
    source: Source,
    arena: std.heap.ArenaAllocator,
    output: std.ArrayList(Model) = .empty,
    started: Io.Semaphore = .{},

    fn run(self: *Caller) !bool {
        self.started.post(self.client.io);
        return self.cache.append(self.client, self.arena.allocator(), self.source, &self.output);
    }
};

test "models concurrent callers singleflight and independent result ownership" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const body = "{\"data\":[{\"id\":\"one\"}]}";
    var gate: Io.Semaphore = .{};
    var fixture = try Fixture.init(a, io, &.{.{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{body.len}), .gate = &gate, .tail = body }});
    defer fixture.deinit();
    try fixture.start();
    const url = try fixture.origin(a);
    defer a.free(url);
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var cache: Cache = .{ .allocator = a };
    defer cache.deinit();
    const source: Source = .{ .url = url, .namespace = "provider" };
    var first: Caller = .{ .cache = &cache, .client = &client, .source = source, .arena = .init(a) };
    defer first.arena.deinit();
    var second: Caller = .{ .cache = &cache, .client = &client, .source = source, .arena = .init(a) };
    defer second.arena.deinit();
    var task1 = try io.concurrent(Caller.run, .{&first});
    defer {
        _ = task1.cancel(io) catch {};
    }
    try fixture.waitRequest();
    var task2 = try io.concurrent(Caller.run, .{&second});
    defer {
        _ = task2.cancel(io) catch {};
    }
    try second.started.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    gate.post(io);
    try std.testing.expect(try task1.await(io));
    try std.testing.expect(try task2.await(io));
    try std.testing.expectEqual(@as(usize, 1), fixture.count.load(.acquire));
    var canceled = source;
    canceled.authorization = error.Canceled;
    try std.testing.expectError(error.Canceled, cache.append(&client, second.arena.allocator(), canceled, &second.output));
    canceled.authorization = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, cache.append(&client, second.arena.allocator(), canceled, &second.output));
    cache.next_refresh = 0;
    var unavailable = source;
    unavailable.authorization = error.CredentialsUnavailable;
    var stale: std.ArrayList(Model) = .empty;
    try std.testing.expect(try cache.append(&client, second.arena.allocator(), unavailable, &stale));
    try std.testing.expectEqualStrings("provider/one", stale.items[0].id);
    cache.deinit();
    cache.arena = null;
    try std.testing.expectEqualStrings("provider/one", first.output.items[0].id);
    try std.testing.expectEqualStrings("provider/one", second.output.items[0].id);
    try std.testing.expect(first.output.items[0].id.ptr != second.output.items[0].id.ptr);
}

test "models caller cancellation joins socket and releases cache mutex" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const body = "{\"data\":[]}";
    var gate: Io.Semaphore = .{};
    var fixture = try Fixture.init(a, io, &.{
        .{ .bytes = "", .gate = &gate, .peer_eof = true },
        .{ .bytes = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) },
    });
    defer fixture.deinit();
    try fixture.start();
    const url = try fixture.origin(a);
    defer a.free(url);
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var cache: Cache = .{ .allocator = a };
    defer cache.deinit();
    var caller: Caller = .{ .cache = &cache, .client = &client, .source = .{ .url = url, .namespace = "provider" }, .arena = .init(a) };
    defer caller.arena.deinit();
    var task = try io.concurrent(Caller.run, .{&caller});
    defer {
        _ = task.cancel(io) catch {};
    }
    try fixture.waitRequest();
    try std.testing.expectError(error.Canceled, task.cancel(io));
    gate.post(io);
    try fixture.waitEof();
    try std.testing.expect(try caller.run());
    try std.testing.expectEqual(@as(usize, 2), fixture.count.load(.acquire));
}
