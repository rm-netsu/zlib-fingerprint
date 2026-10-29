//! Native Zopfli 1.0.3 rolling hash and match-chain tables.
//! Replaces upstream hash.c with C ABI compatible exports. The exact
//! ZOPFLI_HASH_SAME and ZOPFLI_HASH_SAME_HASH settings from util.h are used.
const std = @import("std");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;

pub const window_size: usize = 32768;
const window_mask: usize = window_size - 1;
const hash_mask: i32 = 32767;

pub const Hash = extern struct {
    head: [*]i32,
    prev: [*]u16,
    hashval: [*]i32,
    val: i32,
    head2: [*]i32,
    prev2: [*]u16,
    hashval2: [*]i32,
    val2: i32,
    same: [*]u16,
};

fn mallocArray(comptime T: type, count: usize) [*]T {
    const addr = malloc(count * @sizeOf(T)) orelse @panic("Zopfli hash allocation failed");
    return @ptrCast(@alignCast(addr));
}

fn freeArray(ptr: anytype) void {
    free(@ptrCast(ptr));
}

pub export fn ZopfliAllocHash(size: usize, h: *Hash) callconv(.c) void {
    h.head = mallocArray(i32, 65536);
    h.prev = mallocArray(u16, size);
    h.hashval = mallocArray(i32, size);
    h.head2 = mallocArray(i32, 65536);
    h.prev2 = mallocArray(u16, size);
    h.hashval2 = mallocArray(i32, size);
    h.same = mallocArray(u16, size);
}

pub export fn ZopfliCleanHash(h: *Hash) callconv(.c) void {
    freeArray(h.head);
    freeArray(h.prev);
    freeArray(h.hashval);
    freeArray(h.head2);
    freeArray(h.prev2);
    freeArray(h.hashval2);
    freeArray(h.same);
}

pub export fn ZopfliResetHash(size: usize, h: *Hash) callconv(.c) void {
    h.val = 0;
    h.val2 = 0;
    @memset(h.head[0..65536], -1);
    @memset(h.head2[0..65536], -1);
    @memset(h.hashval[0..size], -1);
    @memset(h.hashval2[0..size], -1);
    @memset(h.same[0..size], 0);
    for (0..size) |i| {
        h.prev[i] = @intCast(i);
        h.prev2[i] = @intCast(i);
    }
}

fn updateValue(h: *Hash, byte: u8) void {
    h.val = ((h.val << 5) ^ @as(i32, byte)) & hash_mask;
}

pub export fn ZopfliWarmupHash(data: [*]const u8, pos: usize, end: usize, h: *Hash) callconv(.c) void {
    updateValue(h, data[pos]);
    if (pos + 1 < end) updateValue(h, data[pos + 1]);
}

pub export fn ZopfliUpdateHash(data: [*]const u8, pos: usize, end: usize, h: *Hash) callconv(.c) void {
    const hpos = pos & window_mask;
    updateValue(h, if (pos + 3 <= end) data[pos + 2] else 0);
    h.hashval[hpos] = h.val;

    const previous = h.head[@intCast(h.val)];
    if (previous != -1 and h.hashval[@intCast(previous)] == h.val) {
        h.prev[hpos] = @intCast(previous);
    } else {
        h.prev[hpos] = @intCast(hpos);
    }
    h.head[@intCast(h.val)] = @intCast(hpos);

    var amount: usize = 0;
    if (h.same[(pos -% 1) & window_mask] > 1) {
        amount = h.same[(pos -% 1) & window_mask] - 1;
    }
    while (pos + amount + 1 < end and data[pos] == data[pos + amount + 1] and amount < 65535) {
        amount += 1;
    }
    h.same[hpos] = @intCast(amount);

    h.val2 = ((@as(i32, @intCast(h.same[hpos])) - 3) & 255) ^ h.val;
    h.hashval2[hpos] = h.val2;
    const previous2 = h.head2[@intCast(h.val2)];
    if (previous2 != -1 and h.hashval2[@intCast(previous2)] == h.val2) {
        h.prev2[hpos] = @intCast(previous2);
    } else {
        h.prev2[hpos] = @intCast(hpos);
    }
    h.head2[@intCast(h.val2)] = @intCast(hpos);
}

test "Zopfli hash structure has the C layout" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Hash));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Hash, "same"));
}

test "Zopfli native hash handles repeated input and wrapping" {
    var h: Hash = undefined;
    ZopfliAllocHash(window_size, &h);
    defer ZopfliCleanHash(&h);
    ZopfliResetHash(window_size, &h);
    const data = "aaaaaaaaaaaaaaaa";
    ZopfliWarmupHash(data.ptr, 0, data.len, &h);
    for (0..data.len) |i| ZopfliUpdateHash(data.ptr, i, data.len, &h);
    try std.testing.expect(h.same[0] > 0);
    try std.testing.expectEqual(@as(u16, 0), h.prev[0]);
}
