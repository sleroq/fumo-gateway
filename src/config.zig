const std = @import("std");
const auth = @import("auth.zig");
pub const Upstream = @import("provider.zig").Upstream;

const Document = struct {
    upstream: ?Upstream = null,
    listen: []const u8 = "127.0.0.1:8080",
    clients: std.json.ArrayHashMap(struct { key_env: []const u8 }),
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    address: std.Io.net.IpAddress,
    clients: []const auth.Client,
    upstream: ?Upstream,

    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, environ: *const std.process.Environ.Map) !Config {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
        defer gpa.free(text);
        return parse(gpa, text, environ);
    }

    fn parse(gpa: std.mem.Allocator, text: []const u8, environ: *const std.process.Environ.Map) !Config {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const document = try std.json.parseFromSliceLeaky(Document, allocator, text, .{ .allocate = .alloc_always });
        var upstream = document.upstream;
        if (upstream) |*value| {
            try value.configure(allocator, environ);
        }
        const address = std.Io.net.IpAddress.parseLiteral(document.listen) catch return error.InvalidListenAddress;
        if (address.getPort() == 0) return error.InvalidListenAddress;
        if (document.clients.map.count() == 0) return error.NoClients;

        const clients = try allocator.alloc(auth.Client, document.clients.map.count());
        for (document.clients.map.keys(), document.clients.map.values(), 0..) |label, client, i| {
            if (label.len == 0) return error.EmptyClientLabel;
            if (!std.process.Environ.Map.validateKeyForPut(client.key_env)) return error.InvalidKeyEnv;

            const key = environ.get(client.key_env) orelse return error.MissingClientKey;
            if (key.len == 0) return error.EmptyClientKey;
            for (key) |byte| {
                if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return error.InvalidClientKey;
            }

            clients[i] = auth.Client.init(label, key);
            for (clients[0..i]) |previous| {
                if (std.mem.eql(u8, &previous.key_hash, &clients[i].key_hash)) return error.DuplicateClientKey;
            }
        }

        return .{ .arena = arena, .address = address, .clients = clients, .upstream = upstream };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "configuration resolves environment keys and defaults to loopback" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PI_KEY", "first-secret");
    try environ.put("DEV_KEY", "second-secret");
    var config = try Config.parse(std.testing.allocator,
        \\{"clients":{"pi":{"key_env":"PI_KEY"},"dev":{"key_env":"DEV_KEY"}}}
    , &environ);
    defer config.deinit();
    try std.testing.expectEqualStrings("pi", auth.authenticate(config.clients, "Bearer first-secret").?);
    try std.testing.expectEqualStrings("dev", auth.authenticate(config.clients, "Bearer second-secret").?);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, config.address.ip4.bytes);
    try std.testing.expectEqual(8080, config.address.getPort());
    try std.testing.expect(config.upstream == null);
}

test "invalid configuration fails before serving" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    const text =
        \\{"clients":{"pi":{"key_env":"PI_KEY"}}}
    ;
    try std.testing.expectError(error.MissingClientKey, Config.parse(std.testing.allocator, text, &environ));
    try environ.put("PI_KEY", "");
    try std.testing.expectError(error.EmptyClientKey, Config.parse(std.testing.allocator, text, &environ));
    try environ.put("PI_KEY", "bad\r\nkey");
    try std.testing.expectError(error.InvalidClientKey, Config.parse(std.testing.allocator, text, &environ));
    try environ.put("PI_KEY", "secret");
    try std.testing.expectError(error.NoClients, Config.parse(std.testing.allocator, "{\"clients\":{}}", &environ));
    try std.testing.expectError(error.DuplicateClientKey, Config.parse(std.testing.allocator,
        \\{"clients":{"pi":{"key_env":"PI_KEY"},"dev":{"key_env":"PI_KEY"}}}
    , &environ));
    try std.testing.expectError(error.InvalidListenAddress, Config.parse(std.testing.allocator,
        \\{"listen":"invalid:8080","clients":{"pi":{"key_env":"PI_KEY"}}}
    , &environ));
    try std.testing.expectError(error.UnknownField, Config.parse(std.testing.allocator,
        \\{"unknown":true,"clients":{"pi":{"key_env":"PI_KEY"}}}
    , &environ));
}

