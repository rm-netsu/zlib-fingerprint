//! Native Zopfli 1.0.3 squeeze symbol statistics, deterministic frequency
//! perturbation and entropy calculation. Compatible with C SymbolStats.
const std = @import("std");
const lz77 = @import("lz77_store.zig");
const tree = @import("tree.zig");

const num_ll = 288;
const num_d = 32;

pub const Stats = extern struct {
    litlens: [num_ll]usize,
    dists: [num_d]usize,
    ll_symbols: [num_ll]f64,
    d_symbols: [num_d]f64,
};

pub const RanState = extern struct {
    m_w: c_uint,
    m_z: c_uint,
};

pub export fn ZfSqueezeInitStats(stats: *Stats) callconv(.c) void {
    @memset(&stats.litlens, 0);
    @memset(&stats.dists, 0);
    @memset(&stats.ll_symbols, 0);
    @memset(&stats.d_symbols, 0);
}

pub export fn ZfSqueezeCopyStats(source: *const Stats, dest: *Stats) callconv(.c) void {
    dest.* = source.*;
}

pub export fn ZfSqueezeAddWeighedStatFreqs(first: *const Stats, w1: f64, second: *const Stats, w2: f64, result: *Stats) callconv(.c) void {
    for (0..num_ll) |i| {
        result.litlens[i] = @intFromFloat(@as(f64, @floatFromInt(first.litlens[i])) * w1 + @as(f64, @floatFromInt(second.litlens[i])) * w2);
    }
    for (0..num_d) |i| {
        result.dists[i] = @intFromFloat(@as(f64, @floatFromInt(first.dists[i])) * w1 + @as(f64, @floatFromInt(second.dists[i])) * w2);
    }
    result.litlens[256] = 1;
}

pub export fn ZfSqueezeInitRanState(state: *RanState) callconv(.c) void {
    state.* = .{ .m_w = 1, .m_z = 2 };
}

fn ran(state: *RanState) c_uint {
    state.m_z = 36969 *% (state.m_z & 65535) +% (state.m_z >> 16);
    state.m_w = 18000 *% (state.m_w & 65535) +% (state.m_w >> 16);
    return (state.m_z << 16) +% state.m_w;
}

fn randomize(state: *RanState, freqs: []usize) void {
    for (freqs) |*freq| {
        if (((ran(state) >> 4) % 3) == 0) {
            freq.* = freqs[ran(state) % @as(u32, @intCast(freqs.len))];
        }
    }
}

pub export fn ZfSqueezeRandomizeStatFreqs(state: *RanState, stats: *Stats) callconv(.c) void {
    randomize(state, &stats.litlens);
    randomize(state, &stats.dists);
    stats.litlens[256] = 1;
}

pub export fn ZfSqueezeClearStatFreqs(stats: *Stats) callconv(.c) void {
    @memset(&stats.litlens, 0);
    @memset(&stats.dists, 0);
}

pub export fn ZfSqueezeCalculateStatistics(stats: *Stats) callconv(.c) void {
    tree.ZopfliCalculateEntropy(&stats.litlens, num_ll, &stats.ll_symbols);
    tree.ZopfliCalculateEntropy(&stats.dists, num_d, &stats.d_symbols);
}

pub export fn ZfSqueezeGetStatistics(store: *const lz77.Store, stats: *Stats) callconv(.c) void {
    for (0..store.size) |i| {
        if (store.dists.?[i] == 0) {
            stats.litlens[store.litlens.?[i]] += 1;
        } else {
            stats.litlens[store.ll_symbol.?[i]] += 1;
            stats.dists[store.d_symbol.?[i]] += 1;
        }
    }
    stats.litlens[256] = 1;
    ZfSqueezeCalculateStatistics(stats);
}

fn lengthExtraBits(length: u16) u16 {
    const symbol = lz77.lengthSymbol(length);
    return if (symbol <= 264 or symbol == 285) 0 else @intCast((symbol - 261) / 4);
}

fn distanceExtraBits(distance: u16) u16 {
    const symbol = lz77.distanceSymbol(distance);
    return if (symbol < 4) 0 else @intCast(symbol / 2 - 1);
}

pub export fn ZfSqueezeGetCostFixed(litlen: c_uint, dist: c_uint, unused: ?*anyopaque) callconv(.c) f64 {
    _ = unused;
    if (dist == 0) return if (litlen <= 143) 8 else 9;
    const length: u16 = @intCast(litlen);
    const distance: u16 = @intCast(dist);
    const symbol = lz77.lengthSymbol(length);
    const bits: u16 = (if (symbol <= 279) @as(u16, 7) else 8) + 5 +
        distanceExtraBits(distance) + lengthExtraBits(length);
    return @floatFromInt(bits);
}

