const std = @import("std");
const Io = std.Io;

pub const Reply = struct {
    bytes: []const u8,
    gate: ?*Io.Semaphore = null,
    tail: []const u8 = "",
    peer_eof: bool = false,
    /// Serve the following reply on this same accepted socket.
    reuse: bool = false,
};

/// Fixed local HTTP exchanges. Keep at a stable address after start. Captures
/// become readable after waitRequest; reply buffers and gates are caller-owned.
pub const Fixture = struct {
    allocator: std.mem.Allocator,
    io: Io,
    listener: Io.net.Server,
    replies: []const Reply,
    requests: []?[]u8,
    count: std.atomic.Value(usize) = .init(0),
    accepted: std.atomic.Value(usize) = .init(0),
    received: Io.Semaphore = .{},
    eof: Io.Semaphore = .{},
    tasks: Io.Group = .init,
    failure: std.atomic.Value(u16) = .init(0),

    pub fn init(allocator: std.mem.Allocator, io: Io, replies: []const Reply) !Fixture {
        var listener = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
        errdefer listener.deinit(io);
        const requests = try allocator.alloc(?[]u8, replies.len);
        @memset(requests, null);
        return .{ .allocator = allocator, .io = io, .listener = listener, .replies = replies, .requests = requests };
    }

    pub fn start(self: *Fixture) !void {
        try self.tasks.concurrent(self.io, serve, .{self});
    }

    pub fn origin(self: *const Fixture, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://{f}", .{self.listener.socket.address});
    }

    fn check(self: *Fixture) !void {
        const code = self.failure.load(.acquire);
        if (code != 0) return @errorFromInt(code);
    }

    pub fn waitRequest(self: *Fixture) !void {
        try self.received.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try self.check();
    }

    pub fn waitEof(self: *Fixture) !void {
        try self.eof.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try self.check();
    }

    pub fn deinit(self: *Fixture) void {
        self.tasks.cancel(self.io);
        self.listener.deinit(self.io);
        for (self.requests) |request| if (request) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.requests);
        self.check() catch |err| std.debug.panic("HTTP fixture failed: {s}", .{@errorName(err)});
    }

    fn serve(self: *Fixture) void {
        self.run() catch |err| {
            if (err == error.Canceled) return;
            self.failure.store(@intFromError(err), .release);
            self.received.post(self.io);
            self.eof.post(self.io);
        };
    }

    fn run(self: *Fixture) !void {
        var index: usize = 0;
        while (index < self.replies.len) {
            const stream = try self.listener.accept(self.io);
            defer stream.close(self.io);
            _ = self.accepted.fetchAdd(1, .release);
            var buffer: [8192]u8 = undefined;
            var reader = stream.reader(self.io, &buffer);
            while (index < self.replies.len) {
                const reply = self.replies[index];
                var raw: std.Io.Writer.Allocating = .init(self.allocator);
                defer raw.deinit();
                var content_length: usize = 0;
                while (true) {
                    const line = try reader.interface.takeDelimiterInclusive('\n');
                    try raw.writer.writeAll(line);
                    if (std.ascii.startsWithIgnoreCase(line, "content-length:"))
                        content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
                    if (std.mem.eql(u8, line, "\r\n")) break;
                }
                if (content_length > 1024 * 1024) return error.RequestTooLarge;
                const body = try self.allocator.alloc(u8, content_length);
                defer self.allocator.free(body);
                try reader.interface.readSliceAll(body);
                try raw.writer.writeAll(body);
                self.requests[index] = try self.allocator.dupe(u8, raw.written());
                _ = self.count.fetchAdd(1, .release);
                self.received.post(self.io);
                var write_buffer: [1024]u8 = undefined;
                var writer = stream.writer(self.io, &write_buffer);
                try writer.interface.writeAll(reply.bytes);
                try writer.interface.flush();
                if (reply.gate) |gate| try gate.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
                try writer.interface.writeAll(reply.tail);
                try writer.interface.flush();
                if (reply.peer_eof) {
                    while (true) _ = reader.interface.takeByte() catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return reader.err orelse err,
                    };
                    self.eof.post(self.io);
                }
                index += 1;
                if (!reply.reuse) break;
            }
        }
    }
};