test "upstream preserves endpoint and model aliases in its arena" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PI_KEY", "secret");
    const text = try std.testing.allocator.dupe(u8,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstream":{"url":"http://127.0.0.1:9090/v1/responses","models":{"demo":"fixture-model","other":"second-model"}}}
    );
    var config = try Config.parse(std.testing.allocator, text, &environ);
    defer config.deinit();
    std.testing.allocator.free(text);
    const upstream = config.upstream.?;
    try std.testing.expectEqualStrings("http://127.0.0.1:9090/v1/responses", upstream.url);
    try std.testing.expectEqualStrings("fixture-model", upstream.models.map.get("demo").?);
    try std.testing.expectEqualStrings("second-model", upstream.models.map.get("other").?);
}

test "SIWC configuration resolves private storage and pins the credential destination" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PI_KEY", "secret");
    try environ.put("HOME", "/home/test");
    var config = try Config.parse(std.testing.allocator,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstream":{"url":"https://api.openai.com/v1/responses","models":{"demo":"model"},"auth":{"provider":"codex"}}}
    , &environ);
    defer config.deinit();
    try std.testing.expectEqualStrings("/home/test/.local/state/fumo-gateway", config.upstream.?.auth.?.credentials_dir.?);
    const explicit =
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstream":{"url":"https://api.openai.com/v1/responses","models":{"demo":"model"},"auth":{"provider":"codex","credentials_dir":"/private/credentials"}}}
    ;
    var configured = try Config.parse(std.testing.allocator, explicit, &environ);
    defer configured.deinit();
    try std.testing.expectEqualStrings("/private/credentials", configured.upstream.?.auth.?.credentials_dir.?);
    for ([_][]const u8{ "http://api.openai.com/v1/responses", "https://example.com/v1/responses", "https://api.openai.com/other", "https://api.openai.com:443/v1/responses" }) |url| {
        const text = try std.testing.allocator.print(
            \\{{"clients":{{"pi":{{"key_env":"PI_KEY"}}}},"upstream":{{"url":"{s}","models":{{"demo":"model"}},"auth":{{"provider":"codex"}}}}}}
        , .{url});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidCodexEndpoint, Config.parse(std.testing.allocator, text, &environ));
    }
    try std.testing.expectError(error.InvalidDirectory, Config.parse(std.testing.allocator,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstream":{"url":"https://api.openai.com/v1/responses","models":{"demo":"model"},"auth":{"provider":"codex","credentials_dir":""}}}
    , &environ));
}

test "invalid upstream configuration is rejected" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("PI_KEY", "secret");
    const invalid_urls = [_][]const u8{
        "",                                              "/v1/responses",                         "ftp://example.com/v1/responses",
        "http:///v1/responses",                          "http://:9090/v1/responses",             "http://user@example.com/v1/responses",
        "http://user:password@example.com/v1/responses", "http://example.com/v1/responses?",      "http://example.com/v1/responses#",
        "http://example.com:0/v1/responses",             "http://example.com:65536/v1/responses", "http://example.com:bad/v1/responses",
        "http://example.com:/v1/responses",
    };
    for (invalid_urls) |url| {
        const text = try std.testing.allocator.print(
            \\{{"clients":{{"pi":{{"key_env":"PI_KEY"}}}},"upstream":{{"url":"{s}","models":{{"demo":"model"}}}}}}
        , .{url});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.InvalidUpstreamUrl, Config.parse(std.testing.allocator, text, &environ));
    }
    const cases = .{
        .{ "{}", error.NoUpstreamModels },
        .{ "{\"\":\"model\"}", error.EmptyModelAlias },
        .{ "{\"demo\":\"\"}", error.EmptyUpstreamModel },
    };
    inline for (cases) |case| {
        const text = try std.testing.allocator.print(
            \\{{"clients":{{"pi":{{"key_env":"PI_KEY"}}}},"upstream":{{"url":"https://example.com/v1/responses","models":{s}}}}}
        , .{case[0]});
        defer std.testing.allocator.free(text);
        try std.testing.expectError(case[1], Config.parse(std.testing.allocator, text, &environ));
    }
}