pub export fn ZfSqueezeGetCostStat(litlen: c_uint, dist: c_uint, context: ?*anyopaque) callconv(.c) f64 {
    const stats: *const Stats = @ptrCast(@alignCast(context orelse @panic("Zopfli statistics context missing")));
    if (dist == 0) return stats.ll_symbols[litlen];
    const length: u16 = @intCast(litlen);
    const distance: u16 = @intCast(dist);
    const lbits = lengthExtraBits(length);
    const dbits = distanceExtraBits(distance);
    const lsym = lz77.lengthSymbol(length);
    const dsym = lz77.distanceSymbol(distance);
    return @as(f64, @floatFromInt(lbits + dbits)) + stats.ll_symbols[lsym] + stats.d_symbols[dsym];
}

pub const CostModel = *const fn (c_uint, c_uint, ?*anyopaque) callconv(.c) f64;

// Keep the two independent scans and strict comparisons of squeeze.c: the
// selected length and distance must match upstream even on cost ties.
pub export fn ZfSqueezeGetCostModelMinCost(model: CostModel, context: ?*anyopaque) callconv(.c) f64 {
    const distance_symbols = [_]c_uint{
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    };
    var best_length: c_uint = 0;
    var best_distance: c_uint = 0;
    var minimum: f64 = 1e30;
    for (3..259) |length| {
        const cost = model(@intCast(length), 1, context);
        if (cost < minimum) {
            best_length = @intCast(length);
            minimum = cost;
        }
    }
    minimum = 1e30;
    for (distance_symbols) |distance| {
        const cost = model(3, distance, context);
        if (cost < minimum) {
            best_distance = distance;
            minimum = cost;
        }
    }
    return model(best_length, best_distance, context);
}

test "minimum squeeze token cost probes every length and distinct distance symbol" {
    const Model = struct {
        fn cost(length: c_uint, distance: c_uint, context: ?*anyopaque) callconv(.c) f64 {
            _ = context;
            return @as(f64, @floatFromInt(if (length == 258) @as(c_uint, 0) else 1)) +
                @as(f64, @floatFromInt(if (distance == 24577) @as(c_uint, 0) else 2));
        }
    };
    try std.testing.expectEqual(@as(f64, 0), ZfSqueezeGetCostModelMinCost(Model.cost, null));
}

test "squeeze stats have C ABI layout and deterministic Marsaglia sequence" {
    try std.testing.expectEqual(@as(usize, 5120), @sizeOf(Stats));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(RanState));
    var ran_state: RanState = undefined;
    ZfSqueezeInitRanState(&ran_state);
    const first = ran(&ran_state);
    ZfSqueezeInitRanState(&ran_state);
    try std.testing.expectEqual(first, ran(&ran_state));
    try std.testing.expect(first != 0);
}

test "squeeze stats weighted blending preserves end symbol and frequencies" {
    var a: Stats = undefined;
    var b: Stats = undefined;
    ZfSqueezeInitStats(&a);
    ZfSqueezeInitStats(&b);
    a.litlens[97] = 13;
    b.litlens[97] = 9;
    b.dists[3] = 5;
    ZfSqueezeAddWeighedStatFreqs(&a, 1.0, &b, 0.5, &a);
    try std.testing.expectEqual(@as(usize, 17), a.litlens[97]);
    try std.testing.expectEqual(@as(usize, 2), a.dists[3]);
    try std.testing.expectEqual(@as(usize, 1), a.litlens[256]);
}

test "fixed and statistical DEFLATE token costs honor length boundaries" {
    try std.testing.expectEqual(@as(f64, 8), ZfSqueezeGetCostFixed(143, 0, null));
    try std.testing.expectEqual(@as(f64, 9), ZfSqueezeGetCostFixed(144, 0, null));
    try std.testing.expectEqual(@as(f64, 12), ZfSqueezeGetCostFixed(3, 1, null));
    try std.testing.expectEqual(@as(f64, 13), ZfSqueezeGetCostFixed(3, 5, null));
    try std.testing.expectEqual(@as(f64, 13), ZfSqueezeGetCostFixed(258, 1, null));
    var stats: Stats = undefined;
    ZfSqueezeInitStats(&stats);
    stats.ll_symbols[257] = 6.5;
    stats.d_symbols[0] = 2.25;
    try std.testing.expectEqual(@as(f64, 8.75), ZfSqueezeGetCostStat(3, 1, @ptrCast(&stats)));
}
