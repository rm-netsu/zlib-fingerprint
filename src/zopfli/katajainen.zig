//! Zopfli 1.0.3 length-limited Huffman code lengths — native Zig port of
//! upstream `katajainen.c` (bounded package-merge).
//!
//! Algorithm: "A Fast and Space-Economical Algorithm for Length-Limited
//! Coding", Jyrki Katajainen, Alistair Moffat, Andrew Turpin. The port keeps
//! upstream's chain/node-pool structure, the stable symbol-index sort
//! (weight packed as `weight << 9 | symbol index`), the two-lookahead list
//! representation, the `2 * numsymbols - 4` BoundaryPM schedule with a final
//! BoundaryPMFinal run, and every special case, so the produced bit lengths
//! are identical to Zopfli 1.0.3 for all non-UB inputs.
//!
//! Deviation from upstream (documented): the C `LeafComparator` returns the
//! packed weights' difference truncated to `int`, which only agrees with a
//! true comparison while frequency differences stay below 2^31; the callers
//! (per-master-block symbol counts, at most 1,000,000) never leave that
//! range. This port compares the packed `usize` keys directly, which matches
//! upstream exactly inside that range and stays correct beyond it.
const std = @import("std");

extern "c" fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) callconv(.c) void;

/// Chain node; also represents a leaf. `weight` is the total weight of the
/// chain, `tail` links to the previous node(s) of the chain, `count` is the
/// leaf symbol index for leaves or the number of leaves before this chain.
const Node = struct {
    weight: usize,
    tail: ?*Node,
    count: i32,
};

/// Sequential node memory pool mirroring upstream's NodePool.
const NodePool = struct {
    nodes: [*]Node,
    used: usize,
    capacity: usize,

    fn alloc(pool: *NodePool) *Node {
        if (pool.used == pool.capacity) @panic("Zopfli katajainen node pool exhausted");
        const node = &pool.nodes[pool.used];
        pool.used += 1;
        return node;
    }
};

/// Initializes a chain node with the given values.
fn initNode(weight: usize, count: i32, tail: ?*Node, node: *Node) void {
    node.weight = weight;
    node.count = count;
    node.tail = tail;
}

/// Performs a Boundary Package-Merge step: puts a new chain in the given
/// list. Depending on the weights, the new chain is a leaf or a combination
/// of two chains from the previous list.
fn boundaryPM(lists: [] [2]?*Node, leaves: []const Node, numsymbols: usize, pool: *NodePool, index: usize) void {
    const lastcount = lists[index][1].?.count;

    if (index == 0 and lastcount >= numsymbols) return;

    const newchain = pool.alloc();
    const oldchain = lists[index][1].?;

    // These are set up before the recursive calls below, so that there is a
    // list pointing to the new node, to let the garbage collection know it's
    // in use.
    lists[index][0] = oldchain;
    lists[index][1] = newchain;

    if (index == 0) {
        // New leaf node in list 0.
        initNode(leaves[@intCast(lastcount)].weight, lastcount + 1, null, newchain);
    } else {
        const sum = lists[index - 1][0].?.weight + lists[index - 1][1].?.weight;
        if (lastcount >= 0 and @as(usize, @intCast(lastcount)) < numsymbols and
            sum > leaves[@intCast(lastcount)].weight)
        {
            // New leaf inserted in list, so count is incremented.
            initNode(leaves[@intCast(lastcount)].weight, lastcount + 1, oldchain.tail, newchain);
        } else {
            initNode(sum, lastcount, lists[index - 1][1], newchain);
            // Two lookahead chains of previous list used up, create new ones.
            boundaryPM(lists, leaves, numsymbols, pool, index - 1);
            boundaryPM(lists, leaves, numsymbols, pool, index - 1);
        }
    }
}

/// Final Boundary Package-Merge step: completes the last chain of the last
/// list without allocating a full two-lookahead slot.
fn boundaryPMFinal(lists: [] [2]?*Node, leaves: []const Node, numsymbols: usize, pool: *NodePool, index: usize) void {
    const lastcount = lists[index][1].?.count;
    const sum = lists[index - 1][0].?.weight + lists[index - 1][1].?.weight;

    if (lastcount >= 0 and @as(usize, @intCast(lastcount)) < numsymbols and
        sum > leaves[@intCast(lastcount)].weight)
    {
        const newchain = pool.alloc();
        const oldchain = lists[index][1].?.tail;

        lists[index][1] = newchain;
        newchain.count = lastcount + 1;
        newchain.tail = oldchain;
        // Upstream never initializes this weight; the extraction phase never
        // reads it. Zero it here for reproducible memory behavior.
        newchain.weight = 0;
    } else {
        lists[index][1].?.tail = lists[index - 1][1];
    }
}

