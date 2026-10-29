//! Native Zopfli 1.0.3 LZ77-store ownership and block-state lifecycle.
//! Longest-match search and greedy parsing still execute in upstream lz77.c.
const std = @import("std");
const cache = @import("cache.zig");

extern "c" fn malloc(usize) callconv(.c) ?*anyopaque;
extern "c" fn realloc(?*anyopaque, usize) callconv(.c) ?*anyopaque;
extern "c" fn free(?*anyopaque) callconv(.c) void;

const ll_symbols = 288;
const d_symbols = 32;

pub const Store = extern struct {
    litlens: ?[*]u16,
    dists: ?[*]u16,
    size: usize,
    data: [*]const u8,
    pos: ?[*]usize,
    ll_symbol: ?[*]u16,
    d_symbol: ?[*]u16,
    ll_counts: ?[*]usize,
    d_counts: ?[*]usize,
};

pub const BlockState = extern struct {
    options: ?*const anyopaque,
    lmc: ?*cache.LongestMatchCache,
    blockstart: usize,
    blockend: usize,
};

fn alloc(comptime T: type, count: usize) [*]T {
    const raw = malloc(@sizeOf(T) * count) orelse @panic("Zopfli LZ77-store allocation failed");
    return @ptrCast(@alignCast(raw));
}

fn freeArray(pointer: anytype) void {
    if (pointer) |p| free(@ptrCast(p));
}

pub export fn ZopfliInitLZ77Store(data: [*]const u8, store: *Store) callconv(.c) void {
    store.* = .{
        .litlens = null,
        .dists = null,
        .size = 0,
        .data = data,
        .pos = null,
        .ll_symbol = null,
        .d_symbol = null,
        .ll_counts = null,
        .d_counts = null,
    };
}

pub export fn ZopfliCleanLZ77Store(store: *Store) callconv(.c) void {
    freeArray(store.litlens);
    freeArray(store.dists);
    freeArray(store.pos);
    freeArray(store.ll_symbol);
    freeArray(store.d_symbol);
    freeArray(store.ll_counts);
    freeArray(store.d_counts);
}

pub export fn ZopfliCopyLZ77Store(source: *const Store, dest: *Store) callconv(.c) void {
    const ll_size = ll_symbols * (std.math.divCeil(usize, source.size, ll_symbols) catch unreachable);
    const d_size = d_symbols * (std.math.divCeil(usize, source.size, d_symbols) catch unreachable);
    ZopfliCleanLZ77Store(dest);
    ZopfliInitLZ77Store(source.data, dest);
    dest.litlens = alloc(u16, source.size);
    dest.dists = alloc(u16, source.size);
    dest.pos = alloc(usize, source.size);
    dest.ll_symbol = alloc(u16, source.size);
    dest.d_symbol = alloc(u16, source.size);
    dest.ll_counts = alloc(usize, ll_size);
    dest.d_counts = alloc(usize, d_size);
    dest.size = source.size;
    // Upstream copies element-by-element, so a count of zero never touches
    // the (possibly null) source arrays. Guarding each copy on its length
    // preserves exactly that behavior for empty stores.
    if (source.size > 0) {
        @memcpy(dest.litlens.?[0..source.size], source.litlens.?[0..source.size]);
        @memcpy(dest.dists.?[0..source.size], source.dists.?[0..source.size]);
        @memcpy(dest.pos.?[0..source.size], source.pos.?[0..source.size]);
        @memcpy(dest.ll_symbol.?[0..source.size], source.ll_symbol.?[0..source.size]);
        @memcpy(dest.d_symbol.?[0..source.size], source.d_symbol.?[0..source.size]);
    }
    if (ll_size > 0) @memcpy(dest.ll_counts.?[0..ll_size], source.ll_counts.?[0..ll_size]);
    if (d_size > 0) @memcpy(dest.d_counts.?[0..d_size], source.d_counts.?[0..d_size]);
}

pub export fn ZopfliLZ77GetByteRange(store: *const Store, start: usize, end: usize) callconv(.c) usize {
    if (start == end) return 0;
    const last = end - 1;
    return store.pos.?[last] + (if (store.dists.?[last] == 0) @as(usize, 1) else @as(usize, store.litlens.?[last])) - store.pos.?[start];
}

// Match upstream ZOPFLI_APPEND_DATA's power-of-two growth. The store's `size`
// is temporarily reset between the different arrays when appending a token.
fn append(comptime T: type, arr: *?[*]T, index: usize, value: T) void {
    if (index & (index -% 1) == 0) {
        const new_capacity = if (index == 0) @as(usize, 1) else index * 2;
        const previous: ?*anyopaque = if (arr.*) |p| @ptrCast(p) else null;
        const raw = if (index == 0) malloc(@sizeOf(T)) else realloc(previous, new_capacity * @sizeOf(T));
        arr.* = @ptrCast(@alignCast(raw orelse @panic("Zopfli LZ77 append allocation failed")));
    }
    arr.*.?[index] = value;
}

