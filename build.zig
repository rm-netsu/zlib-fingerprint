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

    const exe = b.addExecutable(.{
        .name = "zlib-fingerprint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zlib-replicant", replicant_mod);
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
    // with the standalone upstream 1.0.3 CLI.
    const zzopfli = b.addExecutable(.{
        .name = "zzopfli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zzopfli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // zopfli/container.zig reuses the engine's shared adler32.
    zzopfli.root_module.addImport("zlib-replicant", replicant_mod);
    addZopfliRuntime(zzopfli.root_module);
    b.installArtifact(zzopfli);

    // Differential harness: feed binary frequency vectors on stdin, print
    // the length-limited Huffman code lengths produced by the native
    // katajainen.zig port (scripts/diff_katajainen.py compares against
    // the upstream C kernel).
    const zkatajainen = b.addExecutable(.{
        .name = "zkatajainen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zkatajainen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zkatajainen.root_module.addImport("katajainen", b.createModule(.{
        .root_source_file = b.path("src/zopfli/katajainen.zig"),
        .target = target,
        .optimize = optimize,
    }));
    zkatajainen.root_module.link_libc = true;
    b.installArtifact(zkatajainen);

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
}

/// Zopfli's complete pipeline — LZ77 optimization, block splitting,
/// package-merge code lengths and DEFLATE serialization — is native Zig.
/// Only libc (malloc/free/log) and libm are linked as runtime support;
/// no upstream algorithmic C source is compiled into the build.
fn addZopfliRuntime(module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("m", .{});
}
