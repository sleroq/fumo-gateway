const std = @import("std");
const Config = @import("config.zig").Config;
const server = @import("server.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        if (err == error.InvalidArguments) std.log.err("{s}", .{cli.usage});
        std.log.err("event=command_failed error={s}", .{@errorName(err)});
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
    }
}

test {
    std.testing.refAllDecls(@This());
}
