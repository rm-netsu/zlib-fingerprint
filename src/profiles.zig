//! Compressor implementation profiles.
//!
//! The order of `profiles` encodes the implementation *prior*: which
//! implementation is most likely to have produced an arbitrary stream found
//! in the wild. The integrated engine comes first — it reproduces the
//! bit-exact output of every historical stock zlib release 1.2.3 .. 1.3.1
//! in-process (see `deflate/`), which covers the overwhelming majority of
//! real-world streams without spawning a single binary. Modern stock zlib
//! binaries follow, then alternative implementations. The search engine
//! always walks profiles in this order inside every stage; the metadata
//! hints (FLEVEL / CINFO) reorder *candidates within* a profile, not
//! profiles themselves.
//!
//! In the default mode the per-version zlib binaries covered bit-exactly by
//! the integrated engine (`covered_by_integrated = true`) are redundant and
//! are skipped; `--external-zlib` restores the original all-external search
//! and skips the integrated profile instead. zlib 1.3.2 postdates the
//! integrated engine's verified range and zlib-ng's output diverges from
//! stock zlib, so both always stay external.

const std = @import("std");

pub const ImplType = enum {
    /// Built-in `deflate/` engine: full zlib API semantics, covers all
    /// historical stock zlib releases 1.2.3 .. 1.3.1 in-process.
    integrated,
    /// Anything speaking the full zlib API: `level memLevel strategy windowBits`.
    zlib_family,
    /// Zopfli CLI: `--zlib -c --iN <file>`.
    zopfli,
    /// libdeflate wrapper: `level` (1..12).
    libdeflate,
    /// miniz wrapper: `level` (1..10).
    miniz,
    /// AdvanceCOMP advdef: recompresses a zlib stream file in place (`-L -z -k`).
    advdef,
};

pub const Profile = struct {
    name: []const u8,
    /// File name of the executable inside the binaries directory. Unused for
    /// the integrated profile.
    binary: []const u8,
    impl_type: ImplType,
    /// Lower value = tried earlier inside a stage.
    prior: u8,
    /// True when the integrated engine already reproduces this profile's
    /// compressed output bit-exactly for every parameter combination the
    /// search visits — such profiles are skipped in the default mode.
    covered_by_integrated: bool = false,
};

/// Profile table, pre-sorted by prior.
pub const profiles = [_]Profile{
    .{ .name = "zlib (integrated)", .binary = "(integrated)",       .impl_type = .integrated,  .prior = 0 },
    .{ .name = "zlib 1.3.2",        .binary = "zlib-1.3.2",         .impl_type = .zlib_family, .prior = 1 },
    .{ .name = "zlib 1.3.1",        .binary = "zlib-1.3.1",         .impl_type = .zlib_family, .prior = 2,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.11",       .binary = "zlib-1.2.11",        .impl_type = .zlib_family, .prior = 3,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.8",        .binary = "zlib-1.2.8",         .impl_type = .zlib_family, .prior = 4,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.7",        .binary = "zlib-1.2.7",         .impl_type = .zlib_family, .prior = 5,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.12",       .binary = "zlib-1.2.12",        .impl_type = .zlib_family, .prior = 6,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.13",       .binary = "zlib-1.2.13",        .impl_type = .zlib_family, .prior = 7,  .covered_by_integrated = true },
    .{ .name = "zlib 1.3",          .binary = "zlib-1.3",           .impl_type = .zlib_family, .prior = 8,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.5",        .binary = "zlib-1.2.5",         .impl_type = .zlib_family, .prior = 9,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.3",        .binary = "zlib-1.2.3",         .impl_type = .zlib_family, .prior = 10, .covered_by_integrated = true },
    .{ .name = "zlib-ng 2.2.1",     .binary = "zlib-ng-2.2.1",      .impl_type = .zlib_family, .prior = 11 },
    .{ .name = "libdeflate 1.20",   .binary = "libdeflate-1.20",    .impl_type = .libdeflate,  .prior = 12 },
    .{ .name = "miniz 3.1.2",       .binary = "miniz-3.1.2",        .impl_type = .miniz,       .prior = 13 },
    .{ .name = "zopfli 1.0.3",      .binary = "zopfli-1.0.3",       .impl_type = .zopfli,      .prior = 14 },
    .{ .name = "advdef 2.6",        .binary = "advdef-2.6",         .impl_type = .advdef,      .prior = 15 },
};

/// Strategy names per zlib's Z_* constants (used for reporting).
pub const STRATEGY_NAMES = [5][]const u8{
    "default", "filtered", "huffman-only", "rle", "fixed",
};

test "profiles are sorted by prior" {
    for (profiles, 0..) |p, i| {
        if (i > 0) {
            try std.testing.expect(profiles[i - 1].prior <= p.prior);
        }
    }
    // The integrated engine must be tried first.
    try std.testing.expectEqual(ImplType.integrated, profiles[0].impl_type);
    try std.testing.expectEqualStrings("zlib 1.3.2", profiles[1].name);
}

test "integrated coverage flags match the engine's verified range" {
    for (profiles) |p| {
        switch (p.impl_type) {
            .integrated => try std.testing.expect(!p.covered_by_integrated),
            .zlib_family => {
                // Every stock zlib release within 1.2.3..1.3.1 is covered;
                // 1.3.2 (newer than the verified range) and zlib-ng are not.
                const covered_versions = [_][]const u8{
                    "zlib 1.2.3", "zlib 1.2.5", "zlib 1.2.7", "zlib 1.2.8",
                    "zlib 1.2.11", "zlib 1.2.12", "zlib 1.2.13", "zlib 1.3", "zlib 1.3.1",
                };
                var should_cover = false;
                for (covered_versions) |v| {
                    if (std.mem.eql(u8, p.name, v)) should_cover = true;
                }
                try std.testing.expectEqual(should_cover, p.covered_by_integrated);
            },
            else => try std.testing.expect(!p.covered_by_integrated),
        }
    }
}
