//! Native reconstruction and replay of the optimal LZ77 path from Zopfli
//! 1.0.3 squeeze.c. The forward dynamic program remains in C temporarily.
const std = @import("std");
const state_mod = @import("lz77_store.zig");
const hash_mod = @import("hash.zig");
const match_mod = @import("lz77_match.zig");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn realloc(?*anyopaque, usize) callconv(.c) ?*anyopaque;

fn appendPath(path: *?[*]u16, len: *usize, value: u16) void {
    const index = len.*;
    if ((index & (index -% 1)) == 0) {
        const capacity = if (index == 0) @as(usize, 1) else index * 2;
        const old: ?*anyopaque = if (path.*) |p| @ptrCast(p) else null;
        const raw = if (index == 0) malloc(@sizeOf(u16)) else realloc(old, capacity * @sizeOf(u16));
        path.* = @ptrCast(@alignCast(raw orelse @panic("Zopfli squeeze path allocation failed")));
    }
    path.*.?[index] = value;
    len.* = index + 1;
}

pub export fn ZfSqueezeTraceBackwards(size: usize, length_array: [*]const u16, path: *?[*]u16, pathsize: *usize) callconv(.c) void {
    if (size == 0) return;
    var index = size;
    while (true) {
        const length = length_array[index];
        appendPath(path, pathsize, length);
        std.debug.assert(length > 0 and length <= 258 and length <= index);
        index -= length;
        if (index == 0) break;
    }
    for (0..pathsize.* / 2) |i| {
        const opposite = pathsize.* - i - 1;
        std.mem.swap(u16, &path.*.?[i], &path.*.?[opposite]);
    }
}

pub export fn ZfSqueezeFollowPath(
    state: *state_mod.BlockState,
    input: [*]const u8,
    start: usize,
    end: usize,
    path: [*]u16,
    pathsize: usize,
    store: *state_mod.Store,
    hash: *hash_mod.Hash,
) callconv(.c) void {
    if (start == end) return;
    const windowstart = start -| hash_mod.window_size;
    hash_mod.ZopfliResetHash(hash_mod.window_size, hash);
    hash_mod.ZopfliWarmupHash(input, windowstart, end, hash);
    for (windowstart..start) |j| hash_mod.ZopfliUpdateHash(input, j, end, hash);

    var pos = start;
    for (path[0..pathsize]) |original_length| {
        var length = original_length;
        std.debug.assert(pos < end);
        hash_mod.ZopfliUpdateHash(input, pos, end, hash);
        if (length >= 3) {
            var found_length: u16 = undefined;
            var distance: u16 = undefined;
            match_mod.ZopfliFindLongestMatch(state, hash, input, pos, end, length, null, &distance, &found_length);
            std.debug.assert(!(found_length != length and length > 2 and found_length > 2));
            match_mod.ZopfliVerifyLenDist(input, end, pos, distance, length);
            state_mod.ZopfliStoreLitLenDist(length, distance, pos, store);
        } else {
            length = 1;
            state_mod.ZopfliStoreLitLenDist(input[pos], 0, pos, store);
        }
        std.debug.assert(pos + length <= end);
        for (1..length) |j| hash_mod.ZopfliUpdateHash(input, pos + j, end, hash);
        pos += length;
    }
}

test "optimal path backtracking is reversed into forward token order" {
    var path: ?[*]u16 = null;
    var pathsize: usize = 0;
    defer if (path) |p| std.c.free(@ptrCast(p));
    const lengths = [_]u16{ 0, 1, 1, 1, 3, 1, 2, 3 };
    // Position 7 <- 4 (3) <- 1 (3) <- 0 (1).
    ZfSqueezeTraceBackwards(7, &lengths, &path, &pathsize);
    try std.testing.expectEqualSlices(u16, &.{ 1, 3, 3 }, path.?[0..pathsize]);
}

test "empty block leaves path unallocated" {
    var path: ?[*]u16 = null;
    var count: usize = 0;
    const values = [_]u16{0};
    ZfSqueezeTraceBackwards(0, &values, &path, &count);
    try std.testing.expect(path == null);
    try std.testing.expectEqual(@as(usize, 0), count);
}
