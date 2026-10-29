const std = @import("std");
const Upstream = @import("provider.zig").Upstream;
const Contract = @import("provider.zig").Contract;

pub const max_body_size = 16 * 1024 * 1024;

pub const Pending = struct {
    request: std.http.Server.Request,
    url: []const u8,
    body: []u8,
    headers: []const std.http.Header,
    client: []const u8,
    authorization: ?[]const u8 = null,
};

/// gpa reclaims input/parsing scratch before return; allocator owns pending data.
/// Capture headers before reading the body invalidates the HTTP head buffer.
pub fn prepare(gpa: std.mem.Allocator, allocator: std.mem.Allocator, request: *std.http.Server.Request, upstream: Upstream, client: []const u8) !Pending {
    const headers = try requestHeaders(allocator, request, upstream.contract());
    if (request.head.content_length) |length| {
        if (length > max_body_size) return error.StreamTooLong;
    }

    const reader = try request.readerExpectContinue(&.{});
    const body = try reader.allocRemaining(gpa, .limited(max_body_size));
    defer gpa.free(body);
    const rewritten = try upstream.contract().rewriteRequest(gpa, allocator, body, upstream.models);

    return .{ .request = request.*, .url = upstream.url, .body = rewritten, .headers = headers, .client = client };
}

/// Once the request body is consumed, only the monitor reads downstream. EOF
/// closes only the client's sending direction; transport errors cancel the relay.
/// Join both tasks before releasing their buffers or socket. The HTTP client
/// is borrowed from the service and outlives every relay.
pub fn forward(client: *std.http.Client, allocator: std.mem.Allocator, stream: std.Io.net.Stream, pending: *Pending) !std.http.Status {
    const io = client.io;
    const Completion = union(enum) { response: anyerror!std.http.Status, downstream: std.Io.net.Stream.Reader.Error!void };

    var buffer: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &buffer);
    defer select.cancelDiscard();

    try select.concurrent(.downstream, monitorDownstream, .{ io, stream });
    try select.concurrent(.response, relay, .{ client, allocator, pending });

    while (true) switch (try select.await()) {
        .response => |result| return result,
        .downstream => |result| try result,
    };
}

fn monitorDownstream(io: std.Io, stream: std.Io.net.Stream) std.Io.net.Stream.Reader.Error!void {
    var buffer: [1024]u8 = undefined;
    var data = [_][]u8{&buffer};
    while (true) {
        const result = try stream.readWithControl(io, &data, &.{});
        if (result.data_len == 0) return;
    }
}

