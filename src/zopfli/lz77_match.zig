//! Native Zig port of Zopfli 1.0.3 longest-match search, including rolling
//! hash chains, repeated-byte shortcuts and the longest-match cache.
const std = @import("std");
const state_mod = @import("lz77_store.zig");
const hash_mod = @import("hash.zig");
const cache_mod = @import("cache.zig");

const window = hash_mod.window_size;
const mask = window - 1;
const min_match = 3;
const max_match = 258;
const max_chain_hits = 8192;

pub export fn ZopfliVerifyLenDist(data: [*]const u8, datasize: usize, pos: usize, dist: u16, length: u16) callconv(.c) void {
    std.debug.assert(pos + length <= datasize);
    for (0..length) |i| {
        std.debug.assert(data[pos - dist + i] == data[pos + i]);
    }
}

fn tryCache(state: *state_mod.BlockState, pos: usize, limit: *usize, sublen: ?[*]u16, distance: *u16, length: *u16) bool {
    const lmc = state.lmc orelse return false;
    const index = pos - state.blockstart;
    const cached_length: u16 = lmc.length[index];
    const available = cached_length == 0 or lmc.dist[index] != 0;
    if (!available) return false;
    const sufficient = limit.* == max_match or cached_length <= limit.* or
        (sublen != null and cache_mod.ZopfliMaxCachedSublen(lmc, index, cached_length) >= limit.*);
    if (!sufficient) return false;

    if (sublen == null or cached_length <= cache_mod.ZopfliMaxCachedSublen(lmc, index, cached_length)) {
        length.* = @intCast(@min(cached_length, limit.*));
        if (sublen) |values| {
            cache_mod.ZopfliCacheToSublen(lmc, index, length.*, values);
            // The upstream C implementation reads an uninitialised sublen[0]
            // for cached no-match entries. Its value is irrelevant at length 0.
            distance.* = if (length.* == 0) 0 else values[length.*];
            if (limit.* == max_match and length.* >= min_match) {
                std.debug.assert(distance.* == lmc.dist[index]);
            }
        } else {
            distance.* = lmc.dist[index];
        }
        return true;
    }
    // The cached maximum still limits subsequent chain traversal.
    limit.* = cached_length;
    return false;
}

fn storeCache(state: *state_mod.BlockState, pos: usize, limit: usize, sublen: ?[*]u16, distance: u16, length: u16) void {
    const lmc = state.lmc orelse return;
    const index = pos - state.blockstart;
    const available = lmc.length[index] == 0 or lmc.dist[index] != 0;
    if (limit != max_match or sublen == null or available) return;
    std.debug.assert(lmc.length[index] == 1 and lmc.dist[index] == 0);
    lmc.dist[index] = if (length < min_match) 0 else distance;
    lmc.length[index] = if (length < min_match) 0 else length;
    cache_mod.ZopfliSublenToCache(sublen.?, index, length, lmc);
}

fn equalRun(bytes: [*]const u8, scan_start: usize, match_start: usize, end: usize) usize {
    var scan = scan_start;
    var match = match_start;
    // Mirrors the original 64-bit GetMatch fast path. Equality of the eight
    // bytes is independent of host endian and alignment.
    while (scan + 8 < end and std.mem.eql(u8, bytes[scan .. scan + 8], bytes[match .. match + 8])) {
        scan += 8;
        match += 8;
    }
    while (scan < end and bytes[scan] == bytes[match]) {
        scan += 1;
        match += 1;
    }
    return scan;
}

