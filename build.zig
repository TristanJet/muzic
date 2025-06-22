const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{});

    const exe = b.addExecutable(.{
        .name = if (optimize == .ReleaseFast) "muzic" else "out",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    exe.root_module.addImport("code_point", zg.module("code_point"));
    exe.root_module.addImport("ascii", zg.module("ascii"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Build and run tests using imported modules");
    const dw_test = b.addTest(.{ .root_source_file = b.path("src/render.zig") });
    dw_test.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    dw_test.root_module.addImport("code_point", zg.module("code_point"));
    dw_test.root_module.addImport("ascii", zg.module("ascii"));
    const run_unit_tests = b.addRunArtifact(dw_test);
    test_step.dependOn(&run_unit_tests.step);
}
