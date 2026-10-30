const std = @import("std");

pub const usage =
    \\usage:
    \\  fumo-gateway --config <path>
;

pub const Command = union(enum) {
    serve: []const u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 2 and std.mem.eql(u8, args[0], "--config")) return .{ .serve = args[1] };
    return error.InvalidArguments;
}

test "serve is the only command; provider authentication is web-only" {
    const serve = try parse(&.{ "--config", "gateway.json" });
    try std.testing.expectEqualStrings("gateway.json", serve.serve);
    for ([_][]const []const u8{
        &.{},
        &.{"--config"},
        &.{ "auth", "login" },
        &.{ "auth", "login", "codex" },
        &.{ "auth", "refresh", "codex" },
        &.{ "auth", "login", "codex", "--credentials-dir", "/private/state" },
        &.{ "auth", "refresh", "codex", "--credentials-dir", "/private/state" },
        &.{ "auth", "login", "unknown" },
        &.{ "auth", "refresh", "unknown" },
        &.{ "auth", "unknown", "codex" },
        &.{ "auth", "refresh", "codex", "--credentials-dir" },
        &.{ "auth", "refresh", "codex", "--credentials-dir", "" },
        &.{ "auth", "login", "codex", "--credentials-dir" },
        &.{ "auth", "login", "codex", "--credentials-dir", "" },
        &.{ "auth", "login", "codex", "--auth-origin", "http://localhost" },
        &.{ "--config", "gateway.json", "extra" },
    }) |args| {
        try std.testing.expectError(error.InvalidArguments, parse(args));
    }
}
