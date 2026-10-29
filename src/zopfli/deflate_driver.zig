//! Native DEFLATE block orchestration and master-block splitting,
//! parameterized by release variant.
//!
//! 1.0.2 / 1.0.3 flow (ZopfliDeflatePart, commit lineage e0e937e + 70721a3):
//!     byte-coordinate greedy split -> optimal LZ77 per part into one merged
//!     store -> optional LZ77-space re-split -> per-block auto-type
//!     (stored / fixed / dynamic) emission.
//! 1.0.0 / 1.0.1 flow (DeflateSplittingFirst + DeflateDynamicBlock):
//!     byte-coordinate greedy split -> per part: optimal LZ77, and for
//!     stores below 1000 symbols an optimal fixed-tree recomparison ->
//!     emission with the chosen btype; no stored candidates, no re-split.
//! The master block size is 20,000,000 for 1.0.0/1.0.1 and 1,000,000 for
//! 1.0.2+; legacy releases emit nothing for an empty input (the upstream
//! `while (i < insize)` loop never runs).
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const splitter = @import("blocksplitter.zig");
const optimizer = @import("squeeze_optimal.zig");
const blocks = @import("deflate_blocks.zig");
const block_cost = @import("deflate_cost.zig");
const block_size = @import("deflate_block_size.zig");
const release = @import("release.zig");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;
const verbose = @import("verbose.zig");

pub export fn ZopfliDeflatePart(
    options: *const blocks.Options,
    block_type: c_int,
    final: c_int,
    input: [*]const u8,
    input_start: usize,
    input_end: usize,
    bp: *u8,
    output: *?[*]u8,
    output_size: *usize,
) callconv(.c) void {
    if (options.variant.rejectsEmptyInput()) {
        deflatePartLegacy(options, block_type, final, input, input_start, input_end, bp, output, output_size);
        return;
    }
    deflatePartModern(options, block_type, final, input, input_start, input_end, bp, output, output_size);
}

/// 1.0.2+ orchestration.
fn deflatePartModern(
    options: *const blocks.Options,
    block_type: c_int,
    final: c_int,
    input: [*]const u8,
    input_start: usize,
    input_end: usize,
    bp: *u8,
    output: *?[*]u8,
    output_size: *usize,
) void {
    if (block_type == 0) {
        blocks.addNonCompressed(options, final, input, input_start, input_end, bp, output, output_size);
        return;
    }
    if (block_type == 1) {
        var store: lz77.Store = undefined;
        lz77.ZopfliInitLZ77Store(input, &store);
        defer lz77.ZopfliCleanLZ77Store(&store);
        var state: lz77.BlockState = undefined;
        lz77.ZopfliInitBlockState(@ptrCast(options), input_start, input_end, 1, &state);
        defer lz77.ZopfliCleanBlockState(&state);
        optimizer.ZopfliLZ77OptimalFixed(&state, input, input_start, input_end, &store);
        blocks.addLZ77Block(options, block_type, final, &store, 0, store.size, 0, bp, output, output_size);
        return;
    }

    var uncompressed_points: ?[*]usize = null;
    defer if (uncompressed_points) |p| free(@ptrCast(p));
    var npoints: usize = 0;
    var points: ?[*]usize = null;
    defer if (points) |p| free(@ptrCast(p));
    if (options.blocksplitting != 0) {
        splitter.ZopfliBlockSplit(@ptrCast(options), input, input_start, input_end,
            @intCast(@max(options.blocksplittingmax, 0)), &uncompressed_points, &npoints);
        if (npoints > 0) {
            const raw = malloc(npoints * @sizeOf(usize)) orelse @panic("Zopfli block points allocation failed");
            points = @ptrCast(@alignCast(raw));
        }
    }

    var store: lz77.Store = undefined;
    lz77.ZopfliInitLZ77Store(input, &store);
    defer lz77.ZopfliCleanLZ77Store(&store);
    var total_cost: f64 = 0;
    for (0..npoints + 1) |i| {
        const start = if (i == 0) input_start else uncompressed_points.?[i - 1];
        const end = if (i == npoints) input_end else uncompressed_points.?[i];
        var state: lz77.BlockState = undefined;
        lz77.ZopfliInitBlockState(@ptrCast(options), start, end, 1, &state);
        var part: lz77.Store = undefined;
        lz77.ZopfliInitLZ77Store(input, &part);
        optimizer.ZopfliLZ77Optimal(&state, input, start, end, options.numiterations, &part);
        total_cost += block_cost.calculateBlockSizeAutoType(&part, 0, part.size, options.variant);
        lz77.ZopfliAppendLZ77Store(&part, &store);
        if (i < npoints) points.?[i] = store.size;
        lz77.ZopfliCleanBlockState(&state);
        lz77.ZopfliCleanLZ77Store(&part);
    }

    if (options.blocksplitting != 0 and npoints > 1) {
        var second: ?[*]usize = null;
        var second_count: usize = 0;
        splitter.ZopfliBlockSplitLZ77(@ptrCast(options), &store,
            @intCast(@max(options.blocksplittingmax, 0)), &second, &second_count);
        var second_cost: f64 = 0;
        for (0..second_count + 1) |i| {
            const start = if (i == 0) @as(usize, 0) else second.?[i - 1];
            const end = if (i == second_count) store.size else second.?[i];
            second_cost += block_cost.calculateBlockSizeAutoType(&store, start, end, options.variant);
        }
        if (second_cost < total_cost) {
            if (points) |p| free(@ptrCast(p));
            points = second;
            npoints = second_count;
        } else if (second) |p| {
            free(@ptrCast(p));
        }
    }

    for (0..npoints + 1) |i| {
        const start = if (i == 0) @as(usize, 0) else points.?[i - 1];
        const end = if (i == npoints) store.size else points.?[i];
        blocks.addAuto(options, @intFromBool(i == npoints and final != 0), &store,
            start, end, 0, bp, output, output_size);
    }
}

