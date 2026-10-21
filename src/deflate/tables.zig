//! Shared deflate constants and static tables.
//!
//! Bit-identical across zlib 1.2.3 .. 1.3.1 (verified by diffing the
//! `deflate.c`/`trees.c`/`trees.h` sources of every release), therefore
//! this module serves every integrated zlib version.
//!
//! The static Huffman tables (static_ltree, static_dtree, _dist_code,
//! _length_code, base_length, base_dist) are computed at comptime with
//! exactly the same algorithm zlib's `tr_static_init()` uses, instead of
//! transcribing the generated `trees.h`.

const std = @import("std");

// ---------------------------------------------------------------------------
// Fixed deflate constants (identical in every zlib version).
// ---------------------------------------------------------------------------

pub const MIN_MATCH = 3;
pub const MAX_MATCH = 258;
/// Matches of length 3 are discarded if their distance exceeds TOO_FAR.
pub const TOO_FAR = 4096;
pub const MIN_LOOKAHEAD = MAX_MATCH + MIN_MATCH + 1;
pub const WIN_INIT = MAX_MATCH;
pub const MAX_BITS = 15;
pub const Buf_size = 16;
/// Maximum stored block length in deflate format (not including header).
pub const MAX_STORED = 65535;
pub const NIL = 0;
pub const DEFLATED = 8;

pub const LENGTH_CODES = 29;
pub const LITERALS = 256;
pub const L_CODES = LITERALS + 1 + LENGTH_CODES;
pub const D_CODES = 30;
pub const BL_CODES = 19;
pub const HEAP_SIZE = 2 * L_CODES + 1;
pub const MAX_BL_BITS = 7;
pub const END_BLOCK = 256;
pub const REP_3_6 = 16;
pub const REPZ_3_10 = 17;
pub const REPZ_11_138 = 18;
pub const DIST_CODE_LEN = 512;

pub const STORED_BLOCK = 0;
pub const STATIC_TREES = 1;
pub const DYN_TREES = 2;

// Stream status values (same numeric values as zlib's deflate.h).
pub const INIT_STATE = 42;
pub const BUSY_STATE = 113;
pub const FINISH_STATE = 666;

// Strategies (zlib.h).
pub const Z_DEFAULT_STRATEGY = 0;
pub const Z_FILTERED = 1;
pub const Z_HUFFMAN_ONLY = 2;
pub const Z_RLE = 3;
pub const Z_FIXED = 4;

// Flush values (zlib.h).
pub const Z_NO_FLUSH = 0;
pub const Z_PARTIAL_FLUSH = 1;
pub const Z_SYNC_FLUSH = 2;
pub const Z_FULL_FLUSH = 3;
pub const Z_FINISH = 4;
pub const Z_BLOCK = 5;

// ---------------------------------------------------------------------------
// Small constant tables (verbatim from trees.c, identical across versions).
// ---------------------------------------------------------------------------

/// Extra bits for each length code.
pub const extra_lbits = [LENGTH_CODES]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
/// Extra bits for each distance code.
pub const extra_dbits = [D_CODES]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
/// Extra bits for each bit length code.
pub const extra_blbits = [BL_CODES]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7 };
/// Order of the bit length code lengths.
pub const bl_order = [BL_CODES]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

// ---------------------------------------------------------------------------
// Per-level configuration (deflate.c `configuration_table`).
// ---------------------------------------------------------------------------

/// Tuning values for one compression level. The actual function dispatch is
/// version-dependent (see deflate.zig); these four values are identical
/// across all integrated zlib versions.
pub const Config = struct {
    good_length: u16,
    max_lazy: u16,
    nice_length: u16,
    max_chain: u16,
    /// true when the level uses deflate_fast (levels 1-3), false for
    /// deflate_slow (levels 4-9). Level 0 is deflate_stored and is
    /// dispatched separately.
    is_fast: bool,
};