pub export fn ZopfliFindLongestMatch(
    state: *state_mod.BlockState,
    hash: *const hash_mod.Hash,
    bytes: [*]const u8,
    pos: usize,
    size: usize,
    original_limit: usize,
    sublen: ?[*]u16,
    distance: *u16,
    length: *u16,
) callconv(.c) void {
    var limit = original_limit;
    if (tryCache(state, pos, &limit, sublen, distance, length)) {
        std.debug.assert(pos + length.* <= size);
        return;
    }

    std.debug.assert(limit >= min_match and limit <= max_match);
    std.debug.assert(pos < size);
    if (size - pos < min_match) {
        distance.* = 0;
        length.* = 0;
        return;
    }

    limit = @min(limit, size - pos);
    const end = pos + limit;
    const hpos: usize = pos & mask;
    var bestdist: u16 = 0;
    var bestlength: u16 = 1;
    var chain_counter: usize = max_chain_hits;
    var use_secondary_hash = false;
    var head = hash.head;
    var prev = hash.prev;
    var hashval = hash.hashval;
    var value = hash.val;

    const pp_initial: usize = @intCast(head[@intCast(value)]);
    var pp = pp_initial;
    var p: usize = prev[pp];
    std.debug.assert(pp == hpos);
    var dist: usize = if (p < pp) pp - p else window - p + pp;

    while (dist < window) {
        var currentlength: u16 = 0;
        std.debug.assert(p < window and p == prev[pp] and hashval[p] == value);
        if (dist > 0) {
            std.debug.assert(dist <= pos);
            if (pos + bestlength >= size or bytes[pos + bestlength] == bytes[pos - dist + bestlength]) {
                var scan = pos;
                var matched = pos - dist;
                const same0: u16 = hash.same[hpos];
                if (same0 > 2 and bytes[scan] == bytes[matched]) {
                    const same1: u16 = hash.same[(pos - dist) & mask];
                    const same: usize = @min(@min(same0, same1), @as(u16, @intCast(limit)));
                    scan += same;
                    matched += same;
                }
                currentlength = @intCast(equalRun(bytes, scan, matched, end) - pos);
            }
            if (currentlength > bestlength) {
                if (sublen) |values| {
                    for (@as(usize, bestlength) + 1..@as(usize, currentlength) + 1) |j| {
                        values[j] = @intCast(dist);
                    }
                }
                bestdist = @intCast(dist);
                bestlength = currentlength;
                if (currentlength >= limit) break;
            }
        }

        if (!use_secondary_hash and bestlength >= hash.same[hpos] and hash.val2 == hash.hashval2[p]) {
            use_secondary_hash = true;
            head = hash.head2;
            prev = hash.prev2;
            hashval = hash.hashval2;
            value = hash.val2;
        }

        pp = p;
        p = prev[p];
        if (p == pp) break;
        dist += if (p < pp) pp - p else window - p + pp;
        chain_counter -= 1;
        if (chain_counter == 0) break;
    }

    storeCache(state, pos, limit, sublen, bestdist, bestlength);
    std.debug.assert(bestlength <= limit);
    distance.* = bestdist;
    length.* = bestlength;
    std.debug.assert(pos + length.* <= size);
}

test "longest match probes empty hash chain and returns no distance" {
    var hash: hash_mod.Hash = undefined;
    hash_mod.ZopfliAllocHash(window, &hash);
    defer hash_mod.ZopfliCleanHash(&hash);
    hash_mod.ZopfliResetHash(window, &hash);
    const bytes = "abcdefg";
    hash_mod.ZopfliWarmupHash(bytes.ptr, 0, bytes.len, &hash);
    hash_mod.ZopfliUpdateHash(bytes.ptr, 0, bytes.len, &hash);
    var state: state_mod.BlockState = undefined;
    state_mod.ZopfliInitBlockState(null, 0, bytes.len, 1, &state);
    defer state_mod.ZopfliCleanBlockState(&state);
    var sublen = [_]u16{0} ** 259;
    var distance: u16 = 123;
    var length: u16 = 123;
    ZopfliFindLongestMatch(&state, &hash, bytes.ptr, 0, bytes.len, 258, &sublen, &distance, &length);
    try std.testing.expectEqual(@as(u16, 0), distance);
    try std.testing.expectEqual(@as(u16, 1), length);
}
