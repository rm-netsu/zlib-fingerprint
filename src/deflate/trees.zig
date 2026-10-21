//! Huffman compression output (zlib `trees.c`).
//!
//! Byte-for-byte identical across zlib 1.2.3 .. 1.3.1 (verified by source
//! diffs: the only changes between versions were renames, visibility macros,
//! formatting and the informational `data_type` detection), so this single
//! shared module serves every integrated zlib version.
//!
//! The 1.2.12 `sym_buf` overlay layout (3 bytes per symbol) is used for all
//! versions; it is provably output-equivalent to the older `d_buf`/`l_buf`
//! overlay (same flush points and capacities).

const std = @import("std");
const tables = @import("tables.zig");

/// Temporary tree-dump switch for differential debugging.
pub var dbg_enabled = false;
const st = @import("state.zig");

const DeflateState = st.DeflateState;
const CtData = tables.CtData;

const L_CODES = tables.L_CODES;
const D_CODES = tables.D_CODES;
const BL_CODES = tables.BL_CODES;
const HEAP_SIZE = tables.HEAP_SIZE;
const MAX_BITS = tables.MAX_BITS;
const MAX_BL_BITS = tables.MAX_BL_BITS;
const END_BLOCK = tables.END_BLOCK;
const LITERALS = tables.LITERALS;
const REP_3_6 = tables.REP_3_6;
const REPZ_3_10 = tables.REPZ_3_10;
const REPZ_11_138 = tables.REPZ_11_138;

const SMALLEST = 1;
/// Index within the heap array of least frequent node in the Huffman tree.

/// Static tree descriptor (zlib `static_tree_desc`).
pub const StaticTreeDesc = struct {
    static_tree: ?[]const CtData,
    extra_bits: []const u8,
    extra_base: usize,
    elems: usize,
    max_length: usize,
};

/// Dynamic tree descriptor (zlib `tree_desc`).
pub const TreeDesc = struct {
    dyn_tree: []CtData,
    max_code: i32 = 0,
    stat_desc: *const StaticTreeDesc,
};

pub const static_l_desc = StaticTreeDesc{
    .static_tree = &tables.static_ltree,
    .extra_bits = &tables.extra_lbits,
    .extra_base = LITERALS + 1,
    .elems = L_CODES,
    .max_length = MAX_BITS,
};

pub const static_d_desc = StaticTreeDesc{
    .static_tree = &tables.static_dtree,
    .extra_bits = &tables.extra_dbits,
    .extra_base = 0,
    .elems = D_CODES,
    .max_length = MAX_BITS,
};

pub const static_bl_desc = StaticTreeDesc{
    .static_tree = null,
    .extra_bits = &tables.extra_blbits,
    .extra_base = 0,
    .elems = BL_CODES,
    .max_length = MAX_BL_BITS,
};

// ---------------------------------------------------------------------------
// Bit-length tree construction helpers.
// ---------------------------------------------------------------------------

/// Restore the heap property by moving down the tree starting at node k.
fn pqdownheap(s: *DeflateState, tree: []const CtData, k_in: usize) void {
    const v = s.heap[k_in];
    var k = k_in;
    var j = k << 1; // left son of k
    while (j <= s.heap_len) {
        // Set j to the smallest of the two sons:
        if (j < s.heap_len and smaller(tree, s.heap[j + 1], s.heap[j], &s.depth)) j += 1;
        // Exit if v is smaller than both sons.
        if (smaller(tree, v, s.heap[j], &s.depth)) break;
        // Exchange v with the smallest son.
        s.heap[k] = s.heap[j];
        k = j;
        // And continue down the tree, setting j to the left son of k.
        j <<= 1;
    }
    s.heap[k] = v;
}

/// Compares two subtrees using the tree depth as tie breaker when the
/// subtrees have equal frequency. Indices are usize heap slots.
inline fn smaller(tree: []const CtData, n: i32, m: i32, depth: []const u8) bool {
    const ni: usize = @intCast(n);
    const mi: usize = @intCast(m);
    return tree[ni].freq < tree[mi].freq or
        (tree[ni].freq == tree[mi].freq and depth[ni] <= depth[mi]);
}

