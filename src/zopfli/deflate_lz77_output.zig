//! Native DEFLATE Huffman symbol emission from Zopfli 1.0.3 AddLZ77Data.
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const writer = @import("deflate_tree_encode.zig");

const length_bases = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const distance_bases = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

fn lengthExtra(symbol: usize) c_uint {
    return @intCast(if (symbol < 265 or symbol == 285) @as(usize, 0) else (symbol - 261) / 4);
}

fn distanceExtra(symbol: usize) c_uint {
    return @intCast(if (symbol < 4) @as(usize, 0) else symbol / 2 - 1);
}

pub export fn ZfDeflateAddLZ77Data(
    store: *const lz77.Store,
    start: usize,
    end: usize,
    expected_data_size: usize,
    ll_symbols: [*]const c_uint,
    ll_lengths: [*]const c_uint,
    d_symbols: [*]const c_uint,
    d_lengths: [*]const c_uint,
    bp: *u8,
    output: *?[*]u8,
    output_size: *usize,
) callconv(.c) void {
    var uncompressed: usize = 0;
    for (start..end) |i| {
        const distance = store.dists.?[i];
        const literal_or_length = store.litlens.?[i];
        if (distance == 0) {
            std.debug.assert(literal_or_length < 256 and ll_lengths[literal_or_length] > 0);
            writer.writeBits(ll_symbols[literal_or_length], ll_lengths[literal_or_length], true, bp, output, output_size);
            uncompressed += 1;
        } else {
            const lsym: usize = lz77.lengthSymbol(literal_or_length);
            const dsym: usize = lz77.distanceSymbol(distance);
            std.debug.assert(literal_or_length >= 3 and literal_or_length <= 258);
            std.debug.assert(ll_lengths[lsym] > 0 and d_lengths[dsym] > 0);
            writer.writeBits(ll_symbols[lsym], ll_lengths[lsym], true, bp, output, output_size);
            writer.writeBits(literal_or_length - length_bases[lsym - 257], lengthExtra(lsym), false, bp, output, output_size);
            writer.writeBits(d_symbols[dsym], d_lengths[dsym], true, bp, output, output_size);
            writer.writeBits(distance - distance_bases[dsym], distanceExtra(dsym), false, bp, output, output_size);
            uncompressed += literal_or_length;
        }
    }
    std.debug.assert(expected_data_size == 0 or expected_data_size == uncompressed);
}

test "length-distance bases have exact DEFLATE boundaries" {
    try std.testing.expectEqual(@as(u16, 258), length_bases[28]);
    try std.testing.expectEqual(@as(u16, 24577), distance_bases[29]);
    try std.testing.expectEqual(@as(c_uint, 0), lengthExtra(285));
    try std.testing.expectEqual(@as(c_uint, 13), distanceExtra(29));
}