/// 1.0.0/1.0.1 orchestration (DeflateSplittingFirst; blocksplittinglast
/// is 0 in the upstream defaults so SplittingLast never triggers via CLI).
fn deflatePartLegacy(
    options: *const blocks.Options,
    block_type: c_int,
    final: c_int,
    input: [*]const u8,
    input_start: usize,
    input_end: usize,
    bp: *u8,
    output: *?[*]u8,
    output_size: *usize,
) void {
    if (block_type == 0) {
        blocks.addNonCompressed(options, final, input, input_start, input_end, bp, output, output_size);
        return;
    }

    var splitpoints: ?[*]usize = null;
    defer if (splitpoints) |p| free(@ptrCast(p));
    var npoints: usize = 0;
    if (options.blocksplitting != 0 and block_type == 2) {
        splitter.ZopfliBlockSplit(@ptrCast(options), input, input_start, input_end,
            @intCast(@max(options.blocksplittingmax, 0)), &splitpoints, &npoints);
    }
    // btype 1: "If all blocks are fixed tree, splitting into separate blocks
    // only increases the total size." npoints stays 0.

    for (0..npoints + 1) |i| {
        const start = if (i == 0) input_start else splitpoints.?[i - 1];
        const end = if (i == npoints) input_end else splitpoints.?[i];
        deflateBlockLegacy(options, block_type, @intFromBool(i == npoints and final != 0),
            input, start, end, bp, output, output_size);
    }
}

/// 1.0.0/1.0.1 DeflateBlock: dynamic blocks may switch to a fixed tree for
/// small stores; no stored-block candidate exists.
fn deflateBlockLegacy(
    options: *const blocks.Options,
    block_type: c_int,
    final: c_int,
    input: [*]const u8,
    input_start: usize,
    input_end: usize,
    bp: *u8,
    output: *?[*]u8,
    output_size: *usize,
) void {
    if (block_type == 1) {
        var fixed: lz77.Store = undefined;
        lz77.ZopfliInitLZ77Store(input, &fixed);
        defer lz77.ZopfliCleanLZ77Store(&fixed);
        var state: lz77.BlockState = undefined;
        lz77.ZopfliInitBlockState(@ptrCast(options), input_start, input_end, 1, &state);
        defer lz77.ZopfliCleanBlockState(&state);
        optimizer.ZopfliLZ77OptimalFixed(&state, input, input_start, input_end, &fixed);
        blocks.addLZ77Block(options, 1, final, &fixed, 0, fixed.size, input_end - input_start, bp, output, output_size);
        return;
    }

    std.debug.assert(block_type == 2);
    var store: lz77.Store = undefined;
    lz77.ZopfliInitLZ77Store(input, &store);
    defer lz77.ZopfliCleanLZ77Store(&store);
    var state: lz77.BlockState = undefined;
    lz77.ZopfliInitBlockState(@ptrCast(options), input_start, input_end, 1, &state);
    defer lz77.ZopfliCleanBlockState(&state);

    optimizer.ZopfliLZ77Optimal(&state, input, input_start, input_end, options.numiterations, &store);

    var chosen: *const lz77.Store = &store;
    var block_type_chosen: c_int = 2;
    var fixed_store: lz77.Store = undefined;
    var fixed_used = false;
    defer if (fixed_used) lz77.ZopfliCleanLZ77Store(&fixed_store);

    // "For small block, encoding with fixed tree can be smaller. For large
    // block, don't bother doing this expensive test, dynamic tree will be
    // better."
    if (store.size < 1000) {
        lz77.ZopfliInitLZ77Store(input, &fixed_store);
        fixed_used = true;
        optimizer.ZopfliLZ77OptimalFixed(&state, input, input_start, input_end, &fixed_store);
        const dyncost = block_size.calculateBlockSize(&store, 0, store.size, 2, options.variant);
        const fixedcost = block_size.calculateBlockSize(&fixed_store, 0, fixed_store.size, 1, options.variant);
        if (fixedcost < dyncost) {
            block_type_chosen = 1;
            chosen = &fixed_store;
        }
    }

    blocks.addLZ77Block(options, block_type_chosen, final, chosen, 0, chosen.size,
        input_end - input_start, bp, output, output_size);
}

