const std = @import("std");
const Config = @import("config.zig").Config;
const server = @import("server.zig");
const cli = @import("cli.zig");
const codex = @import("codex.zig");
const credentials = @import("codex/credentials.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        if (err == error.InvalidArguments) std.log.err("{s}", .{cli.usage});
        std.log.err("event=command_failed error={s}", .{@errorName(err)});
        if (err == error.ReauthenticationRequired) std.log.err("Run fumo-gateway auth login codex with the same credentials directory to authenticate again.", .{});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try cli.parse(args[1..])) {
        .serve => |path| {
            var config = try Config.load(init.gpa, init.io, path, init.environ_map);
            defer config.deinit();
            try server.serve(init.gpa, init.io, &config);
        },
        .login_codex => |directory| {
            const path = directory orelse try credentials.defaultDirectory(init.arena.allocator(), init.environ_map);
            try codex.login(init.gpa, init.io, path);
        },
        .refresh_codex => |directory| {
            const path = directory orelse try credentials.defaultDirectory(init.arena.allocator(), init.environ_map);
            try codex.refresh(init.gpa, init.io, path);
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