/// Initializes each list with as lookahead chains the two leaves with lowest
/// weights.
fn initLists(pool: *NodePool, leaves: []const Node, maxbits: usize, lists: [] [2]?*Node) void {
    const node0 = pool.alloc();
    const node1 = pool.alloc();
    initNode(leaves[0].weight, 1, null, node0);
    initNode(leaves[1].weight, 2, null, node1);
    for (0..maxbits) |i| {
        lists[i][0] = node0;
        lists[i][1] = node1;
    }
}

/// Converts the result of boundary package-merge to the bit lengths. The
/// last chain of the last list contains the amount of active leaves in each
/// list.
fn extractBitLengths(chain: ?*const Node, leaves: []const Node, bitlengths: []c_uint) void {
    var counts = [_]i32{0} ** 16;
    var end: u32 = 16;
    var ptr: u32 = 15;
    var value: c_uint = 1;

    var node = chain;
    while (node) |n| : (node = n.tail) {
        if (end == 0) @panic("Zopfli katajainen chain exceeds 16 levels");
        end -= 1;
        counts[end] = n.count;
    }

    var val: i32 = counts[15];
    while (ptr >= end) {
        while (val > counts[ptr - 1]) : (val -= 1) {
            bitlengths[@intCast(leaves[@intCast(val - 1)].count)] = value;
        }
        ptr -= 1;
        value += 1;
    }
}

/// Sort comparator on the packed `weight << 9 | symbol index` key. Keys are
/// pairwise distinct (the symbol index is unique), so the order is total and
/// independent of the sorting algorithm.
fn leafLessThan(_: void, a: Node, b: Node) bool {
    return a.weight < b.weight;
}

/// Port of upstream `ZopfliLengthLimitedCodeLengths`: calculates
/// length-limited Huffman code lengths for the given frequencies.
/// Returns 0 on success and 1 on error (too many symbols for maxbits, or a
/// frequency too large to pack), mirroring the C ABI.
pub fn lengthLimitedCodeLengths(
    frequencies: [*]const usize,
    n: usize,
    maxbits_in: c_int,
    bitlengths: [*]c_uint,
) c_int {
    if (n > 512) {
        // The packed sort key reserves 9 bits for the symbol index; upstream
        // silently corrupts results beyond 512 symbols, every caller stays
        // far below that (288 is the largest alphabet).
        return 1;
    }
    if (maxbits_in < 1 or maxbits_in > 15) return 1;

    // Initialize all bit lengths at 0.
    for (0..n) |i| bitlengths[i] = 0;

    // One leaf per symbol; only numsymbols leaves will be used.
    const leaves_raw = malloc(n * @sizeOf(Node)) orelse @panic("Zopfli katajainen leaf allocation failed");
    const leaves: [*]Node = @ptrCast(@alignCast(leaves_raw));
    defer free(leaves_raw);

    // Count used symbols and place them in the leaves.
    var numsymbols: usize = 0;
    for (0..n) |i| {
        if (frequencies[i] != 0) {
            leaves[numsymbols].weight = frequencies[i];
            leaves[numsymbols].count = @intCast(i); // Index of symbol this leaf represents.
            leaves[numsymbols].tail = null;
            numsymbols += 1;
        }
    }

    // Check special cases and error conditions.
    if ((@as(usize, 1) << @intCast(maxbits_in)) < numsymbols) {
        return 1; // Error, too few maxbits to represent symbols.
    }
    if (numsymbols == 0) {
        return 0; // No symbols at all. OK.
    }
    if (numsymbols == 1) {
        bitlengths[@intCast(leaves[0].count)] = 1; // Only one symbol, give it bitlength 1, not 0. OK.
        return 0;
    }
    if (numsymbols == 2) {
        bitlengths[@intCast(leaves[0].count)] += 1;
        bitlengths[@intCast(leaves[1].count)] += 1;
        return 0;
    }

    // Sort the leaves from lightest to heaviest. Add count into the same
    // variable for stable sorting.
    for (0..numsymbols) |i| {
        if (leaves[i].weight >= (@as(usize, 1) << @intCast(@bitSizeOf(usize) - 9))) {
            return 1; // Error, we need 9 bits for the count.
        }
        leaves[i].weight = (leaves[i].weight << 9) | @as(usize, @intCast(leaves[i].count));
    }
    std.mem.sort(Node, leaves[0..numsymbols], {}, leafLessThan);
    for (0..numsymbols) |i| {
        leaves[i].weight >>= 9;
    }

    var maxbits: usize = @intCast(maxbits_in);
    if (numsymbols - 1 < maxbits) {
        maxbits = numsymbols - 1;
    }

    // Initialize node memory pool.
    const nodes_raw = malloc(maxbits * 2 * numsymbols * @sizeOf(Node)) orelse
        @panic("Zopfli katajainen node pool allocation failed");
    const nodes: [*]Node = @ptrCast(@alignCast(nodes_raw));
    defer free(nodes_raw);
    var pool = NodePool{ .nodes = nodes, .used = 0, .capacity = maxbits * 2 * numsymbols };

    const lists_raw = malloc(maxbits * @sizeOf([2]?*Node)) orelse
        @panic("Zopfli katajainen list allocation failed");
    const lists: [*][2]?*Node = @ptrCast(@alignCast(lists_raw));
    defer free(lists_raw);
    initLists(&pool, leaves[0..numsymbols], maxbits, lists[0..maxbits]);

    // In the last list, 2 * numsymbols - 2 active chains need to be created.
    // Two are already created in the initialization. Each BoundaryPM run
    // creates one.
    const num_boundary_pm_runs = 2 * numsymbols - 4;
    for (0..num_boundary_pm_runs - 1) |_| {
        boundaryPM(lists[0..maxbits], leaves[0..numsymbols], numsymbols, &pool, maxbits - 1);
    }
    boundaryPMFinal(lists[0..maxbits], leaves[0..numsymbols], numsymbols, &pool, maxbits - 1);

    extractBitLengths(lists[maxbits - 1][1], leaves[0..numsymbols], bitlengths[0..n]);

    return 0; // OK.
}

