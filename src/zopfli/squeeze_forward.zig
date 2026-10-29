//! Bit-compatible forward dynamic programming pass from Zopfli.
//! `legacy_pruning` reproduces the 1.0.0/1.0.1 pruning expression
//! (`costs[j+k] - costs[j] <= mincost`, float subtraction) instead of the
//! 1.0.2+ form (`costs[j+k] <= mincost + costs[j]`).
const std = @import("std");
const state_mod = @import("lz77_store.zig");
const hash_mod = @import("hash.zig");
const match_mod = @import("lz77_match.zig");
const costs_mod = @import("squeeze_stats.zig");

pub fn ZfSqueezeGetBestLengths(
    state: *state_mod.BlockState,
    input: [*]const u8,
    start: usize,
    end: usize,
    model: costs_mod.CostModel,
    context: ?*anyopaque,
    lengths: [*]u16,
    hash: *hash_mod.Hash,
    costs: [*]f32,
    legacy_pruning: bool,
) f64 {
    const blocksize = end - start;
    const mincost = costs_mod.ZfSqueezeGetCostModelMinCost(model, context);
    if (start == end) return 0;

    const windowstart = start -| hash_mod.window_size;
    hash_mod.ZopfliResetHash(hash_mod.window_size, hash);
    hash_mod.ZopfliWarmupHash(input, windowstart, end, hash);
    for (windowstart..start) |pos| hash_mod.ZopfliUpdateHash(input, pos, end, hash);

    for (1..blocksize + 1) |index| costs[index] = 1e30;
    costs[0] = 0;
    lengths[0] = 0;

    var pos = start;
    while (pos < end) : (pos += 1) {
        var j = pos - start;
        hash_mod.ZopfliUpdateHash(input, pos, end, hash);

        // ZOPFLI_SHORTCUT_LONG_REPETITIONS is enabled in upstream util.h.
        // This loop deliberately modifies pos and j before the match search.
        {
            if (hash.same[pos & (hash_mod.window_size - 1)] > 516 and
                pos > start + 259 and pos + 517 < end and
                hash.same[(pos - 258) & (hash_mod.window_size - 1)] > 258)
            {
                const symbolcost = model(258, 1, context);
                for (0..258) |_| {
                    costs[j + 258] = @floatCast(@as(f64, costs[j]) + symbolcost);
                    lengths[j + 258] = 258;
                    pos += 1;
                    j += 1;
                    hash_mod.ZopfliUpdateHash(input, pos, end, hash);
                }
            }
        }

        var sublen: [259]u16 = undefined;
        var distance: u16 = undefined;
        var length: u16 = undefined;
        match_mod.ZopfliFindLongestMatch(state, hash, input, pos, end, 258, &sublen, &distance, &length);

        const literal_cost = model(input[pos], 0, context) + @as(f64, costs[j]);
        std.debug.assert(literal_cost >= 0);
        if (literal_cost < @as(f64, costs[j + 1])) {
            costs[j + 1] = @floatCast(literal_cost);
            lengths[j + 1] = 1;
        }

        const max_length = @min(@as(usize, length), end - pos);
        const mincost_plus_j = mincost + @as(f64, costs[j]);
        if (max_length >= 3) {
            for (3..max_length + 1) |k| {
                if (legacy_pruning) {
                    // 1.0.0/1.0.1: float subtraction, compared to mincost.
                    if (@as(f64, costs[j + k] - costs[j]) <= mincost) continue;
                } else {
                    // 1.0.2+: addition in double, avoids the subtraction.
                    if (@as(f64, costs[j + k]) <= mincost_plus_j) continue;
                }
                const candidate = model(@intCast(k), sublen[k], context) + @as(f64, costs[j]);
                std.debug.assert(candidate >= 0);
                if (candidate < @as(f64, costs[j + k])) {
                    costs[j + k] = @floatCast(candidate);
                    lengths[j + k] = @intCast(k);
                }
            }
        }
    }

    std.debug.assert(costs[blocksize] >= 0);
    return costs[blocksize];
}
