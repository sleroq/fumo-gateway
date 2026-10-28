const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try stdout.interface.writeAll("fumo-gateway\n");
    try stdout.interface.flush();
}