/// Compute the optimal bit lengths for a tree and update the total bit
/// length for the current block (zlib `gen_bitlen`).
fn genBitlen(s: *DeflateState, desc: *TreeDesc) void {
    const tree = desc.dyn_tree;
    const max_code = desc.max_code;
    const stree = desc.stat_desc.static_tree;
    const extra = desc.stat_desc.extra_bits;
    const base = desc.stat_desc.extra_base;
    const max_length = desc.stat_desc.max_length;
    var overflow: i32 = 0; // number of elements with bit length too large

    @memset(s.bl_count[0 .. MAX_BITS + 1], 0);

    // In a first pass, compute the optimal bit lengths (which may overflow
    // in the case of the bit length tree).
    tree[@intCast(s.heap[@intCast(s.heap_max)])].dad = 0; // root of the heap: Len = 0

    var h: usize = @intCast(s.heap_max + 1);
    while (h < HEAP_SIZE) : (h += 1) {
        const n: usize = @intCast(s.heap[h]);
        var bits: u32 = @as(u32, tree[@intCast(tree[n].dad)].len()) + 1;
        if (bits > max_length) {
            bits = @intCast(max_length);
            overflow += 1;
        }
        tree[n].dad = @intCast(bits); // overwrite Dad (no longer needed)

        if (@as(i32, @intCast(n)) > max_code) continue; // not a leaf node

        s.bl_count[bits] += 1;
        var xbits: u32 = 0;
        if (n >= base) xbits = extra[n - base];
        const f: u32 = tree[n].freq;
        s.opt_len +%= @as(u64, f) * (bits + xbits);
        if (stree) |str| {
            s.static_len +%= @as(u64, f) * (@as(u32, str[n].len()) + xbits);
        }
    }
    if (overflow == 0) return;

    // Find the first bit length which could increase.
    while (true) {
        var bits: usize = max_length - 1;
        while (s.bl_count[bits] == 0) bits -= 1;
        s.bl_count[bits] -= 1; // move one leaf down the tree
        s.bl_count[bits + 1] += 2; // move one overflow item as its brother
        s.bl_count[max_length] -= 1;
        // The brother of the overflow item also moves one step up, but this
        // does not affect bl_count[max_length].
        overflow -= 2;
        if (overflow <= 0) break;
    }

    // Now recompute all bit lengths, scanning in increasing frequency.
    var bits2: usize = max_length;
    while (bits2 != 0) : (bits2 -= 1) {
        var n_count = s.bl_count[bits2];
        while (n_count != 0) {
            h -= 1;
            const m: i32 = s.heap[h];
            if (m > max_code) continue;
            const mu: usize = @intCast(m);
            if (tree[mu].len() != bits2) {
                s.opt_len +%= (@as(u64, bits2) -% tree[mu].len()) *% tree[mu].freq;
                tree[mu].dad = @intCast(bits2);
            }
            n_count -= 1;
        }
    }
}

/// Generate the codes for a given tree and bit counts (zlib `gen_codes`).
fn genCodes(s: *DeflateState, tree: []CtData, max_code: i32) void {
    var next_code: [MAX_BITS + 1]u32 = undefined;
    var code: u32 = 0;

    // The distribution counts are first used to generate the code values
    // without bit reversal.
    var bits: usize = 1;
    while (bits <= MAX_BITS) : (bits += 1) {
        code = (code + s.bl_count[bits - 1]) << 1;
        next_code[bits] = code;
    }

    var n: usize = 0;
    while (n <= max_code) : (n += 1) {
        const l = tree[n].len();
        if (l == 0) continue;
        // Now reverse the bits.
        tree[n].freq = @intCast(biReverse(next_code[l], l) & 0xffff);
        next_code[l] += 1;
    }
}

/// Reverse the first len bits of a code (zlib `bi_reverse`).
fn biReverse(code_in: u32, len_in: usize) u32 {
    var res: u32 = 0;
    var code = code_in;
    var len = len_in;
    while (len > 0) : (len -= 1) {
        res |= code & 1;
        code >>= 1;
        res <<= 1;
    }
    return res >> 1;
}

