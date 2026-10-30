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

pub const Model = struct {
    name: ?[]const u8 = null,
    id: []const u8,
    object: []const u8 = "model",
    created: i64 = 0,
    owned_by: []const u8,
};

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
            try output.append(request_allocator, .{
                .id = try request_allocator.dupe(u8, model.id),
                .name = if (model.name) |name| try request_allocator.dupe(u8, name) else null,
                .object = try request_allocator.dupe(u8, model.object),
                .created = model.created,
                .owned_by = try request_allocator.dupe(u8, model.owned_by),
            });
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
        const Entry = struct { id: []const u8, created: i64 = 0, name: ?[]const u8 = null };
        const entries = switch (source.format) {
            .openai => (try std.json.parseFromSliceLeaky(struct { data: []Entry }, allocator, body, .{ .ignore_unknown_fields = true })).data,
            .siwc => blk: {
                const SiwcEntry = struct { slug: []const u8, display_name: []const u8, visibility: []const u8 };
                const parsed = try std.json.parseFromSliceLeaky(struct { models: []SiwcEntry }, allocator, body, .{ .ignore_unknown_fields = true });
                var listed: std.ArrayList(Entry) = .empty;
                for (parsed.models) |entry| {
                    if (entry.slug.len == 0) return error.EmptyModelId;
                    if (std.mem.eql(u8, entry.visibility, "list"))
                        try listed.append(allocator, .{ .id = entry.slug, .name = entry.display_name });
                }
                break :blk listed.items;
            },
        };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var result: std.ArrayList(Model) = .empty;
        const owner = try allocator.dupe(u8, source.namespace);
        for (entries) |entry| {
            if (entry.id.len == 0) return error.EmptyModelId;
            const slot = try seen.getOrPut(allocator, entry.id);
            if (slot.found_existing) continue;
            try result.append(allocator, .{
                .id = try allocator.print("{s}/{s}", .{ source.namespace, entry.id }),
                .created = entry.created,
                .name = entry.name,
                .owned_by = owner,
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
    const first = "{\"data\":[{\"id\":\"org/model\",\"created\":12,\"extra\":true},{\"id\":\"org/model\"}]}";
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
    try std.testing.expectEqual(@as(i64, 12), output.items[0].created);
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
    cache.next_refresh = 0;
    cached.clearRetainingCapacity();
    try std.testing.expect(try cache.append(&client, ra, .{ .url = url, .authorization = null, .headers = &.{}, .namespace = "provider", .format = .openai }, &cached));
    try std.testing.expectEqualStrings("provider/replacement", cached.items[0].id);
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
    const body = "{\"models\":[{\"slug\":\"z/model\",\"display_name\":\"First model\",\"visibility\":\"list\"},{\"slug\":\"hidden\",\"display_name\":\"Hidden\",\"visibility\":\"hidden\"},{\"slug\":\"alpha\",\"display_name\":\"Second\",\"visibility\":\"list\"}]}";
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
