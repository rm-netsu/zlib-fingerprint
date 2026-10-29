//! Native Zig port of the iterative and fixed-tree LZ77 optimizer,
//! parameterized by release variant (iteration cost model + forward pruning).
const std = @import("std");
const store_mod = @import("lz77_store.zig");
const hash_mod = @import("hash.zig");
const greedy = @import("lz77_greedy.zig");
const forward = @import("squeeze_forward.zig");
const path_mod = @import("squeeze_path.zig");
const stats_mod = @import("squeeze_stats.zig");
const block_size = @import("deflate_block_size.zig");
const release = @import("release.zig");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;
const verbose = @import("verbose.zig");

fn releaseOf(state: *const store_mod.BlockState) release.ZopfliRelease {
    const options: *const release.Options = @ptrCast(@alignCast(state.options orelse @panic("missing Zopfli options")));
    return options.variant;
}

fn alloc(comptime T: type, count: usize) [*]T {
    const memory = malloc(count * @sizeOf(T)) orelse @panic("Zopfli squeeze allocation failed");
    return @ptrCast(@alignCast(memory));
}

fn oneRun(
    state: *store_mod.BlockState,
    input: [*]const u8,
    start: usize,
    end: usize,
    path: *?[*]u16,
    pathsize: *usize,
    lengths: [*]u16,
    model: stats_mod.CostModel,
    context: ?*anyopaque,
    store: *store_mod.Store,
    hash: *hash_mod.Hash,
    costs: [*]f32,
    legacy_pruning: bool,
) f64 {
    const cost = forward.ZfSqueezeGetBestLengths(state, input, start, end, model, context, lengths, hash, costs, legacy_pruning);
    if (path.*) |p| free(@ptrCast(p));
    path.* = null;
    pathsize.* = 0;
    path_mod.ZfSqueezeTraceBackwards(end - start, lengths, path, pathsize);
    path_mod.ZfSqueezeFollowPath(state, input, start, end, path.* orelse lengths, pathsize.*, store, hash);
    std.debug.assert(cost < 1e30);
    return cost;
}

pub export fn ZopfliLZ77Optimal(
    state: *store_mod.BlockState,
    input: [*]const u8,
    start: usize,
    end: usize,
    iterations: c_int,
    output: *store_mod.Store,
) callconv(.c) void {
    const count = end - start + 1;
    const lengths = alloc(u16, count);
    defer free(@ptrCast(lengths));
    const costs = alloc(f32, count);
    defer free(@ptrCast(costs));
    var path: ?[*]u16 = null;
    defer if (path) |p| free(@ptrCast(p));
    var pathsize: usize = 0;
    var current: store_mod.Store = undefined;
    store_mod.ZopfliInitLZ77Store(input, &current);
    defer store_mod.ZopfliCleanLZ77Store(&current);
    var hash: hash_mod.Hash = undefined;
    hash_mod.ZopfliAllocHash(hash_mod.window_size, &hash);
    defer hash_mod.ZopfliCleanHash(&hash);

    var stats: stats_mod.Stats = undefined;
    var beststats: stats_mod.Stats = undefined;
    var laststats: stats_mod.Stats = undefined;
    var rng: stats_mod.RanState = undefined;
    stats_mod.ZfSqueezeInitRanState(&rng);
    stats_mod.ZfSqueezeInitStats(&stats);
    greedy.ZopfliLZ77Greedy(state, input, start, end, &current, &hash);
    stats_mod.ZfSqueezeGetStatistics(&current, &stats);

    const variant = releaseOf(state);
    const legacy_pruning = variant.rejectsEmptyInput();

    var bestcost: f64 = 1e30;
    var lastcost: f64 = 0;
    var lastrandomstep: c_int = -1;
    var iteration: c_int = 0;
    while (iteration < iterations) : (iteration += 1) {
        store_mod.ZopfliCleanLZ77Store(&current);
        store_mod.ZopfliInitLZ77Store(input, &current);
        _ = oneRun(state, input, start, end, &path, &pathsize, lengths,
            stats_mod.ZfSqueezeGetCostStat, @ptrCast(&stats), &current, &hash, costs, legacy_pruning);
        const cost = block_size.calculateBlockSize(&current, 0, current.size, 2, variant);
        const options: *const release.Options = @ptrCast(@alignCast(state.options orelse @panic("missing Zopfli options")));
        if (options.verbose_more != 0 or (options.verbose != 0 and cost < bestcost)) {
            verbose.print("Iteration {d}: {d} bit\n", .{ iteration, @as(i64, @intFromFloat(cost)) });
        }
        if (cost < bestcost) {
            store_mod.ZopfliCopyLZ77Store(&current, output);
            stats_mod.ZfSqueezeCopyStats(&stats, &beststats);
            bestcost = cost;
        }
        stats_mod.ZfSqueezeCopyStats(&stats, &laststats);
        stats_mod.ZfSqueezeClearStatFreqs(&stats);
        stats_mod.ZfSqueezeGetStatistics(&current, &stats);
        if (lastrandomstep != -1) {
            stats_mod.ZfSqueezeAddWeighedStatFreqs(&stats, 1, &laststats, 0.5, &stats);
            stats_mod.ZfSqueezeCalculateStatistics(&stats);
        }
        if (iteration > 5 and cost == lastcost) {
            stats_mod.ZfSqueezeCopyStats(&beststats, &stats);
            stats_mod.ZfSqueezeRandomizeStatFreqs(&rng, &stats);
            stats_mod.ZfSqueezeCalculateStatistics(&stats);
            lastrandomstep = iteration;
        }
        lastcost = cost;
    }
}

pub export fn ZopfliLZ77OptimalFixed(
    state: *store_mod.BlockState,
    input: [*]const u8,
    start: usize,
    end: usize,
    store: *store_mod.Store,
) callconv(.c) void {
    const count = end - start + 1;
    const lengths = alloc(u16, count);
    defer free(@ptrCast(lengths));
    const costs = alloc(f32, count);
    defer free(@ptrCast(costs));
    var path: ?[*]u16 = null;
    defer if (path) |p| free(@ptrCast(p));
    var pathsize: usize = 0;
    var hash: hash_mod.Hash = undefined;
    hash_mod.ZopfliAllocHash(hash_mod.window_size, &hash);
    defer hash_mod.ZopfliCleanHash(&hash);
    state.blockstart = start;
    state.blockend = end;
    _ = oneRun(state, input, start, end, &path, &pathsize, lengths,
        stats_mod.ZfSqueezeGetCostFixed, null, store, &hash, costs, false);
}