const length_bases = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const distance_bases = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

pub fn lengthSymbol(length: u16) u16 {
    var i: usize = 0;
    while (i + 1 < length_bases.len and length >= length_bases[i + 1]) : (i += 1) {}
    return @intCast(257 + i);
}

pub fn distanceSymbol(dist: u16) u16 {
    var i: usize = 0;
    while (i + 1 < distance_bases.len and dist >= distance_bases[i + 1]) : (i += 1) {}
    return @intCast(i);
}

pub export fn ZopfliStoreLitLenDist(length: u16, dist: u16, pos: usize, store: *Store) callconv(.c) void {
    const original = store.size;
    const llstart = ll_symbols * (original / ll_symbols);
    const dstart = d_symbols * (original / d_symbols);
    if (original % ll_symbols == 0) {
        for (0..ll_symbols) |i| {
            const value = if (original == 0) @as(usize, 0) else store.ll_counts.?[original - ll_symbols + i];
            append(usize, &store.ll_counts, original + i, value);
        }
    }
    if (original % d_symbols == 0) {
        for (0..d_symbols) |i| {
            const value = if (original == 0) @as(usize, 0) else store.d_counts.?[original - d_symbols + i];
            append(usize, &store.d_counts, original + i, value);
        }
    }
    append(u16, &store.litlens, original, length);
    append(u16, &store.dists, original, dist);
    append(usize, &store.pos, original, pos);
    std.debug.assert(length < 259);
    const ll_symbol = if (dist == 0) length else lengthSymbol(length);
    const d_symbol = if (dist == 0) @as(u16, 0) else distanceSymbol(dist);
    append(u16, &store.ll_symbol, original, ll_symbol);
    append(u16, &store.d_symbol, original, d_symbol);
    store.ll_counts.?[llstart + ll_symbol] += 1;
    if (dist != 0) store.d_counts.?[dstart + d_symbol] += 1;
    store.size = original + 1;
}

pub export fn ZopfliAppendLZ77Store(source: *const Store, target: *Store) callconv(.c) void {
    for (0..source.size) |i| {
        ZopfliStoreLitLenDist(source.litlens.?[i], source.dists.?[i], source.pos.?[i], target);
    }
}

fn histogramAt(store: *const Store, position: usize, ll: *[ll_symbols]usize, d: *[d_symbols]usize) void {
    const llpos = ll_symbols * (position / ll_symbols);
    const dpos = d_symbols * (position / d_symbols);
    @memcpy(ll, store.ll_counts.?[llpos .. llpos + ll_symbols]);
    for (position + 1..@min(llpos + ll_symbols, store.size)) |i| {
        ll[store.ll_symbol.?[i]] -= 1;
    }
    @memcpy(d, store.d_counts.?[dpos .. dpos + d_symbols]);
    for (position + 1..@min(dpos + d_symbols, store.size)) |i| {
        if (store.dists.?[i] != 0) d[store.d_symbol.?[i]] -= 1;
    }
}

pub export fn ZopfliLZ77GetHistogram(store: *const Store, start: usize, end: usize, ll_counts: [*]usize, d_counts: [*]usize) callconv(.c) void {
    const ll = ll_counts[0..ll_symbols];
    const d = d_counts[0..d_symbols];
    if (start + ll_symbols * 3 > end) {
        @memset(ll, 0);
        @memset(d, 0);
        for (start..end) |i| {
            ll[store.ll_symbol.?[i]] += 1;
            if (store.dists.?[i] != 0) d[store.d_symbol.?[i]] += 1;
        }
    } else {
        var current_ll: [ll_symbols]usize = undefined;
        var current_d: [d_symbols]usize = undefined;
        histogramAt(store, end - 1, &current_ll, &current_d);
        if (start > 0) {
            var previous_ll: [ll_symbols]usize = undefined;
            var previous_d: [d_symbols]usize = undefined;
            histogramAt(store, start - 1, &previous_ll, &previous_d);
            for (0..ll_symbols) |i| current_ll[i] -= previous_ll[i];
            for (0..d_symbols) |i| current_d[i] -= previous_d[i];
        }
        @memcpy(ll, &current_ll);
        @memcpy(d, &current_d);
    }
}

pub export fn ZopfliInitBlockState(options: ?*const anyopaque, blockstart: usize, blockend: usize, add_lmc: c_int, state: *BlockState) callconv(.c) void {
    state.options = options;
    state.blockstart = blockstart;
    state.blockend = blockend;
    if (add_lmc != 0) {
        const lmc: *cache.LongestMatchCache = @ptrCast(@alignCast(malloc(@sizeOf(cache.LongestMatchCache)) orelse @panic("Zopfli cache state allocation failed")));
        cache.ZopfliInitCache(blockend - blockstart, lmc);
        state.lmc = lmc;
    } else {
        state.lmc = null;
    }
}