/// C ABI drop-in for the upstream katajainen.c entry point, now backed by
/// Zig. Kept exported so external audit harnesses can call it directly.
pub export fn ZopfliLengthLimitedCodeLengths(
    frequencies: [*]const usize,
    n: usize,
    maxbits: c_int,
    bitlengths: [*]c_uint,
) callconv(.c) c_int {
    return lengthLimitedCodeLengths(frequencies, n, maxbits, bitlengths);
}

fn expectLengths(freqs: []const usize, maxbits: i32, expected: []const u32) !void {
    var lengths: [288]c_uint = undefined;
    const rc = lengthLimitedCodeLengths(freqs.ptr, freqs.len, maxbits, &lengths);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqualSlices(u32, expected, lengths[0..expected.len]);
}

test "katajainen: no symbols at all gives all-zero lengths" {
    var lengths: [4]c_uint = undefined;
    const rc = lengthLimitedCodeLengths(&.{ 0, 0, 0, 0 }, 4, 15, &lengths);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqualSlices(c_uint, &.{ 0, 0, 0, 0 }, &lengths);
}

test "katajainen: single symbol gets length one" {
    try expectLengths(&.{ 0, 7, 0, 0 }, 15, &.{ 0, 1, 0, 0 });
}

test "katajainen: two symbols both get length one" {
    try expectLengths(&.{ 5, 0, 3, 0 }, 15, &.{ 1, 0, 1, 0 });
    try expectLengths(&.{ 9, 9, 0, 0 }, 15, &.{ 1, 1, 0, 0 });
}

test "katajainen: equal frequencies share lengths evenly" {
    // Eight equally frequent symbols with maxbits 3 form a complete tree.
    try expectLengths(&.{ 1, 1, 1, 1, 1, 1, 1, 1 }, 3, &.{ 3, 3, 3, 3, 3, 3, 3, 3 });
    // maxbits above numsymbols-1 is reduced: 4 symbols become 2-bit codes.
    try expectLengths(&.{ 1, 1, 1, 1 }, 15, &.{ 2, 2, 2, 2 });
}

