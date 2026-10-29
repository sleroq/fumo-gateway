const std = @import("std");
const Upstream = @import("config.zig").Upstream;
const Provider = @import("provider.zig").Provider;

pub const max_body_size = 16 * 1024 * 1024;

pub const Pending = struct {
    request: std.http.Server.Request,
    body: []u8,
    headers: []const std.http.Header,
    client: []const u8,
    authorization: ?[]const u8 = null,
};

/// Capture headers before reading the body invalidates the HTTP head buffer.
pub fn prepare(allocator: std.mem.Allocator, request: *std.http.Server.Request, upstream: Upstream, provider: Provider, client: []const u8) !Pending {
    const headers = try requestHeaders(allocator, request, provider);
    if (request.head.content_length) |length| {
        if (length > max_body_size) return error.StreamTooLong;
    }

    const reader = try request.readerExpectContinue(&.{});
    const body = try reader.allocRemaining(allocator, .limited(max_body_size));
    const rewritten = try rewriteModel(allocator, body, upstream);

    return .{ .request = request.*, .body = rewritten, .headers = headers, .client = client };
}

fn rewriteModel(allocator: std.mem.Allocator, body: []const u8, upstream: Upstream) ![]u8 {
    var value = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidRequest,
    };

    if (value != .object) return error.InvalidRequest;
    const model = value.object.getPtr("model") orelse return error.InvalidRequest;
    if (model.* != .string) return error.InvalidRequest;
    const mapped = upstream.models.map.get(model.string) orelse return error.UnknownModel;
    model.* = .{ .string = mapped };
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Once the request body is consumed, only the monitor reads downstream. Cancel
/// and join the relay before releasing its HTTP client, buffers, or socket.
pub fn forward(io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream, upstream: Upstream, pending: *Pending) !std.http.Status {
    const Completion = union(enum) { response: anyerror!std.http.Status, disconnected: void };

    var buffer: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.disconnected, waitForDisconnect, .{ io, stream });
    try select.concurrent(.response, relay, .{ io, allocator, upstream, pending });

    return switch (try select.await()) {
        .response => |result| try result,
        .disconnected => error.DownstreamDisconnected,
    };
}

fn waitForDisconnect(io: std.Io, stream: std.Io.net.Stream) void {
    var buffer: [1024]u8 = undefined;
    var data = [_][]u8{&buffer};
    while (true) {
        const result = stream.readWithControl(io, &data, &.{}) catch return;
        if (result.data_len == 0) return;
    }
}