fn relay(client: *std.http.Client, allocator: std.mem.Allocator, pending: *Pending) !std.http.Status {
    var started = false;
    return relayResponse(client, allocator, pending, &started) catch |err| {
        if (err == error.Canceled) return error.Canceled;
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

fn relayResponse(client: *std.http.Client, allocator: std.mem.Allocator, pending: *Pending, started: *bool) !std.http.Status {
    var outgoing = try client.request(.POST, try std.Uri.parse(pending.url), .{
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

    return transferResponse(&outgoing, allocator, pending, started) catch |err| {
        // Cancellation is one-shot; recover it before deinit loses the transport errors.
        const connection = outgoing.connection.?;
        const read_err = connection.stream_reader.err orelse err;
        const write_err = connection.stream_writer.err orelse err;
        switch (err) {
            error.ReadFailed => {
                if (outgoing.reader.body_err == null and (read_err == error.Canceled or write_err == error.Canceled))
                    return error.Canceled;
            },
            error.WriteFailed => {
                if (write_err == error.Canceled) return error.Canceled;
            },
            else => {},
        }
        return err;
    };
}

fn transferResponse(outgoing: *std.http.Client.Request, allocator: std.mem.Allocator, pending: *Pending, started: *bool) !std.http.Status {
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

fn requestHeaders(allocator: std.mem.Allocator, request: *std.http.Server.Request, contract: Contract) ![]const std.http.Header {
    var result: std.ArrayList(std.http.Header) = .empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization") or
            hopByHop(header.name, request.iterateHeaders()) or
            !contract.allowsRequestHeader(header.name)) continue;
        try result.append(allocator, try copyHeader(allocator, header));
    }
    try result.appendSlice(allocator, contract.requiredHeaders());
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

test "transport relay cancellation before headers or during a body propagates without a 502" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Body = struct {
        fn observe(stream: std.Io.net.Stream, completed: *std.Io.Semaphore) !void {
            defer completed.post(std.testing.io);
            var buffer: [1024]u8 = undefined;
            var reader = stream.reader(std.testing.io, &buffer);
            while (try reader.interface.takeByte() != 'x') {}
        }
    };
    const cases = [_][]const u8{
        "",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n",
    };
    for (cases) |reply| {
        var fixture = try @import("fixture").Fixture.init(a, io, &.{.{ .bytes = reply, .peer_eof = true }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        var listener = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{});
        defer listener.deinit(io);
        const downstream = try listener.socket.address.connect(io, .{ .mode = .stream });
        defer downstream.close(io);
        const accepted = try listener.accept(io);
        defer accepted.close(io);
        var write_buffer: [1024]u8 = undefined;
        var writer = accepted.writer(io, &write_buffer);
        var request_reader = std.Io.Reader.fixed("POST /v1/responses HTTP/1.1\r\n\r\n");
        var http = std.http.Server.init(&request_reader, &writer.interface);
        var body = "{}".*;
        var pending: Pending = .{ .request = try http.receiveHead(), .url = origin, .body = &body, .headers = &.{}, .client = "fixture" };
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var task = try io.concurrent(relay, .{ &client, arena.allocator(), &pending });
        defer _ = task.cancel(io) catch {};
        try fixture.waitRequest();
        if (reply.len != 0) {
            // Observe forwarded body data before canceling, not just an upstream write.
            var completed: std.Io.Semaphore = .{};
            var observation = try io.concurrent(Body.observe, .{ downstream, &completed });
            defer _ = observation.cancel(io) catch {};
            try completed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
            try observation.await(io);
        }
        try std.testing.expectError(error.Canceled, task.cancel(io));
        try fixture.waitEof();
        try std.testing.expectEqual(1, fixture.count.load(.acquire));
        try std.testing.expect(client.connection_pool.used.first == null);
    }
}

test "transport malformed or truncated chunk framing remains a non-cancellation error" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "invalid\r\n", "3\r\nx" }) |chunk| {
        const reply = try std.mem.concat(a, u8, &.{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", chunk });
        defer a.free(reply);
        var fixture = try @import("fixture").Fixture.init(a, io, &.{.{ .bytes = reply }});
        defer fixture.deinit();
        try fixture.start();
        const origin = try fixture.origin(a);
        defer a.free(origin);
        var client: std.http.Client = .{ .allocator = a, .io = io };
        defer client.deinit();
        var writer: std.Io.Writer.Allocating = .init(a);
        defer writer.deinit();
        var reader = std.Io.Reader.fixed("POST /v1/responses HTTP/1.1\r\n\r\n");
        var http = std.http.Server.init(&reader, &writer.writer);
        var body = "{}".*;
        var pending: Pending = .{ .request = try http.receiveHead(), .url = origin, .body = &body, .headers = &.{}, .client = "fixture" };
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try std.testing.expectError(error.ReadFailed, relay(&client, arena.allocator(), &pending));
        try std.testing.expect(std.mem.startsWith(u8, writer.written(), "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.find(u8, writer.written(), "bad_gateway") == null);
        try fixture.waitRequest();
        try std.testing.expectEqual(1, fixture.count.load(.acquire));
    }
}

test "transport preparation releases scratch before pending data is used" {
    const a = std.testing.allocator;
    var upstream: Upstream = .{
        .url = "https://api.openai.com/v1/responses",
        .models = .{},
        .auth = .{ .provider = .codex },
    };
    defer upstream.models.deinit(a);
    try upstream.models.map.put(a, "demo", "upstream-model");
    const cases = [_]struct { body: []const u8, err: ?anyerror = null }{
        .{ .body = "{\"model\":\"demo\",\"stream\":true,\"input\":[0,1,2]}" },
        .{ .body = "{\"model\":", .err = error.InvalidRequest },
        .{ .body = "{\"model\":\"unknown\",\"stream\":true}", .err = error.UnknownModel },
        .{ .body = "{\"model\":\"demo\",\"stream\":false}", .err = error.InvalidRequest },
    };
    for (cases) |case| {
        const raw = try std.fmt.allocPrint(a, "POST /v1/responses HTTP/1.1\r\nSession_id: session\r\nContent-Length: {d}\r\n\r\n{s}", .{ case.body.len, case.body });
        defer a.free(raw);
        var reader = std.Io.Reader.fixed(raw);
        var writer: std.Io.Writer.Discarding = .init(&.{});
        var http = std.http.Server.init(&reader, &writer.writer);
        var request = try http.receiveHead();
        var retained = std.heap.ArenaAllocator.init(a);
        defer retained.deinit();
        var scratch = std.testing.FailingAllocator.init(a, .{});
        const result = prepare(scratch.allocator(), retained.allocator(), &request, upstream, "fixture");
        if (case.err) |err| {
            try std.testing.expectError(err, result);
        } else {
            const pending = try result;
            try std.testing.expectEqualStrings("{\"model\":\"upstream-model\",\"stream\":true,\"input\":[0,1,2],\"store\":false}", pending.body);
            try std.testing.expectEqualStrings("session", pending.headers[0].value);
        }
        try std.testing.expect(scratch.allocations > 0);
        try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    }
}

test "transport applies the supplied provider contract without forwarding gateway auth or hop headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("POST /v1/responses HTTP/1.1\r\nAuthorization: Bearer secret\r\nCookie: secret\r\nProxy-Authorization: secret\r\nSession_id: session\r\nOpenAI-Beta: responses=v1\r\nConnection: openai-beta\r\n\r\n");
    var writer: std.Io.Writer.Discarding = .init(&.{});
    var http = std.http.Server.init(&reader, &writer.writer);
    var request = try http.receiveHead();
    const headers = try requestHeaders(arena.allocator(), &request, .responses);
    try std.testing.expectEqual(1, headers.len);
    try std.testing.expectEqualStrings("Session_id", headers[0].name);
    try std.testing.expectEqualStrings("session", headers[0].value);
}

test "transport SIWC fixture enforces provider body and headers while preserving native fields" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const native =
        \\,"input":[{"type":"function_call_output","call_id":"call_1","output":"ok"}],"tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}],"reasoning":{"effort":"high"},"previous_response_id":"resp_1","prompt_cache_key":"cache_1","instructions":"","metadata":{"precise":18446744073709551617}}
    ;
    const payload = "{\"model\":\"demo\",\"stream\":true" ++ native;
    const sse = "data: {\"type\":\"response.completed\"}\n\n";
    var fixture = try @import("fixture").Fixture.init(a, io, &.{.{
        .bytes = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" ++ sse,
    }});
    defer fixture.deinit();
    try fixture.start();
    const origin = try fixture.origin(a);
    defer a.free(origin);
    const url = try std.fmt.allocPrint(a, "{s}/v1/responses", .{origin});
    defer a.free(url);
    // Exercise the contract against loopback, without adding a production
    // endpoint override. Provider.init separately proves pinning is mandatory.
    var upstream: Upstream = .{ .url = url, .models = .{}, .auth = .{ .provider = .codex } };
    defer upstream.models.deinit(a);
    try upstream.models.map.put(a, "demo", "fixture-model");
    const raw = try std.fmt.allocPrint(a, "POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer gateway-secret\r\nCookie: private\r\nProxy-Authorization: private\r\nX-Api-Key: private\r\nAccept: application/json\r\nAccept: */*\r\nUser-Agent: private\r\nSession_id: session_1\r\nX-Request-Id: private\r\nConnection: x-request-id, accept\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    defer a.free(raw);
    var reader = std.Io.Reader.fixed(raw);
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    var http = std.http.Server.init(&reader, &writer.writer);
    var request = try http.receiveHead();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var pending = try prepare(a, arena.allocator(), &request, upstream, "fixture");
    pending.authorization = "Bearer fixture-access";
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var started = false;
    try std.testing.expectEqual(.ok, try relayResponse(&client, arena.allocator(), &pending, &started));
    try fixture.waitRequest();
    const captured = fixture.requests[0].?;
    try std.testing.expect(std.mem.startsWith(u8, captured, "POST /v1/responses HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.find(u8, captured, "gateway-secret") == null);
    try std.testing.expect(std.mem.find(u8, captured, "private") == null);
    const body_start = std.mem.find(u8, captured, "\r\n\r\n").? + 4;
    try std.testing.expectEqualStrings("{\"model\":\"fixture-model\",\"stream\":true" ++ native[0 .. native.len - 1] ++ ",\"store\":false}", captured[body_start..]);
    var captured_reader = std.Io.Reader.fixed(captured);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var upstream_http = std.http.Server.init(&captured_reader, &discard.writer);
    const received = try upstream_http.receiveHead();
    const expected = [_]std.http.Header{
        .{ .name = "authorization", .value = "Bearer fixture-access" },
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "user-agent", .value = "fumo-gateway" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept-encoding", .value = "identity" },
        .{ .name = "session_id", .value = "session_1" },
    };
    for (expected) |header| {
        var count: usize = 0;
        var headers = received.iterateHeaders();
        while (headers.next()) |actual| {
            if (!std.ascii.eqlIgnoreCase(actual.name, header.name)) continue;
            count += 1;
            try std.testing.expectEqualStrings(header.value, actual.value);
        }
        try std.testing.expectEqual(1, count);
    }
    try std.testing.expect(std.ascii.findIgnoreCase(writer.written(), "content-type: text/event-stream") != null);
    try std.testing.expect(std.mem.find(u8, writer.written(), sse) != null);
    try std.testing.expectEqual(1, fixture.count.load(.acquire));
}
