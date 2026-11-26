//! Compressor implementation profiles.
//!
//! The order of `profiles` encodes the implementation *prior*: which
//! implementation is most likely to have produced an arbitrary stream found
//! in the wild. The integrated engine comes first — it reproduces the
//! bit-exact output of stock zlib 1.2.3 .. 1.3.2 for the tested one-shot model
//! in-process (see `deflate/`); native historical A-D cores are also linked
//! directly from their release sources. External audit binaries and
//! alternative implementations follow. The search engine
//! always walks profiles in this order inside every stage; the metadata
//! hints (FLEVEL / CINFO) reorder *candidates within* a profile, not
//! profiles themselves.
//!
//! In the default mode the per-version zlib binaries covered bit-exactly by
//! the integrated engine (`covered_by_integrated = true`) are redundant and
//! are skipped; `--external-zlib` restores the original all-external search
//! and skips the integrated profile instead. The 1.3.2 class was confirmed
//! empirically for one-shot compression; broader streaming verification is
//! deferred. zlib-ng is independently distinct and remains external.

const std = @import("std");
const zopfli_release = @import("zopfli/release.zig");

pub const ImplType = enum {
    /// Built-in modern Zig deflate, or statically linked historical A-D C
    /// cores distinguished by `legacy_class` (one-shot producer model).
    integrated,
    /// Anything speaking the full zlib API: `level memLevel strategy windowBits`.
    zlib_family,
    /// Historical zlib before 1.2.3: header conventions and supported
    /// strategies are not assumed identical to current zlib.
    legacy_zlib,
    /// Zopfli CLI: `--zlib -c --iN <file>`.
    zopfli,
    /// Zopfli in-process: fully native Zig optimizer (no C kernel linked).
    zopfli_native,
    /// miniz wrapper binary: `level` (1..10).
    miniz,
    /// miniz in-process: native Zig tdefl port (levels 1..10).
    miniz_native,
    /// libdeflate wrapper: `level` (1..12).
    libdeflate,
    /// zlib-ng 2.2.1 (compat) in-process: native Zig port (level/memLevel/
    /// strategy; windowBits fixed to 15 like the reference wrapper).
    zlibng_native,
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
    /// Built-in historical C engine variant, linked into the Zig executable.
    legacy_class: ?ZlibClass = null,
    /// Historical Zopfli release reproduced by the native engine
    /// (`.zopfli_native` profiles only).
    release: ?zopfli_release.ZopfliRelease = null,
    /// When set, this profile's output is byte-identical to the named
    /// profile's on the entire verified equivalence matrix, so the search
    /// skips it and the representative's match reports the full group.
    /// Justification for zopfli 1.0.2 -> 1.0.3: the only source difference
    /// is a malloc cast in deflate.c; the matrix confirms byte-identity.
    collapsed_into: ?[]const u8 = null,
};

