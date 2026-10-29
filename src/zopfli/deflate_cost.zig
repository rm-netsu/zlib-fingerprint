//! Bit-exact LZ77 block symbol-size estimation for all release variants.
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const block_size = @import("deflate_block_size.zig");
const release = @import("release.zig");

fn lengthExtra(symbol: usize) usize {
    return if (symbol < 265 or symbol == 285) 0 else (symbol - 261) / 4;
}

fn distanceExtra(symbol: usize) usize {
    return if (symbol < 4) 0 else symbol / 2 - 1;
}

fn small(ll_lengths: [*]const c_uint, d_lengths: [*]const c_uint, store: *const lz77.Store, start: usize, end: usize) usize {
    var result: usize = 0;
    for (start..end) |i| {
        std.debug.assert(i < store.size and store.litlens.?[i] < 259);
        if (store.dists.?[i] == 0) {
            result += ll_lengths[store.litlens.?[i]];
        } else {
            const ll_symbol = lz77.lengthSymbol(store.litlens.?[i]);
            const d_symbol = lz77.distanceSymbol(store.dists.?[i]);
            result += ll_lengths[ll_symbol];
            result += d_lengths[d_symbol];
            result += lengthExtra(ll_symbol);
            result += distanceExtra(d_symbol);
        }
    }
    return result + ll_lengths[256];
}

pub export fn ZfDeflateCalculateBlockSymbolSizeGivenCounts(
    ll_counts: [*]const usize,
    d_counts: [*]const usize,
    ll_lengths: [*]const c_uint,
    d_lengths: [*]const c_uint,
    store: *const lz77.Store,
    start: usize,
    end: usize,
) callconv(.c) usize {
    if (start + 288 * 3 > end) return small(ll_lengths, d_lengths, store, start, end);
    var result: usize = 0;
    for (0..256) |i| result += @as(usize, ll_lengths[i]) * ll_counts[i];
    for (257..286) |i| {
        result += @as(usize, ll_lengths[i]) * ll_counts[i];
        result += lengthExtra(i) * ll_counts[i];
    }
    for (0..30) |i| {
        result += @as(usize, d_lengths[i]) * d_counts[i];
        result += distanceExtra(i) * d_counts[i];
    }
    return result + ll_lengths[256];
}

pub export fn ZfDeflateCalculateBlockSymbolSize(
    ll_lengths: [*]const c_uint,
    d_lengths: [*]const c_uint,
    store: *const lz77.Store,
    start: usize,
    end: usize,
) callconv(.c) usize {
    if (start + 288 * 3 > end) return small(ll_lengths, d_lengths, store, start, end);
    var ll_counts: [288]usize = undefined;
    var d_counts: [32]usize = undefined;
    lz77.ZopfliLZ77GetHistogram(store, start, end, &ll_counts, &d_counts);
    return ZfDeflateCalculateBlockSymbolSizeGivenCounts(&ll_counts, &d_counts, ll_lengths, d_lengths, store, start, end);
}

pub export fn ZopfliCalculateBlockSizeAutoType(store: *const lz77.Store, start: usize, end: usize) callconv(.c) f64 {
    return calculateBlockSizeAutoType(store, start, end, .v1_0_3);
}

/// Upstream ZopfliCalculateBlockSizeAutoType (1.0.2+): minimum of the
/// stored, fixed and dynamic costs. Only the 1.0.2+ orchestration uses it;
/// 1.0.0/1.0.1 block splitting always costs blocks as dynamic (btype 2).
pub fn calculateBlockSizeAutoType(store: *const lz77.Store, start: usize, end: usize, variant: release.ZopfliRelease) f64 {
    const uncompressed = block_size.calculateBlockSize(store, start, end, 0, variant);
    const fixed = if (store.size > 1000) uncompressed
        else block_size.calculateBlockSize(store, start, end, 1, variant);
    const dynamic_cost = block_size.calculateBlockSize(store, start, end, 2, variant);
    return if (uncompressed < fixed and uncompressed < dynamic_cost) uncompressed else
        if (fixed < dynamic_cost) fixed else dynamic_cost;
}

test "length and distance symbol extra-bit boundaries" {
    try std.testing.expectEqual(@as(usize, 0), lengthExtra(264));
    try std.testing.expectEqual(@as(usize, 1), lengthExtra(265));
    try std.testing.expectEqual(@as(usize, 5), lengthExtra(284));
    try std.testing.expectEqual(@as(usize, 0), lengthExtra(285));
    try std.testing.expectEqual(@as(usize, 0), distanceExtra(3));
    try std.testing.expectEqual(@as(usize, 1), distanceExtra(4));
    try std.testing.expectEqual(@as(usize, 13), distanceExtra(29));
}
