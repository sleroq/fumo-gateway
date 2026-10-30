const std = @import("std");
const auth = @import("auth.zig");
pub const Upstream = @import("provider.zig").Upstream;

const Document = struct {
    upstreams: std.json.ArrayHashMap(Upstream.Options) = .{},
    listen: []const u8 = "127.0.0.1:8080",
    clients: std.json.ArrayHashMap(struct { key_env: []const u8 }),
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    address: std.Io.net.IpAddress,
    clients: []const auth.Client,
    upstreams: []const Upstream,

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
        const upstreams = try allocator.alloc(Upstream, document.upstreams.map.count());
        for (upstreams, document.upstreams.map.keys(), document.upstreams.map.values()) |*upstream, name, options| {
            upstream.* = try Upstream.configure(name, options, allocator, environ);
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

        return .{ .arena = arena, .address = address, .clients = clients, .upstreams = upstreams };
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
    try std.testing.expectEqual(0, config.upstreams.len);
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

test "named upstreams own definitions, aliases, and resolved API keys in the config arena" {
    const a = std.testing.allocator;
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("PI_KEY", "secret");
    try environ.put("ZEN_KEY", "provider-secret");
    const text = try a.dupe(u8,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstreams":{"codex":{"base_url":"http://127.0.0.1:9090/v1/","aliases":{"fast":"native-model"}},"zen":{"base_url":"https://example.com/v1","auth":{"provider":"api_key","key_env":"ZEN_KEY"}}}}
    );
    var config = try Config.parse(a, text, &environ);
    defer config.deinit();
    a.free(text);
    try environ.put("ZEN_KEY", "changed");
    try std.testing.expectEqual(2, config.upstreams.len);
    try std.testing.expectEqualStrings("codex", config.upstreams[0].name);
    try std.testing.expectEqualStrings("http://127.0.0.1:9090/v1", config.upstreams[0].base_url);
    try std.testing.expectEqualStrings("native-model", config.upstreams[0].aliases.map.get("fast").?);
    try std.testing.expectEqualStrings("provider-secret", config.upstreams[1].auth.api_key);
}

test "SIWC configuration resolves private storage and pins inference and discovery destination" {
    const a = std.testing.allocator;
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("PI_KEY", "secret");
    try environ.put("HOME", "/home/test");
    var config = try Config.parse(a,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstreams":{"codex":{"base_url":"https://api.openai.com/v1","auth":{"provider":"codex"}}}}
    , &environ);
    defer config.deinit();
    try std.testing.expectEqualStrings("/home/test/.local/state/fumo-gateway", config.upstreams[0].auth.codex);
    var explicit = try Config.parse(a,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstreams":{"codex":{"base_url":"https://api.openai.com/v1","auth":{"provider":"codex","credentials_dir":"/private/credentials"}}}}
    , &environ);
    defer explicit.deinit();
    try std.testing.expectEqualStrings("/private/credentials", explicit.upstreams[0].auth.codex);
    for ([_][]const u8{ "http://api.openai.com/v1", "https://example.com/v1", "https://api.openai.com/other", "https://api.openai.com:443/v1" }) |url| {
        const text = try a.print(
            \\{{"clients":{{"pi":{{"key_env":"PI_KEY"}}}},"upstreams":{{"codex":{{"base_url":"{s}","auth":{{"provider":"codex"}}}}}}}}
        , .{url});
        defer a.free(text);
        try std.testing.expectError(error.InvalidCodexEndpoint, Config.parse(a, text, &environ));
    }
    try std.testing.expectError(error.InvalidDirectory, Config.parse(a,
        \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstreams":{"codex":{"base_url":"https://api.openai.com/v1","auth":{"provider":"codex","credentials_dir":""}}}}
    , &environ));
}

test "invalid upstream definitions and credentials fail before serving" {
    const a = std.testing.allocator;
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("PI_KEY", "secret");
    const invalid_urls = [_][]const u8{
        "",                            "/v1",                                 "ftp://example.com/v1",   "http:///v1",             "http://:9090/v1",
        "http://user@example.com/v1",  "http://user:password@example.com/v1", "http://example.com/v1?", "http://example.com/v1#", "http://example.com:0/v1",
        "http://example.com:65536/v1", "http://example.com:bad/v1",           "http://example.com:/v1",
    };
    for (invalid_urls) |url| {
        const text = try a.print(
            \\{{"clients":{{"pi":{{"key_env":"PI_KEY"}}}},"upstreams":{{"demo":{{"base_url":"{s}"}}}}}}
        , .{url});
        defer a.free(text);
        try std.testing.expectError(error.InvalidUpstreamUrl, Config.parse(a, text, &environ));
    }
    const cases = .{
        .{ "", "{\"base_url\":\"http://localhost/v1\"}", error.InvalidUpstreamName },
        .{ "bad/name", "{\"base_url\":\"http://localhost/v1\"}", error.InvalidUpstreamName },
        .{ "demo", "{\"base_url\":\"http://localhost/v1\",\"protocol\":\"chat_completions\"}", error.UnknownField },
        .{ "demo", "{\"base_url\":\"http://localhost/v1\",\"aliases\":{\"\":\"model\"}}", error.EmptyModelAlias },
        .{ "demo", "{\"base_url\":\"http://localhost/v1\",\"aliases\":{\"fast\":\"\"}}", error.EmptyUpstreamModel },
        .{ "demo", "{\"base_url\":\"http://localhost/v1\",\"auth\":{\"provider\":\"api_key\"}}", error.InvalidUpstreamAuth },
        .{ "demo", "{\"base_url\":\"http://localhost/v1\",\"auth\":{\"provider\":\"api_key\",\"key_env\":\"MISSING\"}}", error.MissingUpstreamKey },
    };
    inline for (cases) |case| {
        const text = try a.print(
            \\{{"clients":{{"pi":{{"key_env":"PI_KEY"}}}},"upstreams":{{"{s}":{s}}}}}
        , .{ case[0], case[1] });
        defer a.free(text);
        try std.testing.expectError(case[2], Config.parse(a, text, &environ));
    }
    for ([_][]const u8{ "", "bad\r\nkey" }) |key| {
        try environ.put("API_KEY", key);
        const text =
            \\{"clients":{"pi":{"key_env":"PI_KEY"}},"upstreams":{"demo":{"base_url":"http://localhost/v1","auth":{"provider":"api_key","key_env":"API_KEY"}}}}
        ;
        if (key.len == 0) {
            try std.testing.expectError(error.EmptyUpstreamKey, Config.parse(a, text, &environ));
        } else {
            try std.testing.expectError(error.InvalidUpstreamKey, Config.parse(a, text, &environ));
        }
    }
}
