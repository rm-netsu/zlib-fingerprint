const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zlib-fingerprint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Development tool: compress stdin exactly like the historical
    // zlib-<version> wrapper binaries (differential verification harness
    // for the integrated deflate engine).
    const zcompress = b.addExecutable(.{
        .name = "zcompress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zcompress.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zcompress.root_module.addImport("deflate", b.createModule(.{
        .root_source_file = b.path("src/deflate/deflate.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(zcompress);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the fingerprint search");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
