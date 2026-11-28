const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The integrated zlib deflate engine (all historical classes A-H) lives
    // in the separate zlib-replicant package and is imported as the module
    // name "zlib-replicant". The package also builds the differential-
    // testing tools (zcompress, plus zlegacy with the original C-core
    // oracles for classes A-D); this root build installs them into the
    // repository's zig-out/bin so the regression corpus and the
    // differential suites keep a single tool location.
    const zlib_replicant = b.dependency("zlib_replicant", .{
        .target = target,
        .optimize = optimize,
    });
    const replicant_mod = zlib_replicant.module("zlib-replicant");
    b.installArtifact(zlib_replicant.artifact("zcompress"));
    b.installArtifact(zlib_replicant.artifact("zlegacy"));

    // The native Zopfli engine (every historical release 1.0.0-1.0.3) lives
    // in the separate zopfli-replicant package and is imported as the
    // module name "zopfli-replicant". The package also builds the
    // differential-testing tools (zzopfli, the CLI-equivalent harness, and
    // zkatajainen for the package-merge kernel); this root build installs
    // them here as well, keeping a single tool location for the search and
    // the differential suites.
    const zopfli_replicant = b.dependency("zopfli_replicant", .{
        .target = target,
        .optimize = optimize,
    });
    const zopfli_mod = zopfli_replicant.module("zopfli-replicant");
    b.installArtifact(zopfli_replicant.artifact("zzopfli"));
    b.installArtifact(zopfli_replicant.artifact("zkatajainen"));

    const exe = b.addExecutable(.{
        .name = "zlib-fingerprint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zlib-replicant", replicant_mod);
    exe.root_module.addImport("zopfli-replicant", zopfli_mod);
    addZopfliRuntime(exe.root_module);
    b.installArtifact(exe);

    // Development tool: compress stdin exactly like the miniz-3.1.2
    // wrapper binary (differential harness for the native tdefl port).
    const zminiz = b.addExecutable(.{
        .name = "zminiz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zminiz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zminiz.root_module.addImport("miniz", b.createModule(.{
        .root_source_file = b.path("src/miniz/tdefl.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(zminiz);

    // Development tool: compress stdin exactly like the zlib-ng-2.2.1
    // wrapper binary (differential harness for the native zlib-ng port).
    const zzlibng = b.addExecutable(.{
        .name = "zzlibng",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zzlibng.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zzlibng.root_module.addImport("zlibng", b.createModule(.{
        .root_source_file = b.path("src/zlibng/deflate.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(zzlibng);

    // Compare the in-process Zig container / transitional Zopfli backend
    // with the standalone upstream 1.0.3 CLI: the zzopfli tool moved into
    // the zopfli-replicant package together with the engine and is
    // installed above.

    // Differential harness: feed binary frequency vectors on stdin, print
    // the length-limited Huffman code lengths produced by the native
    // katajainen.zig port (zopfli-replicant/scripts/diff_katajainen.py
    // compares against the upstream C kernel): the zkatajainen tool moved
    // into the zopfli-replicant package and is installed above.

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
    unit_tests.root_module.addImport("zlib-replicant", replicant_mod);
    unit_tests.root_module.addImport("zopfli-replicant", zopfli_mod);
    addZopfliRuntime(unit_tests.root_module);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    // The engine's own golden-vector tests (classes A-H) live inside the
    // zlib-replicant package now; run them from the root `zig build test`
    // as well, so a single invocation still covers everything it did before
    // the extraction. The package keeps its own standalone
    // `cd zlib-replicant && zig build test`.
    if (zlib_replicant.builder.top_level_steps.get("test")) |dep_tests| {
        test_step.dependOn(&dep_tests.step);
    }
    // The same holds for the zopfli engine's unit tests inside the
    // zopfli-replicant package (`cd zopfli-replicant && zig build test`
    // standalone).
    if (zopfli_replicant.builder.top_level_steps.get("test")) |dep_tests| {
        test_step.dependOn(&dep_tests.step);
    }
}

/// The zopfli engine (in the zopfli-replicant package) links only libc
/// (malloc/free/log) and libm as runtime support; no upstream
/// algorithmic C source is compiled into the build. The flag propagates
/// from the consuming root modules to the final link of each
/// executable.
fn addZopfliRuntime(module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("m", .{});
}
