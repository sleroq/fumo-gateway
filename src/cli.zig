const std = @import("std");

pub const usage =
    \\usage:
    \\  fumo-gateway --config <path>
    \\  fumo-gateway auth login codex [--credentials-dir <directory>]
;

pub const Command = union(enum) {
    serve: []const u8,
    login_codex: ?[]const u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 2 and std.mem.eql(u8, args[0], "--config")) return .{ .serve = args[1] };
    if ((args.len == 3 or args.len == 5) and
        std.mem.eql(u8, args[0], "auth") and
        std.mem.eql(u8, args[1], "login") and
        std.mem.eql(u8, args[2], "codex"))
    {
        if (args.len == 3) return .{ .login_codex = null };
        if (std.mem.eql(u8, args[3], "--credentials-dir") and args[4].len != 0) return .{ .login_codex = args[4] };
    }
    return error.InvalidArguments;
}

test "serve and standalone Codex login commands" {
    const serve = try parse(&.{ "--config", "gateway.json" });
    try std.testing.expectEqualStrings("gateway.json", serve.serve);
    try std.testing.expect((try parse(&.{ "auth", "login", "codex" })).login_codex == null);
    try std.testing.expectEqualStrings("/private/state", (try parse(&.{ "auth", "login", "codex", "--credentials-dir", "/private/state" })).login_codex.?);
    for ([_][]const []const u8{
        &.{},
        &.{"--config"},
        &.{ "auth", "login" },
        &.{ "auth", "login", "unknown" },
        &.{ "auth", "login", "codex", "--credentials-dir" },
        &.{ "auth", "login", "codex", "--credentials-dir", "" },
        &.{ "auth", "login", "codex", "--auth-origin", "http://localhost" },
        &.{ "--config", "gateway.json", "extra" },
    }) |args| {
        try std.testing.expectError(error.InvalidArguments, parse(args));
    }
}
