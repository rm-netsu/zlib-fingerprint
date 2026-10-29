//! Native Zig port of Zopfli 1.0.3 greedy LZ77, including lazy matching.
//! Uses the still-C longest-match oracle until its own native port is ready.
const std = @import("std");
const store_module = @import("lz77_store.zig");
const hash_module = @import("hash.zig");

extern "c" fn ZopfliFindLongestMatch(
    state: *store_module.BlockState,
    hash: *const hash_module.Hash,
    bytes: [*]const u8,
    position: usize,
    size: usize,
    limit: usize,
    sublen: [*]u16,
    distance: *u16,
    length: *u16,
) callconv(.c) void;

extern "c" fn ZopfliVerifyLenDist(
    data: [*]const u8,
    datasize: usize,
    pos: usize,
    dist: u16,
    length: u16,
) callconv(.c) void;

fn matchScore(length: u16, distance: u16) i32 {
    return @as(i32, length) - @as(i32, if (distance > 1024) 1 else 0);
}

pub export fn ZopfliLZ77Greedy(
    state: *store_module.BlockState,
    input: [*]const u8,
    start: usize,
    end: usize,
    store: *store_module.Store,
    hash: *hash_module.Hash,
) callconv(.c) void {
    if (start == end) return;
    const windowstart = start -| hash_module.window_size;
    var sublen: [259]u16 = undefined;

    var previous_length: u16 = 0;
    var previous_dist: u16 = 0;
    var match_available = false;

    hash_module.ZopfliResetHash(hash_module.window_size, hash);
    hash_module.ZopfliWarmupHash(input, windowstart, end, hash);
    for (windowstart..start) |j| hash_module.ZopfliUpdateHash(input, j, end, hash);

    var i = start;
    while (i < end) : (i += 1) {
        hash_module.ZopfliUpdateHash(input, i, end, hash);
        var length: u16 = undefined;
        var dist: u16 = undefined;
        ZopfliFindLongestMatch(state, hash, input, i, end, 258, &sublen, &dist, &length);
        var score = matchScore(length, dist);

        const previous_score = matchScore(previous_length, previous_dist);
        if (match_available) {
            match_available = false;
            if (score > previous_score + 1) {
                store_module.ZopfliStoreLitLenDist(input[i - 1], 0, i - 1, store);
                if (score >= 3 and length < 258) {
                    match_available = true;
                    previous_length = length;
                    previous_dist = dist;
                    continue;
                }
            } else {
                length = previous_length;
                dist = previous_dist;
                score = previous_score;
                ZopfliVerifyLenDist(input, end, i - 1, dist, length);
                store_module.ZopfliStoreLitLenDist(length, dist, i - 1, store);
                var j: usize = 2;
                while (j < length) : (j += 1) {
                    std.debug.assert(i < end);
                    i += 1;
                    hash_module.ZopfliUpdateHash(input, i, end, hash);
                }
                continue;
            }
        } else if (score >= 3 and length < 258) {
            match_available = true;
            previous_length = length;
            previous_dist = dist;
            continue;
        }

        if (score >= 3) {
            ZopfliVerifyLenDist(input, end, i, dist, length);
            store_module.ZopfliStoreLitLenDist(length, dist, i, store);
        } else {
            length = 1;
            store_module.ZopfliStoreLitLenDist(input[i], 0, i, store);
        }

        var j: usize = 1;
        while (j < length) : (j += 1) {
            std.debug.assert(i < end);
            i += 1;
            hash_module.ZopfliUpdateHash(input, i, end, hash);
        }
    }
}

test "greedy score preserves original long-distance penalty" {
    try std.testing.expectEqual(@as(i32, 3), matchScore(3, 1024));
    try std.testing.expectEqual(@as(i32, 2), matchScore(3, 1025));
    try std.testing.expectEqual(@as(i32, -1), matchScore(0, 32768));
}
