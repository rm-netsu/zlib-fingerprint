//! Native bit-size estimation for stored, fixed and dynamic DEFLATE blocks,
//! parameterized by the historical release variant (the dynamic cost model
//! differs: 1.0.0 raw, 1.0.1 always-RLE, 1.0.2+ try-both).
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const rle = @import("deflate_rle.zig");
const cost = @import("deflate_cost.zig");
const dynamic = @import("deflate_dynamic.zig");
const release = @import("release.zig");

pub export fn ZopfliCalculateBlockSize(store: *const lz77.Store, start: usize, end: usize, block_type: c_int) callconv(.c) f64 {
    return calculateBlockSize(store, start, end, block_type, .v1_0_3);
}

/// Upstream ZopfliCalculateBlockSize for the given release. btype 0/1 are
/// variant-independent; btype 2 uses the release's dynamic cost model.
pub fn calculateBlockSize(store: *const lz77.Store, start: usize, end: usize, block_type: c_int, variant: release.ZopfliRelease) f64 {
    if (block_type == 0) {
        const length = lz77.ZopfliLZ77GetByteRange(store, start, end);
        const remainder = length % 65535;
        const blocks = length / 65535 + @as(usize, if (remainder != 0) 1 else 0);
        return @floatFromInt(blocks * 5 * 8 + length * 8);
    }

    var ll_lengths: [288]c_uint = undefined;
    var d_lengths: [32]c_uint = undefined;
    if (block_type == 1) {
        rle.ZfDeflateGetFixedTree(&ll_lengths, &d_lengths);
        return 3 + @as(f64, @floatFromInt(cost.ZfDeflateCalculateBlockSymbolSize(
            &ll_lengths, &d_lengths, store, start, end)));
    }
    return 3 + dynamic.getDynamicLengths(store, start, end, &ll_lengths, &d_lengths, variant);
}

test "empty stored DEFLATE block keeps upstream zero-bit cost" {
    var store: lz77.Store = undefined;
    const bytes = [_]u8{0};
    lz77.ZopfliInitLZ77Store(&bytes, &store);
    inline for (.{ release.ZopfliRelease.v1_0_0, .v1_0_1, .v1_0_3 }) |variant| {
        try std.testing.expectEqual(@as(f64, 0), calculateBlockSize(&store, 0, 0, 0, variant));
        try std.testing.expect(calculateBlockSize(&store, 0, 0, 1, variant) > 0);
    }
}