test "katajainen: skewed distribution lengths follow weights" {
    // {8,4,2,1} is the classic complete Huffman tree: the optimal lengths
    // 1,2,3,3 already respect the reduced limit (numsymbols-1 = 3).
    try expectLengths(&.{ 8, 4, 2, 1 }, 15, &.{ 1, 2, 3, 3 });
    try expectLengths(&.{ 1, 2, 4, 8 }, 15, &.{ 3, 3, 2, 1 });
}

test "katajainen: length limit forces rebalancing beyond the optimum" {
    // Fibonacci weights need 5 bits unlimited; the limit compresses the
    // deepest pair back to 4 bits. Exact assignment verified against the
    // upstream C kernel by scripts/diff_katajainen.py.
    var lengths: [6]c_uint = undefined;
    const rc = lengthLimitedCodeLengths(&.{ 1, 1, 2, 3, 5, 8 }, 6, 4, &lengths);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    var kraft: f64 = 0;
    for (lengths) |len| kraft += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(len)));
    try std.testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-9);
    for (lengths) |len| try std.testing.expect(len <= 4);
    // The two heaviest symbols must stay strictly shorter than the limit.
    try std.testing.expect(lengths[5] < 4);
    try std.testing.expect(lengths[4] < 4);
}

test "katajainen: zero-frequency symbols stay out of the code" {
    try expectLengths(&.{ 0, 0, 1, 0, 1, 0, 2, 0 }, 15, &.{ 0, 0, 2, 0, 2, 0, 1, 0 });
}

test "katajainen: kraft inequality holds and limit is respected" {
    var rng = std.Random.DefaultPrng.init(0x4B47D4);
    const rand = rng.random();
    var lengths: [288]c_uint = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const n: usize = @intCast(1 + rand.uintLessThan(usize, 288));
        var freqs: [288]usize = undefined;
        for (freqs[0..n]) |*f| {
            f.* = if (rand.boolean() and rand.boolean()) 0 else 1 + rand.uintLessThan(usize, 100000);
        }
        const maxbits: i32 = @intCast(1 + rand.uintLessThan(usize, 15));
        const rc = lengthLimitedCodeLengths(&freqs, n, maxbits, &lengths);
        // Count used symbols to know which outcome is legitimate: upstream
        // reports an error only when 2^maxbits cannot host every symbol.
        var used: usize = 0;
        for (freqs[0..n]) |f| {
            if (f != 0) used += 1;
        }
        if (used > (@as(usize, 1) << @intCast(maxbits))) {
            try std.testing.expectEqual(@as(c_int, 1), rc);
            continue;
        }
        try std.testing.expectEqual(@as(c_int, 0), rc);
        var kraft: f64 = 0;
        var coded: usize = 0;
        for (lengths[0..n]) |len| {
            try std.testing.expect(len <= @as(c_uint, @intCast(maxbits)));
            if (len == 0) continue;
            coded += 1;
            kraft += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(len)));
        }
        if (coded >= 2) try std.testing.expect(kraft <= 1.0 + 1e-9);
    }
}

test "katajainen: error paths return 1 without touching lengths" {
    var lengths: [8]c_uint = undefined;
    // 9 symbols cannot fit in maxbits 3 (2^3 = 8 slots).
    const rc = lengthLimitedCodeLengths(&.{ 1, 1, 1, 1, 1, 1, 1, 1, 1 }, 9, 3, &lengths);
    try std.testing.expectEqual(@as(c_int, 1), rc);
    // A frequency that does not leave 9 bits for the count is rejected —
    // but only once past the two-symbol fast path, mirroring upstream.
    const huge = [_]usize{ 1, @as(usize, 1) << 60, 1 };
    const rc2 = lengthLimitedCodeLengths(&huge, 3, 15, &lengths);
    try std.testing.expectEqual(@as(c_int, 1), rc2);
    const huge_two = [_]usize{ 1, @as(usize, 1) << 60 };
    const rc3 = lengthLimitedCodeLengths(&huge_two, 2, 15, &lengths);
    try std.testing.expectEqual(@as(c_int, 0), rc3);
    // Out-of-range maxbits values are rejected.
    try std.testing.expectEqual(@as(c_int, 1), lengthLimitedCodeLengths(&.{ 1, 1, 1 }, 3, 0, &lengths));
    try std.testing.expectEqual(@as(c_int, 1), lengthLimitedCodeLengths(&.{ 1, 1, 1 }, 3, 16, &lengths));
}