pub export fn ZopfliDeflate(
    options: *const blocks.Options,
    block_type: c_int,
    final: c_int,
    input: [*]const u8,
    input_size: usize,
    bp: *u8,
    output: *?[*]u8,
    output_size: *usize,
) callconv(.c) void {
    const original_output_size = output_size.*;
    const master_block_size = options.variant.masterBlockSize();
    if (options.variant.rejectsEmptyInput()) {
        // 1.0.0/1.0.1: `while (i < insize)` — an empty input emits nothing.
        var i: usize = 0;
        while (i < input_size) {
            const last = i + master_block_size >= input_size;
            const final_block = final != 0 and last;
            const size = if (last) input_size - i else master_block_size;
            ZopfliDeflatePart(options, block_type, @intFromBool(final_block), input, i, i + size, bp, output, output_size);
            i += size;
        }
    } else {
        // 1.0.2+: `do { ... } while (i < insize)` — one empty part.
        var i: usize = 0;
        while (true) {
            const last = i + master_block_size >= input_size;
            const final_block = final != 0 and last;
            const size = if (last) input_size - i else master_block_size;
            ZopfliDeflatePart(options, block_type, @intFromBool(final_block), input, i, i + size, bp, output, output_size);
            i += size;
            if (i >= input_size) break;
        }
    }
    if (options.verbose != 0) {
        const compressed_size = output_size.* - original_output_size;
        const numerator: usize = input_size -% compressed_size;
        const percentage = 100.0 * @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(input_size));
        verbose.print("Original Size: {d}, Deflate: {d}, Compression: {d:.6}% Removed\n", .{ input_size, compressed_size, percentage });
    }
}

test "single empty master block still gets emitted" {
    var opts: blocks.Options = std.mem.zeroes(blocks.Options);
    opts.numiterations = 1;
    opts.variant = .v1_0_3;
    const input = [_]u8{0};
    var bp: u8 = 0;
    var output: ?[*]u8 = null;
    var size: usize = 0;
    defer if (output) |ptr| free(@ptrCast(ptr));
    ZopfliDeflate(&opts, 0, 1, &input, 0, &bp, &output, &size);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 255, 255 }, output.?[0..size]);
}

test "modern master loop processes the empty input once" {
    var opts: blocks.Options = std.mem.zeroes(blocks.Options);
    opts.numiterations = 1;
    opts.variant = .v1_0_3;
    const input = [_]u8{0};
    var bp: u8 = 0;
    var output: ?[*]u8 = null;
    var size: usize = 0;
    defer if (output) |ptr| free(@ptrCast(ptr));
    // btype 2 on an empty input: the do-while runs once, AddLZ77BlockAutoType
    // represents the smallest empty block with a fixed block: final=1,
    // btype=01, then the 7-bit end-symbol code 0000000 -> 10 bits, `03 00`.
    ZopfliDeflate(&opts, 2, 1, &input, 0, &bp, &output, &size);
    try std.testing.expect(output != null);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00 }, output.?[0..size]);
}

test "legacy master loop emits nothing for empty input" {
    var opts: blocks.Options = std.mem.zeroes(blocks.Options);
    opts.numiterations = 1;
    opts.variant = .v1_0_0;
    const input = [_]u8{0};
    var bp: u8 = 0;
    var output: ?[*]u8 = null;
    var size: usize = 0;
    defer if (output) |ptr| free(@ptrCast(ptr));
    ZopfliDeflate(&opts, 2, 1, &input, 0, &bp, &output, &size);
    try std.testing.expect(output == null);
    try std.testing.expectEqual(@as(usize, 0), size);
}