/// Header bytes (CMF/FLG) the profile's Zopfli release emits.
pub fn zopfliHeaderOf(p: Profile) u16 {
    const r = p.release orelse .v1_0_3;
    const bytes = r.containerHeader();
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

/// Reported version range for a native Zopfli match (equivalence groups
/// confirmed by the byte-level matrix and the source analysis).
pub fn zopfliGroupRange(p: Profile) ?[]const u8 {
    const r = p.release orelse return null;
    return switch (r) {
        .v1_0_0 => "zopfli 1.0.0",
        .v1_0_1 => "zopfli 1.0.1",
        .v1_0_2, .v1_0_3 => "zopfli 1.0.2-1.0.3",
    };
}

/// Empirical stock-zlib classes for the tested one-shot Z_FINISH model.
/// The classes are not a proof of identity under arbitrary streaming calls.
pub const ZlibClass = enum { a, b, c, d, e, f, g, h };

pub fn zlibClass(p: Profile) ?ZlibClass {
    if (p.legacy_class) |group| return group;
    if (p.impl_type != .legacy_zlib and
        (p.impl_type != .zlib_family or !std.mem.startsWith(u8, p.name, "zlib ")))
        return null;
    const members = [_][]const []const u8{
        &.{ "zlib-1.0.1", "zlib-1.0.2", "zlib-1.0.4", "zlib-1.0.5" },
        &.{ "zlib-1.0.6", "zlib-1.0.7", "zlib-1.0.8", "zlib-1.0.9" },
        &.{ "zlib-1.1.0", "zlib-1.1.1", "zlib-1.1.2", "zlib-1.1.3", "zlib-1.1.4", "zlib-1.2.0" },
        &.{ "zlib-1.2.1", "zlib-1.2.2" },
        &.{ "zlib-1.2.3" },
        &.{ "zlib-1.2.4", "zlib-1.2.5", "zlib-1.2.6", "zlib-1.2.7", "zlib-1.2.8" },
        &.{ "zlib-1.2.9" },
        &.{ "zlib-1.2.10", "zlib-1.2.11", "zlib-1.2.12", "zlib-1.2.13", "zlib-1.3", "zlib-1.3.1", "zlib-1.3.2", "zlib-1.4" },
    };
    for (members, 0..) |versions, index| {
        for (versions) |version| {
            if (std.mem.eql(u8, p.binary, version)) return @enumFromInt(index);
        }
    }
    return null;
}

pub fn classRange(class: ZlibClass) []const u8 {
    return switch (class) {
        // 0.99 is byte-identical to class A across the 1,600-case common
        // parameter matrix (see EQUIVALENCE.md); 0.95 emits the same bytes
        // wherever its smaller API succeeds (no level 0, no deflateParams/
        // SetDictionary/Reset, stubbed deflateCopy).
        .a => "zlib 0.99-1.0.5",
        .b => "zlib 1.0.6-1.0.9",
        .c => "zlib 1.1.0-1.2.0",
        .d => "zlib 1.2.1-1.2.2",
        .e => "zlib 1.2.3",
        .f => "zlib 1.2.4-1.2.8",
        .g => "zlib 1.2.9",
        // zlib 1.4 (Nov 2026) is byte-identical to 1.3.2 across the full
        // one-shot matrix, the streaming matrix and Z_BLOCK/deflateParams
        // scenarios (see EQUIVALENCE.md).
        .h => "zlib 1.2.10-1.4",
    };
}

pub fn legacyClassIndex(p: Profile) ?usize {
    if (p.impl_type != .legacy_zlib) return null;
    return if (zlibClass(p)) |group| @intFromEnum(group) else null;
}

/// Profile table, pre-sorted by prior.
pub const profiles = [_]Profile{
    .{ .name = "zlib (integrated)", .binary = "(integrated)",       .impl_type = .integrated,  .prior = 0 },
    .{ .name = "zlib class D (integrated)", .binary = "(legacy-d)", .impl_type = .integrated, .prior = 0, .legacy_class = .d },
    .{ .name = "zlib class C (integrated)", .binary = "(legacy-c)", .impl_type = .integrated, .prior = 0, .legacy_class = .c },
    .{ .name = "zlib class B (integrated)", .binary = "(legacy-b)", .impl_type = .integrated, .prior = 0, .legacy_class = .b },
    .{ .name = "zlib class A (integrated)", .binary = "(legacy-a)", .impl_type = .integrated, .prior = 0, .legacy_class = .a },
    .{ .name = "zlib 1.4",          .binary = "zlib-1.4",           .impl_type = .zlib_family, .prior = 0, .covered_by_integrated = true },
    .{ .name = "zlib 1.3.2",        .binary = "zlib-1.3.2",         .impl_type = .zlib_family, .prior = 1, .covered_by_integrated = true },
    .{ .name = "zlib 1.3.1",        .binary = "zlib-1.3.1",         .impl_type = .zlib_family, .prior = 2,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.11",       .binary = "zlib-1.2.11",        .impl_type = .zlib_family, .prior = 3,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.8",        .binary = "zlib-1.2.8",         .impl_type = .zlib_family, .prior = 4,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.7",        .binary = "zlib-1.2.7",         .impl_type = .zlib_family, .prior = 5,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.12",       .binary = "zlib-1.2.12",        .impl_type = .zlib_family, .prior = 6,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.13",       .binary = "zlib-1.2.13",        .impl_type = .zlib_family, .prior = 7,  .covered_by_integrated = true },
    .{ .name = "zlib 1.3",          .binary = "zlib-1.3",           .impl_type = .zlib_family, .prior = 8,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.5",        .binary = "zlib-1.2.5",         .impl_type = .zlib_family, .prior = 9,  .covered_by_integrated = true },
    .{ .name = "zlib 1.2.3",        .binary = "zlib-1.2.3",         .impl_type = .zlib_family, .prior = 10, .covered_by_integrated = true },
    .{ .name = "zlib 1.2.2",        .binary = "zlib-1.2.2",         .impl_type = .legacy_zlib, .prior = 11 },
    .{ .name = "zlib 1.2.1",        .binary = "zlib-1.2.1",         .impl_type = .legacy_zlib, .prior = 12 },
    .{ .name = "zlib 1.2.0",        .binary = "zlib-1.2.0",         .impl_type = .legacy_zlib, .prior = 13 },
    .{ .name = "zlib 1.1.4",        .binary = "zlib-1.1.4",         .impl_type = .legacy_zlib, .prior = 14 },
    .{ .name = "zlib 1.1.3",        .binary = "zlib-1.1.3",         .impl_type = .legacy_zlib, .prior = 15 },
    .{ .name = "zlib 1.1.2",        .binary = "zlib-1.1.2",         .impl_type = .legacy_zlib, .prior = 16 },
    .{ .name = "zlib 1.1.1",        .binary = "zlib-1.1.1",         .impl_type = .legacy_zlib, .prior = 17 },
    .{ .name = "zlib 1.1.0",        .binary = "zlib-1.1.0",         .impl_type = .legacy_zlib, .prior = 18 },
    .{ .name = "zlib 1.0.9",        .binary = "zlib-1.0.9",         .impl_type = .legacy_zlib, .prior = 19 },
    .{ .name = "zlib 1.0.8",        .binary = "zlib-1.0.8",         .impl_type = .legacy_zlib, .prior = 20 },
    .{ .name = "zlib 1.0.7",        .binary = "zlib-1.0.7",         .impl_type = .legacy_zlib, .prior = 21 },
    .{ .name = "zlib 1.0.6",        .binary = "zlib-1.0.6",         .impl_type = .legacy_zlib, .prior = 22 },
    .{ .name = "zlib 1.0.5",        .binary = "zlib-1.0.5",         .impl_type = .legacy_zlib, .prior = 23 },
    .{ .name = "zlib 1.0.4",        .binary = "zlib-1.0.4",         .impl_type = .legacy_zlib, .prior = 24 },
    .{ .name = "zlib 1.0.2",        .binary = "zlib-1.0.2",         .impl_type = .legacy_zlib, .prior = 25 },
    .{ .name = "zlib 1.0.1",        .binary = "zlib-1.0.1",         .impl_type = .legacy_zlib, .prior = 26 },
    .{ .name = "zlib-ng 2.2.1",     .binary = "zlib-ng-2.2.1",      .impl_type = .zlib_family, .prior = 27, .covered_by_integrated = true },
    .{ .name = "zlib-ng 2.2.1 (in-process)", .binary = "(zlibng-native)", .impl_type = .zlibng_native, .prior = 27 },
    .{ .name = "libdeflate 1.20",   .binary = "libdeflate-1.20",    .impl_type = .libdeflate,  .prior = 28 },
    .{ .name = "miniz 3.1.2 (in-process)", .binary = "(miniz-native)", .impl_type = .miniz_native, .prior = 29 },
    .{ .name = "miniz 3.1.2",       .binary = "miniz-3.1.2",        .impl_type = .miniz,       .prior = 29 },
    .{ .name = "zopfli 1.0.3 (in-process)", .binary = "(zopfli-native)", .impl_type = .zopfli_native, .prior = 30, .release = .v1_0_3 },
    // 1.0.2 is byte-identical to 1.0.3 (only a malloc cast differs); the
    // search collapses it into the 1.0.3 representative and reports the
    // group range "zopfli 1.0.2-1.0.3".
    .{ .name = "zopfli 1.0.2 (in-process)", .binary = "(zopfli-native)", .impl_type = .zopfli_native, .prior = 30, .release = .v1_0_2, .collapsed_into = "zopfli 1.0.3 (in-process)" },
    .{ .name = "zopfli 1.0.1 (in-process)", .binary = "(zopfli-native)", .impl_type = .zopfli_native, .prior = 30, .release = .v1_0_1 },
    .{ .name = "zopfli 1.0.0 (in-process)", .binary = "(zopfli-native)", .impl_type = .zopfli_native, .prior = 30, .release = .v1_0_0 },
    .{ .name = "zopfli 1.0.3",      .binary = "zopfli-1.0.3",       .impl_type = .zopfli,      .prior = 30 },
    .{ .name = "advdef 2.6",        .binary = "advdef-2.6",         .impl_type = .advdef,      .prior = 31 },
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
    try std.testing.expectEqualStrings("zlib class D (integrated)", profiles[1].name);
}

test "native zopfli profiles cover every official release exactly once" {
    var seen = [_]usize{0} ** 4;
    for (profiles) |p| {
        if (p.impl_type != .zopfli_native) continue;
        const index = @intFromEnum(p.release.?);
        seen[index] += 1;
        // Exactly the 1.0.2 profile is collapsed into its 1.0.3 twin.
        const collapsed = p.release.? == .v1_0_2;
        try std.testing.expectEqual(collapsed, p.collapsed_into != null);
    }
    for (seen) |count| try std.testing.expectEqual(@as(usize, 1), count);
    // The external CLI profile stays release-tagged as 1.0.3.
    for (profiles) |p| {
        if (p.impl_type == .zopfli) try std.testing.expect(p.release == null);
    }
}

test "zopfli headers follow the release container changes" {
    for (profiles) |p| {
        if (p.impl_type != .zopfli_native) continue;
        const expected: u16 = switch (p.release.?) {
            .v1_0_0, .v1_0_1 => 0x7801,
            .v1_0_2, .v1_0_3 => 0x78DA,
        };
        try std.testing.expectEqual(expected, zopfliHeaderOf(p));
    }
}

test "integrated coverage flags match the engine's verified range" {
    for (profiles) |p| {
        switch (p.impl_type) {
            .integrated => try std.testing.expect(!p.covered_by_integrated),
            .zlib_family, .legacy_zlib => {
                // Every listed stock zlib release from 1.2.3 through 1.4 is
                // covered; 1.3.2/1.4 are covered for the verified one-shot
                // producer model plus the 710-scenario streaming matrix
                // (see EQUIVALENCE.md).
                // zlib-ng is covered by the native zlib-ng engine
                // (src/zlibng/), not by the stock-zlib integrated engine —
                // the flag's meaning is "reproduced bit-exactly in-process
                // in the default search mode".
                const covered_versions = [_][]const u8{
                    "zlib 1.2.3", "zlib 1.2.5", "zlib 1.2.7", "zlib 1.2.8",
                    "zlib 1.2.11", "zlib 1.2.12", "zlib 1.2.13", "zlib 1.3", "zlib 1.3.1", "zlib 1.3.2",
                    "zlib 1.4",
                    "zlib-ng 2.2.1",
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

test "pre-1.2.3 zlib releases are separate non-integrated profiles" {
    var count: usize = 0;
    for (profiles) |p| {
        if (p.impl_type != .legacy_zlib) continue;
        count += 1;
        try std.testing.expect(!p.covered_by_integrated);
        try std.testing.expect(std.mem.startsWith(u8, p.binary, "zlib-"));
    }
    try std.testing.expectEqual(@as(usize, 16), count);
}

test "class registry agrees with tested release coverage" {
    var counts = [_]usize{0} ** 8;
    for (profiles) |p| {
        if (zlibClass(p)) |group| counts[@intFromEnum(group)] += 1;
    }
    try std.testing.expectEqualSlices(usize, &.{ 5, 5, 7, 3, 1, 3, 0, 7 }, &counts);
    try std.testing.expect(zlibClass(profiles[0]) == null);
}
