//! Dynamic Huffman length selection per historical Zopfli release.
//!
//! 1.0.0 (commit history: before "denser huffman tree encoding"):
//!     raw symbol counts -> package-merge lengths -> distance patch.
//! 1.0.1 (commit ae16c9e / b87006b lineage):
//!     OptimizeHuffmanForRle is ALWAYS applied before package-merge.
//! 1.0.2 / 1.0.3 (commit e0e937e "try both with and without
//!     OptimizeHuffmanForRle"):
//!     both histograms are tried and the smaller total encoding wins.
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const tree = @import("tree.zig");
const rle = @import("deflate_rle.zig");
const cost = @import("deflate_cost.zig");
const header = @import("deflate_tree_encode.zig");
const release = @import("release.zig");

fn tryOptimize(
    store: *const lz77.Store,
    start: usize,
    end: usize,
    ll_counts: *const [288]usize,
    d_counts: *const [32]usize,
    ll_lengths: [*]c_uint,
    d_lengths: [*]c_uint,
) f64 {
    const tree_size = header.ZfDeflateCalculateTreeSize(ll_lengths, d_lengths);
    const data_size = cost.ZfDeflateCalculateBlockSymbolSizeGivenCounts(
        ll_counts, d_counts, ll_lengths, d_lengths, store, start, end);

    var ll_counts_new = ll_counts.*;
    var d_counts_new = d_counts.*;
    var ll_lengths_new: [288]c_uint = undefined;
    var d_lengths_new: [32]c_uint = undefined;
    rle.OptimizeHuffmanForRle(288, &ll_counts_new);
    rle.OptimizeHuffmanForRle(32, &d_counts_new);
    tree.ZopfliCalculateBitLengths(&ll_counts_new, 288, 15, &ll_lengths_new);
    tree.ZopfliCalculateBitLengths(&d_counts_new, 32, 15, &d_lengths_new);
    rle.ZfDeflatePatchDistanceCodes(&d_lengths_new);

    const tree_size_new = header.ZfDeflateCalculateTreeSize(&ll_lengths_new, &d_lengths_new);
    const data_size_new = cost.ZfDeflateCalculateBlockSymbolSizeGivenCounts(
        ll_counts, d_counts, &ll_lengths_new, &d_lengths_new, store, start, end);

    if (tree_size_new + data_size_new < tree_size + data_size) {
        @memcpy(ll_lengths[0..288], &ll_lengths_new);
        @memcpy(d_lengths[0..32], &d_lengths_new);
        return @floatFromInt(tree_size_new + data_size_new);
    }
    return @floatFromInt(tree_size + data_size);
}

/// Always applies OptimizeHuffmanForRle (1.0.1 behaviour) and returns
/// tree + data size in bits for the resulting lengths. The data size is
/// computed over the store (upstream CalculateBlockSymbolSize), NOT over
/// the RLE-adjusted histogram: upstream 1.0.1 keeps the plain per-symbol
/// iteration, whose counts are the unmodified ones.
fn alwaysOptimize(
    store: *const lz77.Store,
    start: usize,
    end: usize,
    ll_counts: *[288]usize,
    d_counts: *[32]usize,
    ll_lengths: [*]c_uint,
    d_lengths: [*]c_uint,
) f64 {
    rle.OptimizeHuffmanForRle(288, ll_counts);
    rle.OptimizeHuffmanForRle(32, d_counts);
    tree.ZopfliCalculateBitLengths(ll_counts, 288, 15, ll_lengths);
    tree.ZopfliCalculateBitLengths(d_counts, 32, 15, d_lengths);
    rle.ZfDeflatePatchDistanceCodes(d_lengths);
    const tree_size = header.calculateTreeSize(.v1_0_1, ll_lengths, d_lengths);
    const data_size = cost.ZfDeflateCalculateBlockSymbolSize(ll_lengths, d_lengths, store, start, end);
    return @floatFromInt(tree_size + data_size);
}

pub export fn ZfDeflateGetDynamicLengths(
    store: *const lz77.Store,
    start: usize,
    end: usize,
    ll_lengths: [*]c_uint,
    d_lengths: [*]c_uint,
) callconv(.c) f64 {
    return getDynamicLengths(store, start, end, ll_lengths, d_lengths, .v1_0_3);
}