/// Construct one Huffman tree and assign the code bit strings and lengths
/// (zlib `build_tree`).
fn buildTree(s: *DeflateState, desc: *TreeDesc) void {
    const tree = desc.dyn_tree;
    const stree = desc.stat_desc.static_tree;
    const elems = desc.stat_desc.elems;
    var max_code: i32 = -1; // largest code with non zero frequency
    var node: usize = 0; // new node being created

    // Construct the initial heap, with least frequent element in
    // heap[SMALLEST].
    s.heap_len = 0;
    s.heap_max = HEAP_SIZE;

    var n: usize = 0;
    while (n < elems) : (n += 1) {
        if (tree[n].freq != 0) {
            s.heap_len += 1;
            s.heap[s.heap_len] = @intCast(n);
            max_code = @intCast(n);
            s.depth[n] = 0;
        } else {
            tree[n].dad = 0; // Len = 0
        }
    }

    // The pkzip format requires that at least one distance code exists, and
    // that at least one bit should be sent even if there is only one
    // possible code. So to avoid special checks later on we force at least
    // two codes of non zero frequency.
    while (s.heap_len < 2) {
        s.heap_len += 1;
        const forced: i32 = if (max_code < 2) max_code + 1 else 0;
        s.heap[s.heap_len] = forced;
        max_code = @max(max_code, forced);
        node = @intCast(forced);
        tree[node].freq = 1;
        s.depth[node] = 0;
        s.opt_len -%= 1;
        if (stree) |str| s.static_len -%= str[node].len();
        // node is 0 or 1 so it does not have extra bits.
    }
    desc.max_code = max_code;

    // The elements heap[heap_len/2+1 .. heap_len] are leaves of the tree,
    // establish sub-heaps of increasing lengths:
    var k = s.heap_len / 2;
    while (k >= 1) : (k -= 1) {
        pqdownheap(s, tree, k);
        if (k == 1) break;
    }

    // Construct the Huffman tree by repeatedly combining the least two
    // frequent nodes.
    node = elems; // next internal node of the tree
    while (true) {
        // pqremove: top = heap[SMALLEST]; heap[SMALLEST] = heap[heap_len--];
        //           pqdownheap(...)
        const top = s.heap[SMALLEST];
        s.heap[SMALLEST] = s.heap[s.heap_len];
        s.heap_len -= 1;
        pqdownheap(s, tree, SMALLEST);
        const n1: i32 = top; // node of least frequency
        const m: i32 = s.heap[SMALLEST]; // node of next least frequency

        s.heap_max -= 1;
        s.heap[s.heap_max] = n1; // keep the nodes sorted by frequency
        s.heap_max -= 1;
        s.heap[s.heap_max] = m;

        // Create a new node father of n and m.
        const nu: usize = @intCast(n1);
        const mu: usize = @intCast(m);
        tree[node].freq = tree[nu].freq +% tree[mu].freq;
        s.depth[node] = @intCast((if (s.depth[nu] >= s.depth[mu]) s.depth[nu] else s.depth[mu]) + 1);
        tree[nu].dad = @intCast(node);
        tree[mu].dad = @intCast(node);

        // Insert the new node in the heap.
        s.heap[SMALLEST] = @intCast(node);
        node += 1;
        pqdownheap(s, tree, SMALLEST);

        if (s.heap_len < 2) break;
    }

    s.heap_max -= 1;
    s.heap[s.heap_max] = s.heap[SMALLEST];

    // At this point, the fields freq and dad are set; generate bit lengths.
    genBitlen(s, desc);

    // The field len is now set; generate the bit codes.
    genCodes(s, tree, max_code);
}