pub const configuration_table = [10]Config{
    .{ .good_length = 0, .max_lazy = 0, .nice_length = 0, .max_chain = 0, .is_fast = false }, // 0: stored
    .{ .good_length = 4, .max_lazy = 4, .nice_length = 8, .max_chain = 4, .is_fast = true }, // 1
    .{ .good_length = 4, .max_lazy = 5, .nice_length = 16, .max_chain = 8, .is_fast = true }, // 2
    .{ .good_length = 4, .max_lazy = 6, .nice_length = 32, .max_chain = 32, .is_fast = true }, // 3
    .{ .good_length = 4, .max_lazy = 4, .nice_length = 16, .max_chain = 16, .is_fast = false }, // 4
    .{ .good_length = 8, .max_lazy = 16, .nice_length = 32, .max_chain = 32, .is_fast = false }, // 5
    .{ .good_length = 8, .max_lazy = 16, .nice_length = 128, .max_chain = 128, .is_fast = false }, // 6
    .{ .good_length = 8, .max_lazy = 32, .nice_length = 128, .max_chain = 256, .is_fast = false }, // 7
    .{ .good_length = 32, .max_lazy = 128, .nice_length = 258, .max_chain = 1024, .is_fast = false }, // 8
    .{ .good_length = 32, .max_lazy = 258, .nice_length = 258, .max_chain = 4096, .is_fast = false }, // 9
};

// ---------------------------------------------------------------------------
// Comptime-computed static Huffman tables (zlib tr_static_init()).
// ---------------------------------------------------------------------------

/// A single value and its code string (zlib `ct_data`).
pub const CtData = struct {
    /// frequency count (union'd with `code` in zlib)
    freq: u16 = 0,
    /// father node in Huffman tree (union'd with `len` in zlib)
    dad: u16 = 0,

    pub inline fn code(self: *const CtData) u16 {
        return self.freq;
    }
    pub inline fn len(self: *const CtData) u16 {
        return self.dad;
    }
};

fn biReverseComptime(comptime value_in: u32, comptime length: u32) u32 {
    // zlib bi_reverse(): reverse the first `length` bits of `value`.
    comptime var res: u32 = 0;
    comptime var value = value_in;
    comptime var len = length;
    inline while (len > 0) : (len -= 1) {
        res |= value & 1;
        value >>= 1;
        res <<= 1;
    }
    return res >> 1;
}

const static_ltree_blked = blk: {
    @setEvalBranchQuota(2000000);
    var tree: [L_CODES + 2]CtData = undefined;
    var bl_count = [_]u32{0} ** (MAX_BITS + 1);
    var n: usize = 0;
    while (n <= 143) : (n += 1) {
        tree[n] = .{ .freq = 0, .dad = 8 };
        bl_count[8] += 1;
    }
    while (n <= 255) : (n += 1) {
        tree[n] = .{ .freq = 0, .dad = 9 };
        bl_count[9] += 1;
    }
    while (n <= 279) : (n += 1) {
        tree[n] = .{ .freq = 0, .dad = 7 };
        bl_count[7] += 1;
    }
    while (n <= 287) : (n += 1) {
        tree[n] = .{ .freq = 0, .dad = 8 };
        bl_count[8] += 1;
    }
    // zlib gen_codes(): canonical code assignment without bit reversal.
    var next_code: [MAX_BITS + 1]u32 = undefined;
    var code: u32 = 0;
    var bits: usize = 1;
    while (bits <= MAX_BITS) : (bits += 1) {
        code = (code + bl_count[bits - 1]) << 1;
        next_code[bits] = code;
    }
    n = 0;
    while (n <= L_CODES + 1) : (n += 1) {
        const l = tree[n].len();
        if (l == 0) continue;
        tree[n].freq = @intCast(biReverseComptime(next_code[l], l) & 0xffff);
        next_code[l] += 1;
    }
    break :blk tree;
};

/// The static literal/length tree (zlib `static_ltree`).
pub const static_ltree: [L_CODES + 2]CtData = static_ltree_blked;

/// The static distance tree: trivial, all codes use 5 bits (zlib
/// `static_dtree`).
pub const static_dtree: [D_CODES]CtData = blk: {
    @setEvalBranchQuota(100000);
    var tree: [D_CODES]CtData = undefined;
    for (&tree, 0..) |*e, n| {
        e.* = .{ .freq = @intCast(biReverseComptime(@intCast(n), 5) & 0xffff), .dad = 5 };
    }
    break :blk tree;
};

