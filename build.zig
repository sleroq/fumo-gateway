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

    const fixture = b.createModule(.{
        .root_source_file = b.path("tests/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("fixture", fixture);
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = core }));
    const test_step = b.step("test", "Run all native Zig tests against local fixtures");
    test_step.dependOn(&run_tests.step);
    const transport_tests = b.addRunArtifact(b.addTest(.{ .root_module = core, .filters = &.{"transport "} }));
    b.step("test-transport", "Test HTTP relay and streaming against local fixtures").dependOn(&transport_tests.step);

    const codex = b.createModule(.{
        .root_source_file = b.path("src/codex.zig"),
        .target = target,
        .optimize = optimize,
    });
    codex.addImport("fixture", fixture);
    const auth_tests = b.addRunArtifact(b.addTest(.{ .root_module = codex }));
    b.step("test-auth", "Test SIWC auth against local fixtures").dependOn(&auth_tests.step);

    const provider = b.createModule(.{
        .root_source_file = b.path("src/provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    provider.addImport("fixture", fixture);
    const service = b.createModule(.{
        .root_source_file = b.path("tests/service.zig"),
        .target = target,
        .optimize = optimize,
    });
    service.addImport("provider", provider);
    service.addImport("fixture", fixture);
    const service_tests = b.addRunArtifact(b.addTest(.{ .root_module = service, .filters = &.{"session "} }));
    b.step("test-service", "Test nonblocking SIWC refresh against local fixtures").dependOn(&service_tests.step);
    test_step.dependOn(&service_tests.step);
}