/// Scan a literal or distance tree to determine the frequencies of the codes
/// in the bit length tree (zlib `scan_tree`).
fn scanTree(s: *DeflateState, tree: []CtData, max_code: i32) void {
    var prevlen: i32 = -1; // last emitted length
    var curlen: i32 = undefined;
    var nextlen: i32 = tree[0].len(); // length of next code
    var count: i32 = 0; // repeat count of the current code
    var max_count: i32 = 7;
    var min_count: i32 = 4;

    if (nextlen == 0) {
        max_count = 138;
        min_count = 3;
    }
    tree[@intCast(max_code + 1)].dad = 0xffff; // guard

    var n: i32 = 0;
    while (n <= max_code) : (n += 1) {
        curlen = nextlen;
        nextlen = tree[@intCast(n + 1)].len();
        count += 1;
        if (count < max_count and curlen == nextlen) {
            continue;
        } else if (count < min_count) {
            s.bl_tree[@intCast(curlen)].freq += @intCast(count);
        } else if (curlen != 0) {
            if (curlen != prevlen) s.bl_tree[@intCast(curlen)].freq += 1;
            s.bl_tree[REP_3_6].freq += 1;
        } else if (count <= 10) {
            s.bl_tree[REPZ_3_10].freq += 1;
        } else {
            s.bl_tree[REPZ_11_138].freq += 1;
        }
        count = 0;
        prevlen = curlen;
        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        } else if (curlen == nextlen) {
            max_count = 6;
            min_count = 3;
        } else {
            max_count = 7;
            min_count = 4;
        }
    }
}

/// Send a literal or distance tree in compressed form, using the codes in
/// bl_tree (zlib `send_tree`).
fn sendTree(s: *DeflateState, tree: []const CtData, max_code: i32) void {
    var prevlen: i32 = -1; // last emitted length
    var curlen: i32 = undefined;
    var nextlen: i32 = tree[0].len();
    var count: i32 = 0;
    var max_count: i32 = 7;
    var min_count: i32 = 4;

    // Guard already set by scan_tree.
    if (nextlen == 0) {
        max_count = 138;
        min_count = 3;
    }

    var n: i32 = 0;
    while (n <= max_code) : (n += 1) {
        curlen = nextlen;
        nextlen = tree[@intCast(n + 1)].len();
        count += 1;
        if (count < max_count and curlen == nextlen) {
            continue;
        } else if (count < min_count) {
            while (count != 0) : (count -= 1) {
                s.sendCode(s.bl_tree[0..], @intCast(curlen));
            }
        } else if (curlen != 0) {
            if (curlen != prevlen) {
                s.sendCode(s.bl_tree[0..], @intCast(curlen));
                count -= 1;
            }
            s.sendCode(s.bl_tree[0..], REP_3_6);
            s.sendBits(@intCast(count - 3), 2);
        } else if (count <= 10) {
            s.sendCode(s.bl_tree[0..], REPZ_3_10);
            s.sendBits(@intCast(count - 3), 3);
        } else {
            s.sendCode(s.bl_tree[0..], REPZ_11_138);
            s.sendBits(@intCast(count - 11), 7);
        }
        count = 0;
        prevlen = curlen;
        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        } else if (curlen == nextlen) {
            max_count = 6;
            min_count = 3;
        } else {
            max_count = 7;
            min_count = 4;
        }
    }
}

/// Construct the Huffman tree for the bit lengths and return the index in
/// bl_order of the last bit length code to send (zlib `build_bl_tree`).
fn buildBlTree(s: *DeflateState) i32 {
    // Determine the bit length frequencies for literal and distance trees.
    scanTree(s, s.dyn_ltree[0..], s.l_desc.max_code);
    scanTree(s, s.dyn_dtree[0..], s.d_desc.max_code);

    // Build the bit length tree.
    buildTree(s, &s.bl_desc);

    
        if (dbg_enabled) {
        std.debug.print("BLTREE bl_count:", .{});
        for (0..MAX_BITS + 1) |q| std.debug.print(" {d}", .{s.bl_count[q]});
        std.debug.print(" opt_len={d} static_len={d} lmax={d} dmax={d}\n", .{ s.opt_len, s.static_len, s.l_desc.max_code, s.d_desc.max_code });
    }
    // Determine the number of bit length codes to send. The pkzip format
    // requires that at least 4 bit length codes be sent.
    var max_blindex: i32 = BL_CODES - 1;
    while (max_blindex >= 3) : (max_blindex -= 1) {
        if (s.bl_tree[@intCast(tables.bl_order[@intCast(max_blindex)])].len() != 0) break;
    }
    // Update opt_len to include the bit length tree and counts.
    s.opt_len +%= 3 * (@as(u64, @intCast(max_blindex)) + 1) + 5 + 5 + 4;
    return max_blindex;
}

