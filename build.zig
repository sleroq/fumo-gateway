const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "fumo-gateway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run fumo-gateway").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run tests").dependOn(&run_tests.step);

    const auth_driver = b.addExecutable(.{
        .name = "auth-test-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/auth_driver.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    auth_driver.root_module.addImport("codex", b.createModule(.{
        .root_source_file = b.path("src/codex.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const auth_tests = b.addSystemCommand(&.{ "python3", "tests/auth_integration.py" });
    auth_tests.setCwd(b.path("."));
    auth_tests.addArtifactArg(auth_driver);
    b.step("test-auth", "Test Codex device login against a local HTTP fixture").dependOn(&auth_tests.step);
}