pub export fn ZopfliCleanBlockState(state: *BlockState) callconv(.c) void {
    if (state.lmc) |lmc| {
        cache.ZopfliCleanCache(lmc);
        free(@ptrCast(lmc));
    }
}

test "native LZ77 store matches C ABI and copies statistics" {
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Store));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BlockState));
    const data = "abcd";
    var source: Store = undefined;
    ZopfliInitLZ77Store(data.ptr, &source);
    defer ZopfliCleanLZ77Store(&source);
    source.size = 2;
    source.litlens = alloc(u16, 2);
    source.dists = alloc(u16, 2);
    source.pos = alloc(usize, 2);
    source.ll_symbol = alloc(u16, 2);
    source.d_symbol = alloc(u16, 2);
    source.ll_counts = alloc(usize, ll_symbols);
    source.d_counts = alloc(usize, d_symbols);
    source.litlens.?[0..2].* = .{ 97, 3 };
    source.dists.?[0..2].* = .{ 0, 1 };
    source.pos.?[0..2].* = .{ 0, 1 };
    source.ll_symbol.?[0..2].* = .{ 97, 257 };
    source.d_symbol.?[0..2].* = .{ 0, 0 };
    @memset(source.ll_counts.?[0..ll_symbols], 0);
    @memset(source.d_counts.?[0..d_symbols], 0);
    source.ll_counts.?[97] = 1;
    var copied: Store = undefined;
    ZopfliInitLZ77Store(data.ptr, &copied);
    defer ZopfliCleanLZ77Store(&copied);
    ZopfliCopyLZ77Store(&source, &copied);
    try std.testing.expectEqual(@as(usize, 4), ZopfliLZ77GetByteRange(&copied, 0, 2));
    try std.testing.expectEqual(@as(u16, 257), copied.ll_symbol.?[1]);
    try std.testing.expectEqual(@as(usize, 1), copied.ll_counts.?[97]);
}

test "block-state cache is allocated only when requested" {
    var state: BlockState = undefined;
    ZopfliInitBlockState(null, 20, 40, 1, &state);
    defer ZopfliCleanBlockState(&state);
    try std.testing.expect(state.lmc != null);
    try std.testing.expectEqual(@as(usize, 20), state.blockstart);
}

test "native store cumulative histograms agree with direct token counting" {
    const data = "test";
    var store: Store = undefined;
    ZopfliInitLZ77Store(data.ptr, &store);
    defer ZopfliCleanLZ77Store(&store);
    var position: usize = 0;
    for (0..1024) |i| {
        const is_match = i % 7 == 0;
        const length: u16 = if (is_match) @intCast(3 + (i % 256)) else @intCast(32 + i % 80);
        const distance: u16 = if (is_match) @intCast(1 + i % 32768) else 0;
        ZopfliStoreLitLenDist(length, distance, position, &store);
        position += if (is_match) length else 1;
    }
    try std.testing.expectEqual(@as(usize, 1024), store.size);
    const ranges = [_][2]usize{ .{ 0, 0 }, .{ 0, 20 }, .{ 4, 900 }, .{ 0, 1024 }, .{ 288, 895 }, .{ 31, 32 }, .{ 32, 65 }, .{ 700, 1000 } };
    for (ranges) |bounds| {
        var actual_ll: [ll_symbols]usize = undefined;
        var actual_d: [d_symbols]usize = undefined;
        ZopfliLZ77GetHistogram(&store, bounds[0], bounds[1], &actual_ll, &actual_d);
        var expected_ll = [_]usize{0} ** ll_symbols;
        var expected_d = [_]usize{0} ** d_symbols;
        for (bounds[0]..bounds[1]) |i| {
            expected_ll[store.ll_symbol.?[i]] += 1;
            if (store.dists.?[i] != 0) expected_d[store.d_symbol.?[i]] += 1;
        }
        try std.testing.expectEqualSlices(usize, &expected_ll, &actual_ll);
        try std.testing.expectEqualSlices(usize, &expected_d, &actual_d);
    }
    var copy: Store = undefined;
    ZopfliInitLZ77Store(data.ptr, &copy);
    defer ZopfliCleanLZ77Store(&copy);
    ZopfliCopyLZ77Store(&store, &copy);
    try std.testing.expectEqualSlices(u16, store.ll_symbol.?[0..1024], copy.ll_symbol.?[0..1024]);
    try std.testing.expectEqualSlices(usize, store.ll_counts.?[0 .. ll_symbols * 4], copy.ll_counts.?[0 .. ll_symbols * 4]);
}
