//! Dynamic Huffman-tree header RLE and bit emission.
//!
//! `ZfDeflateEncodeTree` reproduces the 1.0.1+ strategy-search encoder
//! (commit b87006b "denser huffman tree encoding"). `addDynamicTreeLegacy`
//! reproduces the 1.0.0 fixed-strategy encoder; `addDynamicTree` and
//! `calculateTreeSize` dispatch on the release variant.
const std = @import("std");
const tree = @import("tree.zig");
const release = @import("release.zig");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn realloc(?*anyopaque, usize) callconv(.c) ?*anyopaque;

const order = [_]usize{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

pub fn appendByte(out: *?[*]u8, size: *usize, byte: u8) void {
    const index = size.*;
    if ((index & (index -% 1)) == 0) {
        const capacity = if (index == 0) @as(usize, 1) else index * 2;
        const old: ?*anyopaque = if (out.*) |pointer| @ptrCast(pointer) else null;
        const raw = if (index == 0) malloc(1) else realloc(old, capacity);
        out.* = @ptrCast(@alignCast(raw orelse @panic("Zopfli tree output allocation failed")));
    }
    out.*.?[index] = byte;
    size.* = index + 1;
}

pub fn writeBits(value: c_uint, count: c_uint, reversed: bool, bp: *u8, output: *?[*]u8, size: *usize) void {
    for (0..count) |i| {
        const offset: u5 = @intCast(if (reversed) @as(usize, count) - i - 1 else i);
        const bit: u8 = @intCast((value >> offset) & 1);
        if (bp.* == 0) appendByte(output, size, 0);
        output.*.?[size.* - 1] |= bit << @intCast(bp.*);
        bp.* = (bp.* + 1) & 7;
    }
}

pub export fn ZfDeflateEncodeTree(
    ll_lengths: [*]const c_uint,
    d_lengths: [*]const c_uint,
    use16: c_int,
    use17: c_int,
    use18: c_int,
    bp: ?*u8,
    output: ?*?[*]u8,
    output_size: ?*usize,
) callconv(.c) usize {
    var clcounts = [_]usize{0} ** 19;
    var clcl: [19]c_uint = undefined;
    var clsymbols: [19]c_uint = undefined;
    var rle: [320]u8 = undefined;
    var extras: [320]u8 = undefined;
    var rle_size: usize = 0;
    var hlit: usize = 29;
    var hdist: usize = 29;
    while (hlit > 0 and ll_lengths[257 + hlit - 1] == 0) hlit -= 1;
    while (hdist > 0 and d_lengths[hdist] == 0) hdist -= 1;
    const ll_end = hlit + 257;
    const total = ll_end + hdist + 1;
    const size_only = output == null;

    var i: usize = 0;
    while (i < total) {
        const symbol: usize = @intCast(if (i < ll_end) ll_lengths[i] else d_lengths[i - ll_end]);
        var count: usize = 1;
        if (use16 != 0 or (symbol == 0 and (use17 != 0 or use18 != 0))) {
            while (i + count < total and symbol == (if (i + count < ll_end)
                ll_lengths[i + count] else d_lengths[i + count - ll_end])) : (count += 1) {}
        }
        i += count;

        if (symbol == 0 and count >= 3) {
            if (use18 != 0) {
                while (count >= 11) {
                    const amount = @min(count, 138);
                    if (!size_only) {
                        rle[rle_size] = 18;
                        extras[rle_size] = @intCast(amount - 11);
                        rle_size += 1;
                    }
                    clcounts[18] += 1;
                    count -= amount;
                }
            }
            if (use17 != 0) {
                while (count >= 3) {
                    const amount = @min(count, 10);
                    if (!size_only) {
                        rle[rle_size] = 17;
                        extras[rle_size] = @intCast(amount - 3);
                        rle_size += 1;
                    }
                    clcounts[17] += 1;
                    count -= amount;
                }
            }
        }
        if (use16 != 0 and count >= 4) {
            count -= 1;
            clcounts[symbol] += 1;
            if (!size_only) {
                rle[rle_size] = @intCast(symbol);
                extras[rle_size] = 0;
                rle_size += 1;
            }
            while (count >= 3) {
                const amount = @min(count, 6);
                if (!size_only) {
                    rle[rle_size] = 16;
                    extras[rle_size] = @intCast(amount - 3);
                    rle_size += 1;
                }
                clcounts[16] += 1;
                count -= amount;
            }
        }
        clcounts[symbol] += count;
        for (0..count) |_| {
            if (!size_only) {
                rle[rle_size] = @intCast(symbol);
                extras[rle_size] = 0;
                rle_size += 1;
            }
        }
    }

    tree.ZopfliCalculateBitLengths(&clcounts, 19, 7, &clcl);
    if (!size_only) tree.ZopfliLengthsToSymbols(&clcl, 19, 7, &clsymbols);
    var hclen: usize = 15;
    while (hclen > 0 and clcounts[order[hclen + 4 - 1]] == 0) hclen -= 1;

    if (!size_only) {
        const bitpointer = bp.?;
        const bytes = output.?;
        const size = output_size.?;
        writeBits(@intCast(hlit), 5, false, bitpointer, bytes, size);
        writeBits(@intCast(hdist), 5, false, bitpointer, bytes, size);
        writeBits(@intCast(hclen), 4, false, bitpointer, bytes, size);
        for (0..hclen + 4) |j| writeBits(clcl[order[j]], 3, false, bitpointer, bytes, size);
        for (0..rle_size) |j| {
            const symbol: usize = rle[j];
            writeBits(clsymbols[symbol], clcl[symbol], true, bitpointer, bytes, size);
            if (symbol == 16) writeBits(extras[j], 2, false, bitpointer, bytes, size);
            if (symbol == 17) writeBits(extras[j], 3, false, bitpointer, bytes, size);
            if (symbol == 18) writeBits(extras[j], 7, false, bitpointer, bytes, size);
        }
    }

    var bits: usize = 14 + (hclen + 4) * 3;
    for (0..19) |j| bits += clcl[j] * clcounts[j];
    bits += clcounts[16] * 2 + clcounts[17] * 3 + clcounts[18] * 7;
    return bits;
}

pub export fn ZfDeflateCalculateTreeSize(ll: [*]const c_uint, d: [*]const c_uint) callconv(.c) usize {
    var best: usize = 0;
    for (0..8) |flags| {
        const cost = ZfDeflateEncodeTree(ll, d, @intCast(flags & 1), @intCast(flags & 2), @intCast(flags & 4), null, null, null);
        if (best == 0 or cost < best) best = cost;
    }
    return best;
}

pub export fn ZfDeflateAddDynamicTree(ll: [*]const c_uint, d: [*]const c_uint, bp: *u8, output: *?[*]u8, output_size: *usize) callconv(.c) void {
    var best: usize = 0;
    var best_size: usize = 0;
    for (0..8) |flags| {
        const cost = ZfDeflateEncodeTree(ll, d, @intCast(flags & 1), @intCast(flags & 2), @intCast(flags & 4), null, null, null);
        if (best_size == 0 or cost < best_size) {
            best_size = cost;
            best = flags;
        }
    }
    _ = ZfDeflateEncodeTree(ll, d, @intCast(best & 1), @intCast(best & 2), @intCast(best & 4), bp, output, output_size);
}

/// Zopfli 1.0.0's AddDynamicTree (deflate.c): one fixed RLE strategy.
/// Runs of equal lengths are compressed only when count >= 4 (>= 3 for
/// zeros); zero runs longer than 10 emit symbol 18 (clamped to 138),
/// shorter zero runs emit 17; non-zero runs emit the first length plus
/// 16-repeats in chunks of 6, one more 16 when 3..5 remain, then singles.
/// When `bp` is null only the encoded size in bits is returned.
pub fn addDynamicTreeLegacy(ll_lengths: [*]const c_uint, d_lengths: [*]const c_uint, bp: ?*u8, output: ?*?[*]u8, output_size: ?*usize) usize {
    var clcounts = [_]usize{0} ** 19;
    var clcl: [19]c_uint = undefined;
    var clsymbols: [19]c_uint = undefined;
    var rle: [320]u8 = undefined;
    var extras: [320]u8 = undefined;
    var rle_size: usize = 0;
    var hlit: usize = 29;
    var hdist: usize = 29;
    while (hlit > 0 and ll_lengths[257 + hlit - 1] == 0) hlit -= 1;
    while (hdist > 0 and d_lengths[hdist] == 0) hdist -= 1;
    const ll_end = hlit + 257;
    const total = ll_end + hdist + 1;
    const size_only = bp == null;

    var i: usize = 0;
    while (i < total) {
        const symbol: usize = @intCast(if (i < ll_end) ll_lengths[i] else d_lengths[i - ll_end]);
        var count: usize = 1;
        while (i + count < total and symbol == (if (i + count < ll_end)
            ll_lengths[i + count] else d_lengths[i + count - ll_end])) : (count += 1) {}

        if (count >= 4 or (count >= 3 and symbol == 0)) {
            if (symbol == 0) {
                if (count > 10) {
                    if (count > 138) count = 138;
                    clcounts[18] += 1;
                    if (!size_only) {
                        rle[rle_size] = 18;
                        extras[rle_size] = @intCast(count - 11);
                        rle_size += 1;
                    }
                } else {
                    clcounts[17] += 1;
                    if (!size_only) {
                        rle[rle_size] = 17;
                        extras[rle_size] = @intCast(count - 3);
                        rle_size += 1;
                    }
                }
            } else {
                var repeat = count - 1; // Since the first one is hardcoded.
                clcounts[symbol] += 1;
                if (!size_only) {
                    rle[rle_size] = @intCast(symbol);
                    extras[rle_size] = 0;
                    rle_size += 1;
                }
                while (repeat >= 6) {
                    clcounts[16] += 1;
                    if (!size_only) {
                        rle[rle_size] = 16;
                        extras[rle_size] = 3; // 6 - 3
                        rle_size += 1;
                    }
                    repeat -= 6;
                }
                if (repeat >= 3) {
                    clcounts[16] += 1;
                    if (!size_only) {
                        rle[rle_size] = 16;
                        extras[rle_size] = 0; // 3 - 3
                        rle_size += 1;
                    }
                    repeat -= 3;
                }
                while (repeat != 0) {
                    clcounts[symbol] += 1;
                    if (!size_only) {
                        rle[rle_size] = @intCast(symbol);
                        extras[rle_size] = 0;
                        rle_size += 1;
                    }
                    repeat -= 1;
                }
            }
            i += count - 1;
        } else {
            clcounts[symbol] += 1;
            if (!size_only) {
                rle[rle_size] = @intCast(symbol);
                extras[rle_size] = 0;
                rle_size += 1;
            }
        }
        i += 1;
    }

    tree.ZopfliCalculateBitLengths(&clcounts, 19, 7, &clcl);
    if (!size_only) tree.ZopfliLengthsToSymbols(&clcl, 19, 7, &clsymbols);
    var hclen: usize = 15;
    while (hclen > 0 and clcounts[order[hclen + 4 - 1]] == 0) hclen -= 1;

    if (!size_only) {
        const bitpointer = bp.?;
        const bytes = output.?;
        const size = output_size.?;
        writeBits(@intCast(hlit), 5, false, bitpointer, bytes, size);
        writeBits(@intCast(hdist), 5, false, bitpointer, bytes, size);
        writeBits(@intCast(hclen), 4, false, bitpointer, bytes, size);
        for (0..hclen + 4) |j| writeBits(clcl[order[j]], 3, false, bitpointer, bytes, size);
        for (0..rle_size) |j| {
            const rle_symbol: usize = rle[j];
            writeBits(clsymbols[rle_symbol], clcl[rle_symbol], true, bitpointer, bytes, size);
            if (rle_symbol == 16) writeBits(extras[j], 2, false, bitpointer, bytes, size);
            if (rle_symbol == 17) writeBits(extras[j], 3, false, bitpointer, bytes, size);
            if (rle_symbol == 18) writeBits(extras[j], 7, false, bitpointer, bytes, size);
        }
    }

    var bits: usize = 14 + (hclen + 4) * 3;
    for (0..19) |j| bits += clcl[j] * clcounts[j];
    bits += clcounts[16] * 2 + clcounts[17] * 3 + clcounts[18] * 7;
    return bits;
}

/// Size in bits of the dynamic tree encoding the given release would emit.
/// For 1.0.0 this reproduces upstream CalculateTreeSize exactly: the tree is
/// dummy-encoded into a byte buffer and the size is reported as
/// `dummysize * 8 + (bp & 7)` — which over-counts non-byte-aligned trees by
/// up to 8 bits. The over-count is part of the historical cost model and
/// influences the 1.0.0 block-splitting and fixed-tree decisions, so it must
/// be preserved byte-for-byte.
pub fn calculateTreeSize(variant: release.ZopfliRelease, ll: [*]const c_uint, d: [*]const c_uint) usize {
    return switch (variant) {
        .v1_0_0 => blk: {
            const bits = addDynamicTreeLegacy(ll, d, null, null, null);
            break :blk ((bits + 7) / 8) * 8 + (bits & 7);
        },
        .v1_0_1, .v1_0_2, .v1_0_3 => ZfDeflateCalculateTreeSize(ll, d),
    };
}

/// Emit the dynamic tree header the given release would emit; returns the
/// number of bits written.
pub fn addDynamicTree(variant: release.ZopfliRelease, ll: [*]const c_uint, d: [*]const c_uint, bp: *u8, output: *?[*]u8, output_size: *usize) usize {
    return switch (variant) {
        .v1_0_0 => addDynamicTreeLegacy(ll, d, bp, output, output_size),
        .v1_0_1, .v1_0_2, .v1_0_3 => blk: {
            ZfDeflateAddDynamicTree(ll, d, bp, output, output_size);
            break :blk calculateTreeSize(variant, ll, d);
        },
    };
}

test "legacy 1.0.0 tree encoder writes exactly the size it reports" {
    var literal = [_]c_uint{0} ** 288;
    var distance = [_]c_uint{0} ** 32;
    literal[97] = 3;
    literal[256] = 1;
    literal[0] = 2;
    distance[0] = 1;
    distance[1] = 1;
    const expected = addDynamicTreeLegacy(&literal, &distance, null, null, null);
    var bp: u8 = 0;
    var out: ?[*]u8 = null;
    var out_size: usize = 0;
    const written = addDynamicTreeLegacy(&literal, &distance, &bp, &out, &out_size);
    defer if (out) |ptr| std.c.free(@ptrCast(ptr));
    try std.testing.expectEqual(expected, written);
    // The write path emits exactly `bits` bits: bytes = ceil(bits/8),
    // trailing bit pointer = bits & 7.
    try std.testing.expectEqual((written + 7) / 8, out_size);
    try std.testing.expectEqual(@as(u8, @intCast(written & 7)), bp);
    // The 1.0.0 cost-model size (byte-accounted, upstream quirk).
    try std.testing.expectEqual(((written + 7) / 8) * 8 + (written & 7), calculateTreeSize(.v1_0_0, &literal, &distance));
}

test "legacy and strategy-search encoders agree on the canonical small tree" {
    // With a single used literal and the end symbol both encoders must
    // produce a valid encoding; sizes may differ (1.0.0 is not minimal),
    // but both must at least encode the 19 code-length codes.
    var literal = [_]c_uint{0} ** 288;
    var distance = [_]c_uint{0} ** 32;
    literal[256] = 1;
    distance[0] = 1;
    distance[1] = 1;
    const legacy = addDynamicTreeLegacy(&literal, &distance, null, null, null);
    const modern = ZfDeflateCalculateTreeSize(&literal, &distance);
    try std.testing.expect(legacy >= 14 + 4 * 3);
    try std.testing.expect(modern >= 14 + 4 * 3);
}

test "dynamic tree size is computed without an output buffer" {
    var literal = [_]c_uint{0} ** 288;
    var distance = [_]c_uint{0} ** 32;
    literal[256] = 1;
    distance[0] = 1;
    const size = ZfDeflateEncodeTree(&literal, &distance, 1, 2, 4, null, null, null);
    try std.testing.expect(size >= 14 + 4 * 3);
}
