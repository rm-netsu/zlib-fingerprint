//! Historical Zopfli release variants and the canonical options struct.
//!
//! Each value of `ZopfliRelease` identifies one official upstream release of
//! Zopfli (https://github.com/google/zopfli). The native Zig implementation
//! reproduces the byte-exact output of every release by switching only the
//! functions whose behaviour actually changed between releases (verified by
//! the differential source analysis and the byte-level equivalence matrix):
//!
//! | Aspect                                | 1.0.0   | 1.0.1   | 1.0.2 / 1.0.3 |
//! |---------------------------------------|---------|---------|---------------|
//! | RFC 1950 FLEVEL header bits           | 0       | 0       | 3             |
//! | Dynamic lengths: histogram RLE opt.   | none    | always  | try both      |
//! | Dynamic tree encoding                 | fixed   | 8-combo | 8-combo       |
//! | Block type selection                  | dynamic | dynamic | auto          |
//! | Block splitting cost model            | dynamic | dynamic | auto          |
//! | Master block size                     | 20 MB   | 20 MB   | 1 MB          |
//! | Empty input (CLI)                     | refused | refused | empty block   |
//!
//! 1.0.2 and 1.0.3 share one code path: their only source difference is a
//! `malloc` cast in `deflate.c` (`(unsigned)length * sizeof(int)`) with no
//! observable effect for any admissible length (<= 288). The equivalence
//! matrix confirms byte-identity across the whole corpus.
//!
//! The variant is always passed explicitly (options field / function
//! parameter); there is no mutable global version switch.

const std = @import("std");

pub const ZopfliRelease = enum(u8) {
    v1_0_0,
    v1_0_1,
    v1_0_2,
    v1_0_3,

    /// Release name as used in profiles, reports and the CLI ("1.0.3").
    pub fn name(self: ZopfliRelease) []const u8 {
        return switch (self) {
            .v1_0_0 => "1.0.0",
            .v1_0_1 => "1.0.1",
            .v1_0_2 => "1.0.2",
            .v1_0_3 => "1.0.3",
        };
    }

    /// FLEVEL bits written into the RFC 1950 header by the release's
    /// zlib_container.c (0 until 1.0.1, 3 from 1.0.2 on, commit 05e3efc
    /// "Set zlib level bits to 3 to indicate slowest compression").
    pub fn flevel(self: ZopfliRelease) u2 {
        return switch (self) {
            .v1_0_0, .v1_0_1 => 0,
            .v1_0_2, .v1_0_3 => 3,
        };
    }

    /// The two container header bytes (CMF, FLG) the release emits for a
    /// stream without a preset dictionary: CM=8, CINFO=7 -> CMF=0x78;
    /// FCHECK makes CMF*256 + FDICT*32 + FLEVEL*64 + FCHECK divisible by 31.
    pub fn containerHeader(self: ZopfliRelease) [2]u8 {
        return switch (self) {
            .v1_0_0, .v1_0_1 => .{ 0x78, 0x01 },
            .v1_0_2, .v1_0_3 => .{ 0x78, 0xda },
        };
    }

    /// ZOPFLI_MASTER_BLOCK_SIZE of the release (util.h): 20,000,000 before
    /// 1.0.2, 1,000,000 from 1.0.2 on (commit fdb3745 "Decrease master block
    /// size to use less memory").
    pub fn masterBlockSize(self: ZopfliRelease) usize {
        return switch (self) {
            .v1_0_0, .v1_0_1 => 20_000_000,
            .v1_0_2, .v1_0_3 => 1_000_000,
        };
    }

    /// True for the releases whose CLI refuses an empty input file
    /// ("Invalid filename") and whose library emits no DEFLATE block for
    /// an empty buffer (the `while (i < insize)` master loop never runs).
    pub fn rejectsEmptyInput(self: ZopfliRelease) bool {
        return switch (self) {
            .v1_0_0, .v1_0_1 => true,
            .v1_0_2, .v1_0_3 => false,
        };
    }

    /// The releases that are byte-identical to this one across the whole
    /// verified equivalence matrix (1.0.2 == 1.0.3, only malloc cast).
    pub fn equivalentGroup(self: ZopfliRelease) []const []const u8 {
        return switch (self) {
            .v1_0_0 => &.{"1.0.0"},
            .v1_0_1 => &.{"1.0.1"},
            .v1_0_2, .v1_0_3 => &.{ "1.0.2", "1.0.3" },
        };
    }

    pub fn parse(text: []const u8) ?ZopfliRelease {
        inline for (@typeInfo(ZopfliRelease).@"enum".fields) |field| {
            const value: ZopfliRelease = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, value.name())) return value;
        }
        return null;
    }
};

/// Canonical Zopfli options (upstream ZopfliOptions, util.c) plus the
/// release variant. Kept C-ABI-compatible: the Zopfli core modules exchange
/// it through `*const anyopaque` block-state pointers.
pub const Options = extern struct {
    verbose: c_int,
    verbose_more: c_int,
    numiterations: c_int,
    blocksplitting: c_int,
    blocksplittinglast: c_int,
    blocksplittingmax: c_int,
    /// Which historical release's behaviour to reproduce.
    variant: ZopfliRelease = .v1_0_3,
};

/// Upstream ZopfliInitOptions (util.c, identical in every release) with the
/// requested variant.
pub fn initOptions(num_iterations: c_int, variant: ZopfliRelease) Options {
    return .{
        .verbose = 0,
        .verbose_more = 0,
        .numiterations = num_iterations,
        .blocksplitting = 1,
        .blocksplittinglast = 0,
        .blocksplittingmax = 15,
        .variant = variant,
    };
}

test "release metadata matches the official sources" {
    try std.testing.expectEqual([2]u8{ 0x78, 0x01 }, ZopfliRelease.v1_0_0.containerHeader());
    try std.testing.expectEqual([2]u8{ 0x78, 0x01 }, ZopfliRelease.v1_0_1.containerHeader());
    try std.testing.expectEqual([2]u8{ 0x78, 0xda }, ZopfliRelease.v1_0_2.containerHeader());
    try std.testing.expectEqual([2]u8{ 0x78, 0xda }, ZopfliRelease.v1_0_3.containerHeader());
    try std.testing.expectEqual(@as(usize, 20_000_000), ZopfliRelease.v1_0_1.masterBlockSize());
    try std.testing.expectEqual(@as(usize, 1_000_000), ZopfliRelease.v1_0_2.masterBlockSize());
    try std.testing.expect(ZopfliRelease.v1_0_0.rejectsEmptyInput());
    try std.testing.expect(!ZopfliRelease.v1_0_3.rejectsEmptyInput());
    try std.testing.expectEqual(@as(?ZopfliRelease, .v1_0_3), ZopfliRelease.parse("1.0.3"));
    try std.testing.expectEqual(@as(?ZopfliRelease, null), ZopfliRelease.parse("0.9"));
}
