//! Zopfli 1.0.3 canonical Huffman symbol numbering in native Zig.
//! Entropy, symbol numbering and the length-limited package-merge kernel
//! (katajainen.zig) are all native; no upstream tree.c code remains linked.
const std = @import("std");
extern "c" fn log(f64) callconv(.c) f64;
const katajainen = @import("katajainen.zig");

pub const TreeError = error{ InvalidLengths, InvalidMaxBits };

/// Port of ZopfliLengthsToSymbols. The canonical numbering is deliberately
/// not bit-reversed: the encoder writes these codes MSB-first.
pub fn lengthsToSymbols(lengths: []const u32, maxbits: u8, symbols: []u32) TreeError!void {
    if (maxbits == 0 or maxbits > 15) return error.InvalidMaxBits;
    if (symbols.len < lengths.len) return error.InvalidLengths;
    var bl_count = [_]u32{0} ** 16;
    var next_code = [_]u32{0} ** 16;
    for (lengths) |len| {
        if (len > maxbits) return error.InvalidLengths;
        bl_count[len] += 1;
    }
    bl_count[0] = 0;
    var code: u32 = 0;
    for (1..@as(usize, maxbits) + 1) |bits| {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = code;
    }
    for (lengths, 0..) |len, i| {
        symbols[i] = if (len == 0) 0 else blk: {
            const v = next_code[len];
            next_code[len] += 1;
            break :blk v;
        };
    }
}

/// C ABI drop-in for the upstream tree.c routine, now backed by Zig.
pub export fn ZopfliLengthsToSymbols(lengths: [*]const c_uint, n: usize, maxbits: c_uint, symbols: [*]c_uint) callconv(.c) void {
    if (maxbits > 15) @panic("unsupported Huffman code length");
    lengthsToSymbols(lengths[0..n], @intCast(maxbits), symbols[0..n]) catch @panic("invalid Huffman lengths");
}

/// Port of ZopfliCalculateEntropy. Uses libc log to preserve the exact
/// numerical cost calculations of the reference optimizer.
pub export fn ZopfliCalculateEntropy(count: [*]const usize, n: usize, bitlengths: [*]f64) callconv(.c) void {
    const inv_log2 = 1.4426950408889;
    var sum: u32 = 0; // upstream's unsigned accumulator is 32-bit
    for (0..n) |i| sum +%= @truncate(count[i]);
    const log2sum = log(@floatFromInt(if (sum == 0) n else @as(usize, sum))) * inv_log2;
    for (0..n) |i| {
        var length = if (count[i] == 0) log2sum else
            log2sum - log(@floatFromInt(count[i])) * inv_log2;
        if (length < 0 and length > -0.00001) length = 0;
        bitlengths[i] = length;
    }
}

/// C ABI drop-in for the upstream tree.c routine. The length-limited
/// package-merge optimizer is now the native katajainen.zig kernel.
pub export fn ZopfliCalculateBitLengths(count: [*]const usize, n: usize, maxbits: c_int, bitlengths: [*]c_uint) callconv(.c) void {
    const rc = katajainen.lengthLimitedCodeLengths(count, n, maxbits, bitlengths);
    if (rc != 0) @panic("Zopfli Huffman code length generation failed");
}

test "Zopfli Huffman codes use canonical ordering before emission" {
    const lengths = [_]u32{ 2, 3, 3, 3, 3, 2, 0 };
    var codes: [lengths.len]u32 = undefined;
    try lengthsToSymbols(&lengths, 3, &codes);
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 5, 6, 7, 1, 0 }, &codes);
    try std.testing.expectError(error.InvalidLengths, lengthsToSymbols(&lengths, 2, &codes));
}

test "native Zopfli entropy matches expected zero-symbol behavior" {
    const counts = [_]usize{ 4, 4, 0, 8 };
    var entropy: [4]f64 = undefined;
    ZopfliCalculateEntropy(&counts, counts.len, &entropy);
    try std.testing.expectApproxEqAbs(@as(f64, 2), entropy[0], 0.00000000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2), entropy[1], 0.00000000001);
    try std.testing.expect(entropy[2] > 3.9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), entropy[3], 0.00000000001);
}