/// Send the header for a block using dynamic Huffman trees (zlib
/// `send_all_trees`).
fn sendAllTrees(s: *DeflateState, lcodes: i32, dcodes: i32, blcodes: i32) void {
    s.sendBits(@intCast(lcodes - 257), 5); // not +255 as stated in appnote.txt
    s.sendBits(@intCast(dcodes - 1), 5);
    s.sendBits(@intCast(blcodes - 4), 4); // not -3 as stated in appnote.txt
    var rank: i32 = 0;
    while (rank < blcodes) : (rank += 1) {
        s.sendBits(s.bl_tree[@intCast(tables.bl_order[@intCast(rank)])].len(), 3);
    }
    sendTree(s, s.dyn_ltree[0..], lcodes - 1); // literal tree
    sendTree(s, s.dyn_dtree[0..], dcodes - 1); // distance tree
}

// ---------------------------------------------------------------------------
// Public trees.c entry points.
// ---------------------------------------------------------------------------

/// _tr_init: initialize the tree data structures for a new stream.
pub fn trInit(s: *DeflateState) void {
    s.l_desc = .{ .dyn_tree = s.dyn_ltree[0..], .stat_desc = &static_l_desc };
    s.d_desc = .{ .dyn_tree = s.dyn_dtree[0..], .stat_desc = &static_d_desc };
    s.bl_desc = .{ .dyn_tree = s.bl_tree[0..], .stat_desc = &static_bl_desc };

    s.bi_buf = 0;
    s.bi_valid = 0;

    initBlock(s);
}

/// Initialize a new block (zlib `init_block`).
pub fn initBlock(s: *DeflateState) void {
    for (0..L_CODES) |n| s.dyn_ltree[n].freq = 0;
    for (0..D_CODES) |n| s.dyn_dtree[n].freq = 0;
    for (0..BL_CODES) |n| s.bl_tree[n].freq = 0;

    s.dyn_ltree[END_BLOCK].freq = 1;
    s.opt_len = 0;
    s.static_len = 0;
    s.sym_next = 0;
    s.matches = 0;
}

/// _tr_stored_block: send a stored block.
pub fn trStoredBlock(s: *DeflateState, buf: ?[]const u8, stored_len: u32, last: bool) void {
    // Largest reachable block: the legacy level-0 forced-stored path in
    // deflate_huff/deflate_rle (see Compressor.stored_block_headroom).
    // Genuine zlib 1.2.4-1.2.8 overflows its pending buffer here; this port
    // models the idealized stream instead.
    std.debug.assert(@as(usize, s.pending) + stored_len <= s.pending_buf.len);
    s.sendBits(@as(u32, tables.STORED_BLOCK) << 1 | @intFromBool(last), 3); // send block type
    s.biWindup(); // align on byte boundary
    s.putShort(@truncate(stored_len));
    const nlen: u16 = ~@as(u16, @truncate(stored_len));
    s.putShort(nlen);
    if (buf) |data| {
        if (stored_len != 0) {
            @memcpy(s.pending_buf[s.pending .. s.pending + stored_len], data[0..stored_len]);
        }
    }
    s.pending += stored_len;
}

/// _tr_flush_bits: flush the bits in the bit buffer to pending output
/// (leaves at most 7 bits).
pub fn trFlushBits(s: *DeflateState) void {
    s.biFlush();
}

/// _tr_align: send one empty static block (used by Z_PARTIAL_FLUSH only).
pub fn trAlign(s: *DeflateState) void {
    s.sendBits(@as(u32, tables.STATIC_TREES) << 1, 3);
    s.sendCode(&tables.static_ltree, END_BLOCK);
    s.biFlush();
}

