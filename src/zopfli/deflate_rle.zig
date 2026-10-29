//! Native port of the DEFLATE Huffman histogram RLE optimization heuristic
//! from Zopfli 1.0.3 deflate.c.
const std = @import("std");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;

pub export fn ZfDeflatePatchDistanceCodes(lengths: [*]c_uint) callconv(.c) void {
    var nonzero: usize = 0;
    for (0..30) |i| {
        if (lengths[i] != 0) nonzero += 1;
        if (nonzero >= 2) return;
    }
    if (nonzero == 0) {
        lengths[0] = 1;
        lengths[1] = 1;
    } else {
        lengths[if (lengths[0] != 0) @as(usize, 1) else 0] = 1;
    }
}

pub export fn ZfDeflateGetFixedTree(literal_lengths: [*]c_uint, distance_lengths: [*]c_uint) callconv(.c) void {
    @memset(literal_lengths[0..144], 8);
    @memset(literal_lengths[144..256], 9);
    @memset(literal_lengths[256..280], 7);
    @memset(literal_lengths[280..288], 8);
    @memset(distance_lengths[0..32], 5);
}

pub export fn OptimizeHuffmanForRle(original_length: c_int, counts: [*]usize) callconv(.c) void {
    var length: usize = @intCast(@max(original_length, 0));
    while (length > 0 and counts[length - 1] == 0) length -= 1;
    if (length == 0) return;

    const raw = malloc(length * @sizeOf(c_int)) orelse @panic("Zopfli RLE allocation failed");
    defer free(raw);
    const good: [*]c_int = @ptrCast(@alignCast(raw));
    @memset(good[0..length], 0);

    var symbol = counts[0];
    var stride: usize = 0;
    for (0..length + 1) |i| {
        if (i == length or counts[i] != symbol) {
            if ((symbol == 0 and stride >= 5) or (symbol != 0 and stride >= 7)) {
                for (0..stride) |k| good[i - k - 1] = 1;
            }
            stride = 1;
            if (i != length) symbol = counts[i];
        } else {
            stride += 1;
        }
    }

    stride = 0;
    var limit = counts[0];
    var sum: usize = 0;
    for (0..length + 1) |i| {
        if (i == length or good[i] != 0 or
            (if (i != length) (if (counts[i] > limit) counts[i] - limit else limit - counts[i]) >= 4 else false))
        {
            if (stride >= 4 or (stride >= 3 and sum == 0)) {
                var averaged = (sum + stride / 2) / stride;
                if (averaged < 1) averaged = 1;
                if (sum == 0) averaged = 0;
                for (0..stride) |k| counts[i - k - 1] = averaged;
            }
            stride = 0;
            sum = 0;
            if (i + 3 < length) {
                limit = (counts[i] + counts[i + 1] + counts[i + 2] + counts[i + 3] + 2) / 4;
            } else if (i < length) {
                limit = counts[i];
            } else {
                limit = 0;
            }
        }
        stride += 1;
        if (i != length) sum += counts[i];
    }
}

test "RLE optimization leaves trailing zero histogram tail intact" {
    var counts = [_]usize{ 2, 2, 2, 2, 2, 2, 2, 0, 0, 0 };
    OptimizeHuffmanForRle(counts.len, &counts);
    try std.testing.expectEqualSlices(usize, &.{ 2, 2, 2, 2, 2, 2, 2, 0, 0, 0 }, &counts);
}

test "RLE optimization preserves entirely empty histograms" {
    var counts = [_]usize{0} ** 32;
    OptimizeHuffmanForRle(counts.len, &counts);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(usize, &counts, &.{1}));
}

test "DEFLATE distance tree compatibility uses two placeholder codes" {
    var distances = [_]c_uint{0} ** 32;
    ZfDeflatePatchDistanceCodes(&distances);
    try std.testing.expectEqual(@as(c_uint, 1), distances[0]);
    try std.testing.expectEqual(@as(c_uint, 1), distances[1]);
    distances = [_]c_uint{0} ** 32;
    distances[15] = 4;
    ZfDeflatePatchDistanceCodes(&distances);
    try std.testing.expectEqual(@as(c_uint, 1), distances[0]);
    try std.testing.expectEqual(@as(c_uint, 4), distances[15]);
}
