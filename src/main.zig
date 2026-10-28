const std = @import("std");
const Config = @import("config.zig").Config;
const server = @import("server.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.log.err("event=startup_failed error={s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--config")) {
        std.log.err("usage: fumo-gateway --config <path>", .{});
        return error.InvalidArguments;
    }

    var config = try Config.load(init.gpa, init.io, args[2], init.environ_map);
    defer config.deinit();
    try server.serve(init.gpa, init.io, &config);
}

test {
    std.testing.refAllDecls(@This());
}