/// Distance -> distance code mapping; the first 256 entries correspond to
/// distances 3..258, the last 256 to the top 8 bits of 15-bit distances
/// (zlib `_dist_code`). Note: entries [256] and [257] are unreachable via
/// `dCode` (they would mean distances < 256 in the second half) and zlib
/// leaves them zero-initialized; this port reproduces that exactly.
pub const dist_code: [DIST_CODE_LEN]u8 = blk: {
    @setEvalBranchQuota(1000000);
    var codes: [DIST_CODE_LEN]u8 = undefined;
    var dist: usize = 0;
    var code: usize = 0;
    while (code < 16) : (code += 1) {
        var n: usize = 0;
        while (n < (@as(usize, 1) << extra_dbits[code])) : (n += 1) {
            codes[dist] = code;
            dist += 1;
        }
    }
    dist >>= 7;
    while (code < D_CODES) : (code += 1) {
        var n: usize = 0;
        while (n < (@as(usize, 1) << (extra_dbits[code] - 7))) : (n += 1) {
            codes[256 + dist] = code;
            dist += 1;
        }
    }
    break :blk codes;
};

/// Normalized match length (0 == MIN_MATCH) -> length code (zlib
/// `_length_code`).
pub const length_code: [MAX_MATCH - MIN_MATCH + 1]u8 = blk: {
    @setEvalBranchQuota(1000000);
    var codes: [MAX_MATCH - MIN_MATCH + 1]u8 = undefined;
    var length: usize = 0;
    var code: usize = 0;
    while (code < LENGTH_CODES - 1) : (code += 1) {
        var n: usize = 0;
        while (n < (@as(usize, 1) << extra_lbits[code])) : (n += 1) {
            codes[length] = code;
            length += 1;
        }
    }
    // Length 255 (match length 258) is representable two ways; overwrite to
    // use the better encoding (same as zlib).
    codes[length - 1] = code;
    break :blk codes;
};

/// First normalized length for each code (zlib `base_length`).
pub const base_length: [LENGTH_CODES]u16 = blk: {
    @setEvalBranchQuota(1000000);
    var bases: [LENGTH_CODES]u16 = undefined;
    var length: usize = 0;
    var code: usize = 0;
    while (code < LENGTH_CODES - 1) : (code += 1) {
        bases[code] = @intCast(length);
        length += @as(usize, 1) << extra_lbits[code];
    }
    break :blk bases;
};

/// First normalized distance for each code (zlib `base_dist`).
pub const base_dist: [D_CODES]u16 = blk: {
    @setEvalBranchQuota(1000000);
    var bases: [D_CODES]u16 = undefined;
    var dist: usize = 0;
    var code: usize = 0;
    while (code < 16) : (code += 1) {
        bases[code] = @intCast(dist);
        dist += @as(usize, 1) << extra_dbits[code];
    }
    dist >>= 7;
    while (code < D_CODES) : (code += 1) {
        bases[code] = @intCast(dist << 7);
        dist += @as(usize, 1) << (extra_dbits[code] - 7);
    }
    break :blk bases;
};

/// Mapping from a distance to a distance code (`d_code` macro). `dist` is
/// the distance - 1.
pub inline fn dCode(dist: usize) usize {
    return if (dist < 256) dist_code[dist] else dist_code[256 + (dist >> 7)];
}

// ---------------------------------------------------------------------------
// Comptime sanity checks against known zlib table values (trees.h).
// ---------------------------------------------------------------------------

comptime {
    if (static_dtree[1].code() != 16 or static_dtree[1].len() != 5) @compileError("static_dtree mismatch");
    if (length_code[0] != 0 or length_code[7] != 7 or length_code[255] != 28) @compileError("length_code mismatch");
    if (dist_code[0] != 0 or dist_code[4] != 4 or dist_code[258] != 16 or dist_code[511] != 29) @compileError("dist_code mismatch");
    if (static_ltree[0].len() != 8 or static_ltree[0].code() != 12) @compileError("static_ltree[0] mismatch");
    if (static_ltree['a'].len() != 8 or static_ltree['a'].code() != 137) @compileError("static_ltree['a'] mismatch");
    if (static_ltree[END_BLOCK].len() != 7 or static_ltree[END_BLOCK].code() != 0) @compileError("static_ltree[EOB] mismatch");
}
