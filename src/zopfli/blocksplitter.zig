//! Native block boundary optimizer, parameterized by release variant.
//! 1.0.2+ costs candidate splits with the auto-type block cost; 1.0.0/1.0.1
//! always cost them as dynamic (btype 2) blocks.
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const hash_mod = @import("hash.zig");
const greedy = @import("lz77_greedy.zig");
const block_cost = @import("deflate_cost.zig");
const release = @import("release.zig");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn realloc(?*anyopaque, usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;
const verbose = @import("verbose.zig");

pub const Options = release.Options;

fn append(values: *?[*]usize, count: *usize, value: usize) void {
    const index = count.*;
    if ((index & (index -% 1)) == 0) {
        const capacity = if (index == 0) @as(usize, 1) else index * 2;
        const old: ?*anyopaque = if (values.*) |p| @ptrCast(p) else null;
        const memory = if (index == 0) malloc(@sizeOf(usize)) else realloc(old, capacity * @sizeOf(usize));
        values.* = @ptrCast(@alignCast(memory orelse @panic("block split allocation failed")));
    }
    values.*.?[index] = value;
    count.* = index + 1;
}

fn addSorted(value: usize, points: *?[*]usize, count: *usize) void {
    append(points, count, value);
    for (0..count.* - 1) |i| {
        if (points.*.?[i] > value) {
            var j = count.* - 1;
            while (j > i) : (j -= 1) points.*.?[j] = points.*.?[j - 1];
            points.*.?[i] = value;
            break;
        }
    }
}

const SplitCostContext = struct {
    store: *const lz77.Store,
    start: usize,
    end: usize,
    variant: release.ZopfliRelease,
};

fn splitCost(index: usize, context: SplitCostContext) f64 {
    if (context.variant.rejectsEmptyInput()) {
        // 1.0.0/1.0.1: EstimateCost always uses btype 2 (dynamic).
        return block_size_dynamic(context.store, context.start, index, context.variant) +
            block_size_dynamic(context.store, index, context.end, context.variant);
    }
    return block_cost.calculateBlockSizeAutoType(context.store, context.start, index, context.variant) +
        block_cost.calculateBlockSizeAutoType(context.store, index, context.end, context.variant);
}

/// Dynamic (btype 2) block cost, used verbatim by the 1.0.0/1.0.1
/// blocksplitter instead of the auto-type cost.
fn block_size_dynamic(store: *const lz77.Store, start: usize, end: usize, variant: release.ZopfliRelease) f64 {
    const block_size = @import("deflate_block_size.zig");
    return block_size.calculateBlockSize(store, start, end, 2, variant);
}

fn findMinimum(context: SplitCostContext, lower: usize, upper: usize, smallest: *f64) usize {
    if (upper - lower < 1024) {
        var best: f64 = 1e30;
        var position = lower;
        for (lower..upper) |index| {
            const value = splitCost(index, context);
            if (value < best) {
                best = value;
                position = index;
            }
        }
        smallest.* = best;
        return position;
    }

    var start = lower;
    var end = upper;
    var lastbest: f64 = 1e30;
    var position = start;
    while (end - start > 9) {
        var points: [9]usize = undefined;
        var values: [9]f64 = undefined;
        for (0..9) |i| {
            points[i] = start + (i + 1) * ((end - start) / 10);
            values[i] = splitCost(points[i], context);
        }
        var best_index: usize = 0;
        var best = values[0];
        for (1..9) |i| {
            if (values[i] < best) {
                best = values[i];
                best_index = i;
            }
        }
        if (best > lastbest) break;
        start = if (best_index == 0) start else points[best_index - 1];
        end = if (best_index == 8) end else points[best_index + 1];
        position = points[best_index];
        lastbest = best;
    }
    smallest.* = lastbest;
    return position;
}

fn findLargest(size: usize, done: []const u8, points: ?[*]usize, count: usize, start: *usize, end: *usize) bool {
    var longest: usize = 0;
    var found = false;
    for (0..count + 1) |index| {
        const a = if (index == 0) @as(usize, 0) else points.?[index - 1];
        const b = if (index == count) size - 1 else points.?[index];
        if (done[a] == 0 and b - a > longest) {
            start.* = a;
            end.* = b;
            longest = b - a;
            found = true;
        }
    }
    return found;
}

fn printPoints(store: *const lz77.Store, points: ?[*]usize, count: usize) void {
    var positions: ?[*]usize = null;
    defer if (positions) |p| free(@ptrCast(p));
    var found: usize = 0;
    var pos: usize = 0;
    if (count > 0) {
        for (0..store.size) |i| {
            const length: usize = if (store.dists.?[i] == 0) 1 else store.litlens.?[i];
            if (points.?[found] == i) {
                append(&positions, &found, pos);
                if (found == count) break;
            }
            pos += length;
        }
    }
    std.debug.assert(found == count);
    verbose.writeAll("block split points: ");
    for (0..found) |i| verbose.print("{d} ", .{positions.?[i]});
    verbose.writeAll("(hex:");
    for (0..found) |i| verbose.print(" {x}", .{positions.?[i]});
    verbose.writeAll(")\n");
}

pub export fn ZopfliBlockSplitLZ77(options: *const Options, store: *const lz77.Store, maxblocks: usize, points: *?[*]usize, count: *usize) callconv(.c) void {
    if (store.size < 10) return;
    const memory = malloc(store.size) orelse @panic("block split done allocation failed");
    defer free(memory);
    const done: [*]u8 = @ptrCast(memory);
    @memset(done[0..store.size], 0);

    var start: usize = 0;
    var end: usize = store.size;
    var blocks: usize = 1;
    while (true) {
        if (maxblocks > 0 and blocks >= maxblocks) break;
        std.debug.assert(start < end);
        const context = SplitCostContext{ .store = store, .start = start, .end = end, .variant = options.variant };
        var divided_cost: f64 = undefined;
        const position = findMinimum(context, start + 1, end, &divided_cost);
        std.debug.assert(position > start and position < end);
        const original_cost = if (options.variant.rejectsEmptyInput())
            block_size_dynamic(store, start, end, options.variant)
        else
            block_cost.calculateBlockSizeAutoType(store, start, end, options.variant);
        if (divided_cost > original_cost or position == start + 1 or position == end) {
            done[start] = 1;
        } else {
            addSorted(position, points, count);
            blocks += 1;
        }
        if (!findLargest(store.size, done[0..store.size], points.*, count.*, &start, &end)) break;
        if (end - start < 10) break;
    }
    if (options.verbose != 0) printPoints(store, points.*, count.*);
}

pub export fn ZopfliBlockSplit(options: *const Options, input: [*]const u8, start: usize, end: usize, maxblocks: usize, points: *?[*]usize, count: *usize) callconv(.c) void {
    var store: lz77.Store = undefined;
    lz77.ZopfliInitLZ77Store(input, &store);
    defer lz77.ZopfliCleanLZ77Store(&store);
    var state: lz77.BlockState = undefined;
    lz77.ZopfliInitBlockState(@ptrCast(options), start, end, 0, &state);
    defer lz77.ZopfliCleanBlockState(&state);
    var hash: hash_mod.Hash = undefined;
    hash_mod.ZopfliAllocHash(hash_mod.window_size, &hash);
    defer hash_mod.ZopfliCleanHash(&hash);
    count.* = 0;
    points.* = null;
    greedy.ZopfliLZ77Greedy(&state, input, start, end, &store, &hash);

    var lz_points: ?[*]usize = null;
    defer if (lz_points) |p| free(@ptrCast(p));
    var lz_count: usize = 0;
    ZopfliBlockSplitLZ77(options, &store, maxblocks, &lz_points, &lz_count);
    var pos = start;
    if (lz_count > 0) {
        for (0..store.size) |i| {
            const length: usize = if (store.dists.?[i] == 0) 1 else store.litlens.?[i];
            if (lz_points.?[count.*] == i) {
                append(points, count, pos);
                if (count.* == lz_count) break;
            }
            pos += length;
        }
    }
    std.debug.assert(count.* == lz_count);
}

pub export fn ZopfliBlockSplitSimple(_: [*]const u8, start: usize, end: usize, blocksize: usize, points: *?[*]usize, count: *usize) callconv(.c) void {
    var position = start;
    while (position < end) : (position += blocksize) append(points, count, position);
}

test "sorted split boundaries preserve upstream stable insertion ordering" {
    var points: ?[*]usize = null;
    defer if (points) |p| free(@ptrCast(p));
    var count: usize = 0;
    addSorted(12, &points, &count);
    addSorted(3, &points, &count);
    addSorted(9, &points, &count);
    try std.testing.expectEqualSlices(usize, &.{ 3, 9, 12 }, points.?[0..count]);
}
