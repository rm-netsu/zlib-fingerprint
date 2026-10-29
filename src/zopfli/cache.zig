//! Zopfli 1.0.3 longest-match cache, ported from upstream cache.c.
//! C ABI exports allow upstream lz77.c to use this native implementation.
const std = @import("std");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;

const cache_length: usize = 8;
const stride = cache_length * 3;

pub const LongestMatchCache = extern struct {
    length: [*]u16,
    dist: [*]u16,
    sublen: [*]u8,
};

fn alloc(comptime T: type, len: usize) [*]T {
    const memory = malloc(len * @sizeOf(T)) orelse @panic("Zopfli match-cache allocation failed");
    return @ptrCast(@alignCast(memory));
}

pub export fn ZopfliInitCache(blocksize: usize, lmc: *LongestMatchCache) callconv(.c) void {
    lmc.length = alloc(u16, blocksize);
    lmc.dist = alloc(u16, blocksize);
    lmc.sublen = alloc(u8, stride * blocksize);
    @memset(lmc.length[0..blocksize], 1);
    @memset(lmc.dist[0..blocksize], 0);
    @memset(lmc.sublen[0 .. stride * blocksize], 0);
}

pub export fn ZopfliCleanCache(lmc: *LongestMatchCache) callconv(.c) void {
    free(@ptrCast(lmc.length));
    free(@ptrCast(lmc.dist));
    free(@ptrCast(lmc.sublen));
}

pub export fn ZopfliMaxCachedSublen(lmc: *const LongestMatchCache, pos: usize, length: usize) callconv(.c) c_uint {
    _ = length;
    const cache = lmc.sublen[pos * stride ..][0..stride];
    if (cache[1] == 0 and cache[2] == 0) return 0;
    return @as(c_uint, cache[(cache_length - 1) * 3]) + 3;
}

pub export fn ZopfliSublenToCache(sublen: [*]const u16, pos: usize, length: usize, lmc: *LongestMatchCache) callconv(.c) void {
    if (length < 3) return;
    const cache = lmc.sublen[pos * stride ..][0..stride];
    var j: usize = 0;
    var bestlength: usize = 0;
    for (3..length + 1) |i| {
        if (i == length or sublen[i] != sublen[i + 1]) {
            cache[j * 3] = @truncate(i - 3);
            cache[j * 3 + 1] = @truncate(sublen[i]);
            cache[j * 3 + 2] = @truncate(sublen[i] >> 8);
            bestlength = i;
            j += 1;
            if (j >= cache_length) break;
        }
    }
    if (j < cache_length) {
        std.debug.assert(bestlength == length);
        cache[(cache_length - 1) * 3] = @truncate(bestlength - 3);
    } else {
        std.debug.assert(bestlength <= length);
    }
    std.debug.assert(bestlength == ZopfliMaxCachedSublen(lmc, pos, length));
}

pub export fn ZopfliCacheToSublen(lmc: *const LongestMatchCache, pos: usize, length: usize, sublen: [*]u16) callconv(.c) void {
    if (length < 3) return;
    const maxlength = ZopfliMaxCachedSublen(lmc, pos, length);
    const cache = lmc.sublen[pos * stride ..][0..stride];
    var prevlength: usize = 0;
    for (0..cache_length) |j| {
        const endlength: usize = @as(usize, cache[j * 3]) + 3;
        const dist: u16 = @as(u16, cache[j * 3 + 1]) + 256 * @as(u16, cache[j * 3 + 2]);
        for (prevlength..endlength + 1) |i| sublen[i] = dist;
        if (endlength == maxlength) break;
        prevlength = endlength + 1;
    }
}

test "C-compatible cache layout and three-byte run encoding" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(LongestMatchCache));
    var lmc: LongestMatchCache = undefined;
    ZopfliInitCache(4, &lmc);
    defer ZopfliCleanCache(&lmc);
    try std.testing.expectEqual(@as(u16, 1), lmc.length[0]);
    try std.testing.expectEqual(@as(u16, 0), lmc.dist[3]);
    var sublen = [_]u16{0} ** 16;
    for (3..12) |i| sublen[i] = if (i < 7) 42 else 300;
    ZopfliSublenToCache(&sublen, 1, 11, &lmc);
    try std.testing.expectEqual(@as(c_uint, 11), ZopfliMaxCachedSublen(&lmc, 1, 11));
    var restored = [_]u16{0} ** 16;
    ZopfliCacheToSublen(&lmc, 1, 11, &restored);
    try std.testing.expectEqualSlices(u16, sublen[3..12], restored[3..12]);
}

test "cache truncates after eight distance transitions" {
    var lmc: LongestMatchCache = undefined;
    ZopfliInitCache(1, &lmc);
    defer ZopfliCleanCache(&lmc);
    try std.testing.expectEqual(@as(c_uint, 0), ZopfliMaxCachedSublen(&lmc, 0, 20));
    var sublen = [_]u16{0} ** 20;
    for (3..17) |i| sublen[i] = @intCast(i + 2);
    ZopfliSublenToCache(&sublen, 0, 16, &lmc);
    try std.testing.expectEqual(@as(c_uint, 10), ZopfliMaxCachedSublen(&lmc, 0, 16));
    var restored = [_]u16{0} ** 20;
    ZopfliCacheToSublen(&lmc, 0, 16, &restored);
    try std.testing.expectEqualSlices(u16, sublen[3..11], restored[3..11]);
}