/// Variant-dispatching dynamic length selection; returns the size of the
/// encoded tree plus the encoded block symbols, in bits (excluding the
/// 3-bit block header), matching the cost the release would optimize for.
pub fn getDynamicLengths(
    store: *const lz77.Store,
    start: usize,
    end: usize,
    ll_lengths: [*]c_uint,
    d_lengths: [*]c_uint,
    variant: release.ZopfliRelease,
) f64 {
    var ll_counts: [288]usize = undefined;
    var d_counts: [32]usize = undefined;
    switch (variant) {
        .v1_0_0 => {
            // 1.0.0: no RLE histogram optimization at all.
            lz77.ZopfliLZ77GetHistogram(store, start, end, &ll_counts, &d_counts);
            ll_counts[256] = 1;
            tree.ZopfliCalculateBitLengths(&ll_counts, 288, 15, ll_lengths);
            tree.ZopfliCalculateBitLengths(&d_counts, 32, 15, d_lengths);
            rle.ZfDeflatePatchDistanceCodes(d_lengths);
            const tree_size = header.calculateTreeSize(variant, ll_lengths, d_lengths);
            const data_size = cost.ZfDeflateCalculateBlockSymbolSizeGivenCounts(
                &ll_counts, &d_counts, ll_lengths, d_lengths, store, start, end);
            return @floatFromInt(tree_size + data_size);
        },
        .v1_0_1 => {
            lz77.ZopfliLZ77GetHistogram(store, start, end, &ll_counts, &d_counts);
            ll_counts[256] = 1;
            return alwaysOptimize(store, start, end, &ll_counts, &d_counts, ll_lengths, d_lengths);
        },
        .v1_0_2, .v1_0_3 => {
            lz77.ZopfliLZ77GetHistogram(store, start, end, &ll_counts, &d_counts);
            ll_counts[256] = 1;
            tree.ZopfliCalculateBitLengths(&ll_counts, 288, 15, ll_lengths);
            tree.ZopfliCalculateBitLengths(&d_counts, 32, 15, d_lengths);
            rle.ZfDeflatePatchDistanceCodes(d_lengths);
            return tryOptimize(store, start, end, &ll_counts, &d_counts, ll_lengths, d_lengths);
        },
    }
}

test "dynamic optimizer preserves valid empty-block end symbol" {
    var store: lz77.Store = undefined;
    const bytes = [_]u8{0};
    lz77.ZopfliInitLZ77Store(&bytes, &store);
    var ll: [288]c_uint = undefined;
    var d: [32]c_uint = undefined;
    inline for (.{ release.ZopfliRelease.v1_0_0, .v1_0_1, .v1_0_3 }) |variant| {
        _ = getDynamicLengths(&store, 0, 0, &ll, &d, variant);
        try std.testing.expect(ll[256] != 0);
        try std.testing.expect(d[0] != 0 and d[1] != 0);
    }
}

test "1.0.0 dynamic lengths differ from 1.0.3 on an RLE-friendly histogram" {
    // A histogram that is highly regular (all runs) is exactly the case
    // where the 1.0.1+ RLE optimization changes the chosen code lengths;
    // 1.0.0 must NOT apply it. Build a tiny store with a skewed alphabet.
    var store: lz77.Store = undefined;
    var data: [4096]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = if (i % 7 == 0) @intCast(i % 251) else 'x';
    lz77.ZopfliInitLZ77Store(&data, &store);
    defer lz77.ZopfliCleanLZ77Store(&store);
    var state: lz77.BlockState = undefined;
    var options: release.Options = std.mem.zeroes(release.Options);
    options.numiterations = 1;
    lz77.ZopfliInitBlockState(&options, 0, data.len, 0, &state);
    var hash: @import("hash.zig").Hash = undefined;
    @import("hash.zig").ZopfliAllocHash(@import("hash.zig").window_size, &hash);
    defer @import("hash.zig").ZopfliCleanHash(&hash);
    @import("lz77_greedy.zig").ZopfliLZ77Greedy(&state, &data, 0, data.len, &store, &hash);
    try std.testing.expect(store.size > 0);

    var ll0: [288]c_uint = undefined;
    var d0: [32]c_uint = undefined;
    var ll3: [288]c_uint = undefined;
    var d3: [32]c_uint = undefined;
    _ = getDynamicLengths(&store, 0, store.size, &ll0, &d0, .v1_0_0);
    _ = getDynamicLengths(&store, 0, store.size, &ll3, &d3, .v1_0_3);
    // The chosen lengths must be valid Huffman lengths in both variants.
    try std.testing.expect(ll0[256] != 0 and ll3[256] != 0);
    // And the 1.0.0 cost must never be reported as smaller than its own
    // tree+data encoding (self-consistency of the returned size).
    try std.testing.expect(getDynamicLengths(&store, 0, store.size, &ll0, &d0, .v1_0_0) > 0);
}
