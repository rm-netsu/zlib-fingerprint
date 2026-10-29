//! Native block serialization and automatic block selection,
//! parameterized by release variant (dynamic tree encoder differs for 1.0.0).
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const opt = @import("squeeze_optimal.zig");
const tree = @import("tree.zig");
const rle = @import("deflate_rle.zig");
const dynamic = @import("deflate_dynamic.zig");
const header = @import("deflate_tree_encode.zig");
const data_writer = @import("deflate_lz77_output.zig");
const block_cost = @import("deflate_block_size.zig");
const release = @import("release.zig");

const verbose = @import("verbose.zig");

pub const Options = release.Options;

pub fn addNonCompressed(_: *const Options, final: c_int, input: [*]const u8, start: usize, end: usize, bp: *u8, output: *?[*]u8, output_size: *usize) void {
    var pos = start;
    while (true) {
        const blocksize: u16 = @intCast(@min(@as(usize, 65535), end - pos));
        const currentfinal = pos + blocksize >= end;
        const nlen: u16 = ~blocksize;
        header.writeBits(@intFromBool(final != 0 and currentfinal), 1, false, bp, output, output_size);
        header.writeBits(0, 1, false, bp, output, output_size);
        header.writeBits(0, 1, false, bp, output, output_size);
        bp.* = 0;
        header.appendByte(output, output_size, @truncate(blocksize));
        header.appendByte(output, output_size, @truncate(blocksize >> 8));
        header.appendByte(output, output_size, @truncate(nlen));
        header.appendByte(output, output_size, @truncate(nlen >> 8));
        for (0..blocksize) |i| header.appendByte(output, output_size, input[pos + i]);
        if (currentfinal) break;
        pos += blocksize;
    }
}

pub fn addLZ77Block(options: *const Options, block_type: c_int, final: c_int, store: *const lz77.Store, start: usize, end: usize, expected_size: usize, bp: *u8, output: *?[*]u8, output_size: *usize) void {
    var ll_lengths: [288]c_uint = undefined;
    var d_lengths: [32]c_uint = undefined;
    var ll_symbols: [288]c_uint = undefined;
    var d_symbols: [32]c_uint = undefined;

    if (block_type == 0) {
        const length = lz77.ZopfliLZ77GetByteRange(store, start, end);
        const pos = if (start == end) @as(usize, 0) else store.pos.?[start];
        addNonCompressed(options, final, store.data, pos, pos + length, bp, output, output_size);
        return;
    }

    header.writeBits(@intFromBool(final != 0), 1, false, bp, output, output_size);
    header.writeBits(@intCast(block_type & 1), 1, false, bp, output, output_size);
    header.writeBits(@intCast((block_type & 2) >> 1), 1, false, bp, output, output_size);

    if (block_type == 1) {
        rle.ZfDeflateGetFixedTree(&ll_lengths, &d_lengths);
    } else {
        std.debug.assert(block_type == 2);
        _ = dynamic.getDynamicLengths(store, start, end, &ll_lengths, &d_lengths, options.variant);
        const tree_start = output_size.*;
        _ = header.addDynamicTree(options.variant, &ll_lengths, &d_lengths, bp, output, output_size);
        if (options.verbose != 0) verbose.print("treesize: {d}\n", .{output_size.* - tree_start});
    }

    tree.ZopfliLengthsToSymbols(&ll_lengths, 288, 15, &ll_symbols);
    tree.ZopfliLengthsToSymbols(&d_lengths, 32, 15, &d_symbols);
    const data_start = output_size.*;
    data_writer.ZfDeflateAddLZ77Data(store, start, end, expected_size, &ll_symbols, &ll_lengths, &d_symbols, &d_lengths, bp, output, output_size);
    header.writeBits(ll_symbols[256], ll_lengths[256], true, bp, output, output_size);
    if (options.verbose != 0) {
        var original_size: usize = 0;
        for (start..end) |i| original_size += if (store.dists.?[i] == 0) @as(usize, 1) else store.litlens.?[i];
        const bytes = output_size.* - data_start;
        verbose.print("compressed block size: {d} ({d}k) (unc: {d})\n", .{ bytes, bytes / 1024, original_size });
    }
}

pub fn addAuto(options: *const Options, final: c_int, store: *const lz77.Store, start: usize, end: usize, expected_size: usize, bp: *u8, output: *?[*]u8, output_size: *usize) void {
    // Auto-type block selection exists only in 1.0.2+; legacy releases
    // use addLegacyDynamicBlock / addLZ77Block instead.
    std.debug.assert(!options.variant.rejectsEmptyInput());
    const uncompressed = block_cost.calculateBlockSize(store, start, end, 0, options.variant);
    var fixed = block_cost.calculateBlockSize(store, start, end, 1, options.variant);
    const dynamic_cost = block_cost.calculateBlockSize(store, start, end, 2, options.variant);
    const expensivefixed = store.size < 1000 or fixed <= dynamic_cost * 1.1;

    if (start == end) {
        header.writeBits(@intFromBool(final != 0), 1, false, bp, output, output_size);
        header.writeBits(1, 2, false, bp, output, output_size);
        header.writeBits(0, 7, false, bp, output, output_size);
        return;
    }

    var fixedstore: lz77.Store = undefined;
    lz77.ZopfliInitLZ77Store(store.data, &fixedstore);
    defer lz77.ZopfliCleanLZ77Store(&fixedstore);
    if (expensivefixed) {
        const input_start = store.pos.?[start];
        const input_end = input_start + lz77.ZopfliLZ77GetByteRange(store, start, end);
        var state: lz77.BlockState = undefined;
        lz77.ZopfliInitBlockState(@ptrCast(options), input_start, input_end, 1, &state);
        defer lz77.ZopfliCleanBlockState(&state);
        opt.ZopfliLZ77OptimalFixed(&state, store.data, input_start, input_end, &fixedstore);
        fixed = block_cost.ZopfliCalculateBlockSize(&fixedstore, 0, fixedstore.size, 1);
    }

    if (uncompressed < fixed and uncompressed < dynamic_cost) {
        addLZ77Block(options, 0, final, store, start, end, expected_size, bp, output, output_size);
    } else if (fixed < dynamic_cost) {
        if (expensivefixed) {
            addLZ77Block(options, 1, final, &fixedstore, 0, fixedstore.size, expected_size, bp, output, output_size);
        } else {
            addLZ77Block(options, 1, final, store, start, end, expected_size, bp, output, output_size);
        }
    } else {
        addLZ77Block(options, 2, final, store, start, end, expected_size, bp, output, output_size);
    }
}

test "stored block emits LEN/NLEN and empty final header" {
    const input = [_]u8{0};
    var options: Options = std.mem.zeroes(Options);
    var bp: u8 = 0;
    var output: ?[*]u8 = null;
    var size: usize = 0;
    defer if (output) |ptr| std.c.free(@ptrCast(ptr));
    addNonCompressed(&options, 1, &input, 0, 0, &bp, &output, &size);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 255, 255 }, output.?[0..size]);
}