/// _tr_flush_block: determine the best encoding for the current block
/// (dynamic trees, static trees or store) and write it out.
pub fn trFlushBlock(s: *DeflateState, buf: ?[]const u8, stored_len: u32, last: bool) void {
    var opt_lenb: u64 = undefined;
    var static_lenb: u64 = undefined;
    var max_blindex: i32 = 0;

    // Build the Huffman trees unless a stored block is forced.
    if (s.level > 0) {
        // (zlib also runs detect_data_type() here; its result is purely
        // informational and never affects the compressed bytes.)

        // Construct the literal and distance trees.
        buildTree(s, &s.l_desc);
        
            if (dbg_enabled) {
                std.debug.print("LTREE lens:", .{});
                for (0..L_CODES) |q| std.debug.print(" {d}", .{s.dyn_ltree[q].len()});
                std.debug.print("\n", .{});
            }
        buildTree(s, &s.d_desc);

        // Build the bit length tree for the above two trees, and get the
        // index in bl_order of the last bit length code to send.
        max_blindex = buildBlTree(s);

        // Determine the best encoding. Compute the block lengths in bytes.
        opt_lenb = (s.opt_len + 3 + 7) >> 3;
        static_lenb = (s.static_len + 3 + 7) >> 3;

        if (static_lenb <= opt_lenb) opt_lenb = static_lenb;
    } else {
        opt_lenb = @as(u64, stored_len) + 5; // force a stored block
        static_lenb = opt_lenb;
    }

    if (@as(u64, stored_len) + 4 <= opt_lenb and buf != null) {
        // 4: two words for the lengths.
        trStoredBlock(s, buf, stored_len, last);
    } else if (s.strategy == tables.Z_FIXED or static_lenb == opt_lenb) {
        s.sendBits(@as(u32, tables.STATIC_TREES) << 1 | @intFromBool(last), 3);
        compressBlock(s, &tables.static_ltree, &tables.static_dtree);
    } else {
        s.sendBits(@as(u32, tables.DYN_TREES) << 1 | @intFromBool(last), 3);
        sendAllTrees(s, s.l_desc.max_code + 1, s.d_desc.max_code + 1, max_blindex + 1);
        compressBlock(s, s.dyn_ltree[0..], s.dyn_dtree[0..]);
    }
    initBlock(s);

    if (last) {
        s.biWindup(); // align on byte boundary
    }
}

/// _tr_tally: save the match info and tally the frequency counts. Returns
/// true if the current block must be flushed.
pub fn trTally(s: *DeflateState, dist: u32, lc: u32) bool {
    s.sym_buf[s.sym_next] = @truncate(dist & 0xff);
    s.sym_buf[s.sym_next + 1] = @truncate(dist >> 8);
    s.sym_buf[s.sym_next + 2] = @truncate(lc & 0xff);
    s.sym_next += 3;

    if (dist == 0) {
        // lc is the unmatched char.
        s.dyn_ltree[lc].freq +%= 1;
    } else {
        s.matches += 1;
        // Here, lc is the match length - MIN_MATCH and
        // dist is the match distance - 1.
        const dist1 = dist - 1;
        s.dyn_ltree[@as(usize, tables.length_code[lc]) + LITERALS + 1].freq +%= 1;
        s.dyn_dtree[tables.dCode(dist1)].freq +%= 1;
    }

    return s.sym_next == s.sym_end;
}

/// compress_block: send the block data compressed using the given Huffman
/// trees (zlib `compress_block`).
fn compressBlock(s: *DeflateState, ltree: []const CtData, dtree: []const CtData) void {
    var sx: usize = 0; // running index in sym_buf

    if (s.sym_next != 0) {
        while (true) {
            var dist: u32 = s.sym_buf[sx];
            dist += @as(u32, s.sym_buf[sx + 1]) << 8;
            var lc: u32 = s.sym_buf[sx + 2];
            sx += 3;
            if (dist == 0) {
                // Send a literal byte.
                s.sendCode(ltree, lc);
            } else {
                // Here, lc is the match length - MIN_MATCH.
                var code: u32 = tables.length_code[lc];
                s.sendCode(ltree, code + LITERALS + 1); // send the length code
                const extra = tables.extra_lbits[code];
                if (extra != 0) {
                    lc -= tables.base_length[code];
                    s.sendBits(lc, extra); // send the extra length bits
                }
                dist -= 1; // dist is now the match distance - 1
                code = @intCast(tables.dCode(dist));
                s.sendCode(dtree, code); // send the distance code
                const dextra = tables.extra_dbits[code];
                if (dextra != 0) {
                    dist -= tables.base_dist[code];
                    s.sendBits(dist, dextra); // send the extra distance bits
                }
            } // literal or match pair?
            if (sx >= s.sym_next) break;
        }
    }

    s.sendCode(ltree, END_BLOCK);
}