fn relay(io: std.Io, allocator: std.mem.Allocator, upstream: Upstream, pending: *Pending) !std.http.Status {
    var started = false;
    return relayResponse(io, allocator, upstream, pending, &started) catch |err| {
        // Reader/Writer interfaces wrap cancellation in ReadFailed/WriteFailed.
        try io.checkCancel();
        std.log.warn("event=upstream_failed error={s}", .{@errorName(err)});
        if (started) return err;
        try pending.request.respond("{\"error\":\"bad_gateway\"}\n", .{
            .status = .bad_gateway,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
        return .bad_gateway;
    };
}

fn relayResponse(io: std.Io, allocator: std.mem.Allocator, upstream: Upstream, pending: *Pending, started: *bool) !std.http.Status {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var outgoing = try client.request(.POST, try std.Uri.parse(upstream.url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (pending.authorization) |value| .{ .override = value } else .omit,
            .user_agent = .omit,
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = pending.headers,
    });
    defer outgoing.deinit();

    try outgoing.sendBodyComplete(pending.body);

    var response = try outgoing.receiveHead(&.{});
    while (response.head.status.class() == .informational) {
        if (response.head.status == .switching_protocols) return error.UnsupportedUpgrade;
        response = try outgoing.receiveHead(&.{});
    }

    const status = response.head.status;
    const headers = try responseHeaders(allocator, response.head);
    if (status == .no_content or status == .not_modified) {
        started.* = true;
        try pending.request.respond("", .{
            .status = status,
            .keep_alive = false,
            .transfer_encoding = .none,
            .extra_headers = headers,
        });
        return status;
    }

    const content_length = response.head.content_length;

    // Headers are now owned separately; response.reader invalidates the head.
    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var write_buffer: [8192]u8 = undefined;
    started.* = true;

    var body = try pending.request.respondStreaming(&write_buffer, .{
        .content_length = content_length,
        .respond_options = .{ .status = status, .keep_alive = false, .extra_headers = headers },
    });
    try body.flush();

    while (true) {
        _ = reader.stream(&body.writer, .limited(8192)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try body.writer.flush();
        try body.flush();
    }

    if (body.state == .content_length and body.state.content_length != 0)
        return error.TruncatedUpstreamResponse;
    try body.end();

    return status;
}

fn requestHeaders(allocator: std.mem.Allocator, request: *std.http.Server.Request, provider: Provider) ![]const std.http.Header {
    var result: std.ArrayList(std.http.Header) = .empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization") or
            hopByHop(header.name, request.iterateHeaders()) or
            !provider.allowsRequestHeader(header.name)) continue;
        try result.append(allocator, try copyHeader(allocator, header));
    }
    return result.toOwnedSlice(allocator);
}

fn responseHeaders(allocator: std.mem.Allocator, head: std.http.Client.Response.Head) ![]const std.http.Header {
    var result: std.ArrayList(std.http.Header) = .empty;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (hopByHop(header.name, head.iterateHeaders()) or
            std.ascii.eqlIgnoreCase(header.name, "content-length") or
            std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        try result.append(allocator, try copyHeader(allocator, header));
    }
    return result.toOwnedSlice(allocator);
}

fn copyHeader(allocator: std.mem.Allocator, header: std.http.Header) !std.http.Header {
    return .{ .name = try allocator.dupe(u8, header.name), .value = try allocator.dupe(u8, header.value) };
}

fn hopByHop(name: []const u8, iterator: std.http.HeaderIterator) bool {
    for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade" }) |hop| {
        if (std.ascii.eqlIgnoreCase(name, hop)) return true;
    }

    var headers = iterator;
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "connection")) continue;
        var tokens = std.mem.splitScalar(u8, header.value, ',');
        while (tokens.next()) |token| {
            if (std.ascii.eqlIgnoreCase(name, std.mem.trim(u8, token, " \t"))) return true;
        }
    }
    return false;
}

test "model rewrite preserves native request fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var upstream: Upstream = .{ .url = "http://localhost/v1/responses", .models = .{} };
    try upstream.models.map.put(allocator, "demo", "upstream-model");
    const body = try rewriteModel(allocator,
        \\{"model":"demo","input":[{"type":"function_call_output","call_id":"123","output":"ok"}],"stream":true,"reasoning":{"effort":"high"},"previous_response_id":"resp_1","metadata":{"precise":18446744073709551617}}
    , upstream);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{});
    try std.testing.expectEqualStrings("upstream-model", value.object.get("model").?.string);
    try std.testing.expectEqualStrings("function_call_output", value.object.get("input").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("resp_1", value.object.get("previous_response_id").?.string);
    try std.testing.expect(std.mem.find(u8, body, "18446744073709551617") != null);
    try std.testing.expectError(error.UnknownModel, rewriteModel(allocator, "{\"model\":\"unknown\"}", upstream));
    for ([_][]const u8{ "invalid", "[]", "{}", "{\"model\":1}" }) |invalid| {
        try std.testing.expectError(error.InvalidRequest, rewriteModel(allocator, invalid, upstream));
    }
}

test "transport applies the supplied provider contract without forwarding gateway auth or hop headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer secret\r\nCookie: secret\r\nProxy-Authorization: secret\r\nSession_id: session\r\nOpenAI-Beta: responses=v1\r\nConnection: openai-beta\r\n\r\n");
    var writer: std.Io.Writer.Discarding = .init(&.{});
    var http = std.http.Server.init(&reader, &writer.writer);
    var request = try http.receiveHead();
    // Deliberately allow auth and a connection-nominated header to verify that
    // provider policy cannot override the transport's exclusions.
    const provider: Provider = .{ .request_headers = &.{ "session_id", "openai-beta", "authorization", "connection" } };
    const headers = try requestHeaders(arena.allocator(), &request, provider);
    try std.testing.expectEqual(1, headers.len);
    try std.testing.expectEqualStrings("Session_id", headers[0].name);
    try std.testing.expectEqualStrings("session", headers[0].value);
    const no_headers: Provider = .{ .request_headers = &.{} };
    try std.testing.expectEqual(0, (try requestHeaders(arena.allocator(), &request, no_headers)).len);
}
