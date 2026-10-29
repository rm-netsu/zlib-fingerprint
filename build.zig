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
    addLegacySources(b, exe.root_module);
    addZopfliRuntime(exe.root_module);
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

    const zlegacy = b.addExecutable(.{
        .name = "zlegacy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zlegacy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addLegacySources(b, zlegacy.root_module);
    zlegacy.root_module.addImport("legacy", b.createModule(.{
        .root_source_file = b.path("src/legacy/legacy.zig"),
        .target = target,
        .optimize = optimize,
    }));
    b.installArtifact(zlegacy);

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
    addLegacySources(b, unit_tests.root_module);
    addZopfliRuntime(unit_tests.root_module);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

/// Zopfli's complete pipeline — LZ77 optimization, block splitting,
/// package-merge code lengths and DEFLATE serialization — is native Zig.
/// Only libc (malloc/free/log) and libm are linked as runtime support;
/// no upstream algorithmic C source is compiled into the build.
fn addZopfliRuntime(module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("m", .{});
}

/// Compile four distinct historical zlib generations directly into the Zig
/// executable. Exported and cross-TU names are prefixed per generation, so
/// the original 1996–2004 deflate implementations never collide at link time.
fn addLegacySources(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    const symbols = [_][]const u8{
        "adler32", "deflate", "deflateInit_", "deflateInit2_", "deflateEnd",
        "deflateReset", "deflateParams", "deflateSetDictionary", "deflateCopy",
        "deflateBound", "deflatePrime", "_tr_init", "_tr_stored_block",
        "_tr_flush_block", "_tr_align", "_tr_tally", "zlibVersion",
        "zlibCompileFlags", "zError", "zcalloc", "zcfree", "z_errmsg",
        "deflate_copyright", "_dist_code", "_length_code",
        "compress", "compress2", "compressBound", "crc32", "get_crc_table", "crc32_combine",
    };
    for ([_][]const u8{ "a", "b", "c", "d" }) |class| {
        var flags: [symbols.len + 3][]const u8 = undefined;
        flags[0] = b.fmt("-Isrc/legacy/vendor/{s}", .{class});
        flags[1] = b.fmt("-DZF_ENTRY=zf_legacy_{s}", .{class});
        flags[2] = "-O2";
        for (symbols, 0..) |symbol, i| {
            flags[i + 3] = b.fmt("-D{s}=zf_{s}_{s}", .{ symbol, class, symbol });
        }
        module.addCSourceFiles(.{
            .files = &.{
                b.fmt("src/legacy/vendor/{s}/adler32.c", .{class}),
                b.fmt("src/legacy/vendor/{s}/compress.c", .{class}),
                b.fmt("src/legacy/vendor/{s}/crc32.c", .{class}),
                b.fmt("src/legacy/vendor/{s}/deflate.c", .{class}),
                b.fmt("src/legacy/vendor/{s}/trees.c", .{class}),
                b.fmt("src/legacy/vendor/{s}/zutil.c", .{class}),
                "src/legacy/bridge.c",
            },
            .flags = &flags,
        });
    }
}
