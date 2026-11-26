//! Native Zig port of zlib-ng 2.2.1's deflate in zlib-compat mode (the
//! one-shot `deflateInit2` + single `deflate(Z_FINISH)` producer model),
//! byte-exact against the reference build on x86-64 (UNALIGNED_OK +
//! UNALIGNED64_OK little-endian configuration, which all 64-bit x86 builds
//! use; the arch-dispatched AVX2/SSE2 kernels compute the same values as
//! the generic kernels ported here — verified empirically against the
//! reference binary).
//!
//! Ported modules (zlib-ng 2.2.1 → this file):
//!   deflate.c       → Compressor: deflateInit2/Reset/lm_init state,
//!                     deflate() one-shot driver, fill_window, read_buf
//!   deflate_stored.c → deflate_stored      (level 0)
//!   deflate_quick.c  → deflate_quick       (level 1; static blocks only)
//!   deflate_fast.c   → deflate_fast        (level 2)
//!   deflate_medium.c → deflate_medium      (levels 3-6; insert_match,
//!                     fizzle_matches)
//!   deflate_slow.c   → deflate_slow         (levels 7-9)
//!   deflate_rle.c    → deflate_rle         (Z_RLE)
//!   deflate_huff.c   → deflate_huff         (Z_HUFFMAN_ONLY)
//!   match_tpl.h      → longestMatch / longestMatchSlow (UNALIGNED64
//!                     filter semantics: 2/4/8-byte scan_start/scan_end
//!                     checks by best_len class)
//!   compare256_c.c   → compare256
//!   insert_string.c  → integer hash (h = LE32 * 2654435761 >> 16)
//!   insert_string_roll.c → rolling hash (h = (h << 5) ^ byte), used at
//!                     level 9 (max_chain_length > 1024)
//!   slide_hash_c.c   → slideHash
//!   trees.c          → trees: init_block, tally, flush_block, build_tree,
//!                     scan_tree/send_tree, compress_block, stored_block,
//!                     detect_data_type, gen_bitlen/gen_codes
//!   trees_emit.h     → send_bits (64-bit bi_buf), emit_lit/dist/tree/
//!                     end_block/align, bi_windup, tr_flush_bits
//!
//! Producer-model notes (what the reference wrapper does):
//!   * deflateInit2(level, 8=Z_DEFLATED, windowBits, memLevel, strategy),
//!     windowBits 9..15 (8 is remapped to 9 like the C);
//!   * a single deflate(Z_FINISH) with an output buffer of
//!     deflateBound+64 bytes — avail_out is never exhausted, so the
//!     avail_out-dependent paths always take their "plenty of room"
//!     branch;
//!   * the pending window/pending buffers are exact-size like the C
//!     allocation (the LIT_MEM symbol buffers live separately — the
//!     overlay in C is a memory optimization that never changes bytes);
//!   * the header (CMF/FLG with zlib-ng's FLEVEL formula, identical to
//!     stock zlib's) and the MSB Adler-32 trailer.

const std = @import("std");
const tables = @import("tables.zig");

const std_min_match: u32 = 3;
const std_max_match: u32 = 258;
const want_min_match: u32 = 4;
const min_lookahead: u32 = std_max_match + std_min_match + 1;
const win_init: u32 = std_max_match;
const max_stored: u32 = 65535;
const hash_size: usize = 65536;
const hash_mask: u32 = 65535;
const length_codes: usize = 29;
const literals: usize = 256;
const l_codes: usize = 256 + 1 + 29;
const d_codes: usize = 30;
const bl_codes: usize = 19;
const heap_size: usize = 2 * l_codes + 1;
const max_bits: usize = 15;
const max_bl_bits: usize = 7;
const rep_3_6: usize = 16;
const repz_3_10: usize = 17;
const repz_11_138: usize = 18;
const bit_buf_size: u32 = 64;
const early_exit_trigger_level: i32 = 5;

const end_block: usize = 256;
const stored_block_t: u32 = 0;
const static_trees_t: u32 = 1;
const dyn_trees_t: u32 = 2;

const Z_NO_FLUSH: i32 = 0;
const Z_PARTIAL_FLUSH: i32 = 1;
const Z_SYNC_FLUSH: i32 = 2;
const Z_FULL_FLUSH: i32 = 3;
const Z_FINISH: i32 = 4;
const Z_BLOCK: i32 = 5;

const d_code = struct {
    fn of(dist: u32) u32 {
        return if (dist < 256)
            tables.dist_code[dist]
        else
            tables.dist_code[256 + (dist >> 7)];
    }
};

const BlockState = enum { need_more, block_done, finish_started, finish_done };

/// configuration_table[10] of the default build (QUICK and MEDIUM
/// strategies enabled — the release configuration). The `func` column of
/// the C table (level -> strategy function) is expressed by
/// `compressFuncFor`: 0 stored, 1 quick, 2 fast, 3-6 medium, 7-9 slow.
const Config = struct { good: u16, lazy: u16, nice: u16, chain: u16 };
const configuration_table = [10]Config{
    .{ .good = 0, .lazy = 0, .nice = 0, .chain = 0 },
    .{ .good = 0, .lazy = 0, .nice = 0, .chain = 0 },
    .{ .good = 4, .lazy = 4, .nice = 8, .chain = 4 },
    .{ .good = 4, .lazy = 6, .nice = 16, .chain = 6 },
    .{ .good = 4, .lazy = 12, .nice = 32, .chain = 24 },
    .{ .good = 8, .lazy = 16, .nice = 32, .chain = 32 },
    .{ .good = 8, .lazy = 16, .nice = 128, .chain = 128 },
    .{ .good = 8, .lazy = 32, .nice = 128, .chain = 256 },
    .{ .good = 32, .lazy = 128, .nice = 258, .chain = 1024 },
    .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
};

/// The configuration_table's func dispatch (by level).
fn compressFuncFor(level: i32) *const fn (self: *Compressor, flush: i32) BlockState {
    return switch (level) {
        0 => Compressor.deflate_stored,
        1 => Compressor.deflate_quick,
        2 => Compressor.deflate_fast,
        3, 4, 5, 6 => Compressor.deflate_medium,
        else => Compressor.deflate_slow,
    };
}

const StaticTreeDesc = struct {
    tree: ?[]const tables.CtData,
    extra: []const u8,
    extra_base: usize,
    elems: usize,
    max_length: u32,
};

const static_l_desc = StaticTreeDesc{
    .tree = &tables.static_ltree,
    .extra = &tables.extra_lbits,
    .extra_base = literals + 1,
    .elems = l_codes,
    .max_length = max_bits,
};
const static_d_desc = StaticTreeDesc{
    .tree = &tables.static_dtree,
    .extra = &tables.extra_dbits,
    .extra_base = 0,
    .elems = d_codes,
    .max_length = max_bits,
};
const static_bl_desc = StaticTreeDesc{
    .tree = null,
    .extra = &tables.extra_blbits,
    .extra_base = 0,
    .elems = bl_codes,
    .max_length = max_bl_bits,
};

const TreeDesc = struct {
    max_code: i32 = -1,
    stat_desc: *const StaticTreeDesc,
};

/// The `match` struct of deflate_medium.c.
const MediumMatch = struct {
    match_start: u16 = 0,
    strstart: u16 = 0,
    orgstart: u16 = 0,
    match_length: u16 = 0,
};

pub const Compressor = struct {
    gpa: std.mem.Allocator,

    // Parameters / level state
    level: i32 = 6,
    strategy: u8 = 0,
    w_bits: u5 = 15,
    w_size: u32 = 32768,
    w_mask: u32 = 32767,
    window_size: u32 = 65536,
    lit_bufsize: u32 = 16384,
    pending_buf_size: u32 = 65536,
    sym_end: u32 = 16383,
    max_lazy_match: u32 = 0,
    good_match: u32 = 0,
    nice_match: i32 = 0,
    max_chain_length: u32 = 0,
    rolling_hash: bool = false,
    block_open: i32 = 0,

    // Buffers
    window: []u8 = &.{}, // 2 * w_size + guard (zeroed)
    prev: []u16 = &.{}, // w_size
    head: []u16 = &.{}, // 65536
    pending_buf: []u8 = &.{}, // pending_buf_size + slack
    d_buf: []u16 = &.{}, // lit_bufsize
    l_buf: []u8 = &.{}, // lit_bufsize
    dyn_ltree: [heap_size]tables.CtData = undefined,
    dyn_dtree: [2 * d_codes + 1]tables.CtData = undefined,
    bl_tree: [2 * bl_codes + 1]tables.CtData = undefined,
    l_desc: TreeDesc = .{ .stat_desc = &static_l_desc },
    d_desc: TreeDesc = .{ .stat_desc = &static_d_desc },
    bl_desc: TreeDesc = .{ .stat_desc = &static_bl_desc },
    heap: [heap_size]i32 = undefined,
    heap_len: i32 = 0,
    heap_max: i32 = 0,
    depth: [heap_size]u8 = undefined,
    bl_count: [max_bits + 1]u16 = undefined,

    // Match state
    strstart: u32 = 0,
    lookahead: u32 = 0,
    match_start: u32 = 0,
    prev_match: u16 = 0,
    match_available: i32 = 0,
    prev_length: u32 = 0,
    match_length: u32 = 0,
    block_start: i64 = 0,
    insert: u32 = 0,
    high_water: u32 = 0,
    ins_h: u32 = 0,
    matches: u32 = 0,

    // Symbol bookkeeping
    sym_next: u32 = 0,
    opt_len: u64 = 0,
    static_len: u64 = 0,

    // Bit output
    bi_buf: u64 = 0,
    /// int32_t in the C: bi_windup can drive it negative mid-computation.
    bi_valid: i32 = 0,
    pending: u32 = 0,

    // Stream state (one-shot: pending always fits, avail_out never ends)
    status: i32 = 1, // INIT_STATE
    wrap: i32 = 1,
    last_flush: i32 = -2,
    data_type: i32 = 2, // Z_UNKNOWN

    // I/O
    src: []const u8 = &.{},
    src_pos: usize = 0,
    adler: u32 = 1,
    out: std.ArrayList(u8) = .empty,

    // Scratch for longest_match (scan_start/scan_end by width class)
    scan_start: [8]u8 = undefined,
    scan_end: [8]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator) Compressor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Compressor) void {
        self.deinitBuffers();
        self.out.deinit(self.gpa);
    }

    fn deinitBuffers(self: *Compressor) void {
        // The Compressor is reused across calls (the search holds one
        // instance); deflateInit2 re-allocates per parameter set.
        if (self.window.len != 0) self.gpa.free(self.window);
        if (self.prev.len != 0) self.gpa.free(self.prev);
        if (self.head.len != 0) self.gpa.free(self.head);
        if (self.pending_buf.len != 0) self.gpa.free(self.pending_buf);
        if (self.d_buf.len != 0) self.gpa.free(self.d_buf);
        if (self.l_buf.len != 0) self.gpa.free(self.l_buf);
        self.window = &.{};
        self.prev = &.{};
        self.head = &.{};
        self.pending_buf = &.{};
        self.d_buf = &.{};
        self.l_buf = &.{};
    }

    /// deflateInit2 + single deflate(Z_FINISH); returns the compressed
    /// zlib stream. Errors on the C's Z_STREAM_ERROR parameter rejects.
    pub fn compressZlib(self: *Compressor, input: []const u8, level: i32, mem_level: u8, strategy: u8, window_bits: u8) ![]u8 {
        if (level < 0 or level > 9) return error.InvalidLevel;
        if (mem_level < 1 or mem_level > 9) return error.InvalidMemLevel;
        if (strategy > 4) return error.InvalidStrategy;
        var wb: u5 = @intCast(window_bits);
        if (wb == 8) wb = 9; // "until 256-byte window bug fixed"
        if (wb < 9 or wb > 15) return error.InvalidWindowBits;

        self.out = .empty;
        errdefer self.out.deinit(self.gpa);
        try self.deflateInit2(input.len, level, mem_level, strategy, wb);

        self.src = input;
        self.src_pos = 0;
        self.adler = 1;
        const out_estimate = input.len + (input.len >> 3) + (input.len >> 6) + 1024;
        try self.out.ensureTotalCapacity(self.gpa, out_estimate);

        try self.deflateFinish();
        return self.out.toOwnedSlice(self.gpa);
    }

    fn deflateInit2(self: *Compressor, input_len: usize, level: i32, mem_level: u8, strategy: u8, w_bits: u5) !void {
        self.w_bits = w_bits;
        self.w_size = @as(u32, 1) << w_bits;
        self.w_mask = self.w_size - 1;
        const lit_bufsize: u32 = @as(u32, 1) << @intCast(@as(u32, mem_level) + 6);
        self.lit_bufsize = lit_bufsize;
        self.pending_buf_size = lit_bufsize * 4;
        self.sym_end = lit_bufsize - 1;
        self.level = level;
        self.strategy = strategy;
        self.block_open = 0;
        self.status = 1; // INIT_STATE
        self.wrap = 1;

        // Allocs (window padded like the C allocation: 2*w_size + 64).
        // Free the previous parameter set's buffers first: the search
        // reuses one Compressor across many (level, memLevel) candidates.
        self.deinitBuffers();
        errdefer self.deinitBuffers();
        self.window = try self.gpa.alloc(u8, 2 * self.w_size + 64);
        self.prev = try self.gpa.alloc(u16, self.w_size);
        self.head = try self.gpa.alloc(u16, hash_size);
        self.pending_buf = try self.gpa.alloc(u8, self.pending_buf_size + 64);
        self.d_buf = try self.gpa.alloc(u16, lit_bufsize + 8);
        self.l_buf = try self.gpa.alloc(u8, lit_bufsize + 8);

        self.deflateReset(input_len);
    }

    fn deflateReset(self: *Compressor, input_len: usize) void {
        self.pending = 0;
        self.out.clearRetainingCapacity();
        _ = input_len;
        self.status = 1;
        self.adler = 1;
        self.last_flush = -2;
        self.trInit();
        self.lmInit();
    }

    fn lmInit(self: *Compressor) void {
        self.window_size = 2 * self.w_size;
        self.clearHash();
        self.lmSetLevel(self.level);
        self.strstart = 0;
        self.block_start = 0;
        self.lookahead = 0;
        self.insert = 0;
        self.prev_length = 0;
        self.match_available = 0;
        self.match_start = 0;
        self.ins_h = 0;
    }

    fn lmSetLevel(self: *Compressor, level: i32) void {
        const cfg = configuration_table[@intCast(level)];
        self.max_lazy_match = cfg.lazy;
        self.good_match = cfg.good;
        self.nice_match = cfg.nice;
        self.max_chain_length = cfg.chain;
        // Level 9 (chain > 1024): rolling hash.
        self.rolling_hash = self.max_chain_length > 1024;
        self.level = level;
    }

    fn clearHash(self: *Compressor) void {
        @memset(self.head, 0);
    }

    fn slideHash(self: *Compressor) void {
        const wsize: u16 = @intCast(self.w_size);
        for (self.head) |*h| {
            const m = h.*;
            h.* = if (m >= wsize) m - wsize else 0;
        }
        for (self.prev) |*p| {
            const m = p.*;
            p.* = if (m >= wsize) m - wsize else 0;
        }
    }

    // ---- hash functions ------------------------------------------------

    inline fn hashOf(window: []const u8, pos: u32) u32 {
        // Integer hash: val = 4 bytes little-endian at pos.
        const val: u32 = @as(u32, window[pos]) | (@as(u32, window[pos + 1]) << 8) |
            (@as(u32, window[pos + 2]) << 16) | (@as(u32, window[pos + 3]) << 24);
        return ((val *% 2654435761) >> 16) & hash_mask;
    }

    /// quick_insert_string (integer variant): hash at str from 4 bytes;
    /// returns the previous chain head.
    fn quickInsertString(self: *Compressor, str: u32) u16 {
        const hm = hashOf(self.window, str);
        const head = self.head[hm];
        if (head != str) {
            self.prev[str & self.w_mask] = head;
            self.head[hm] = @intCast(str);
        }
        return head;
    }

    /// insert_string (integer variant): hash each of count positions.
    fn insertString(self: *Compressor, str: u32, count: u32) void {
        var idx: u16 = @intCast(str & 0xFFFF);
        var pos = str;
        var i: u32 = 0;
        while (i < count) : ({
            i += 1;
            idx +%= 1;
            pos += 1;
        }) {
            const hm = hashOf(self.window, pos);
            const head = self.head[hm];
            if (head != idx) {
                self.prev[idx & self.w_mask] = head;
                self.head[hm] = idx;
            }
        }
    }

    /// quick_insert_string_roll: rolling hash; hash at str+2, byte-wise.
    fn quickInsertStringRoll(self: *Compressor, str: u32) u16 {
        const val: u32 = self.window[str + 2];
        self.ins_h = ((self.ins_h << 5) ^ (val & 0xFF)) & 32767;
        const hm = self.ins_h;
        const head = self.head[hm];
        if (head != str) {
            self.prev[str & self.w_mask] = head;
            self.head[hm] = @intCast(str);
        }
        return head;
    }

    /// insert_string_roll.
    fn insertStringRoll(self: *Compressor, str: u32, count: u32) void {
        var idx: u16 = @intCast(str & 0xFFFF);
        var pos = str + 2;
        var i: u32 = 0;
        while (i < count) : ({
            i += 1;
            idx +%= 1;
            pos += 1;
        }) {
            const val: u32 = self.window[pos];
            self.ins_h = ((self.ins_h << 5) ^ (val & 0xFF)) & 32767;
            const hm = self.ins_h;
            const head = self.head[hm];
            if (head != idx) {
                self.prev[idx & self.w_mask] = head;
                self.head[hm] = idx;
            }
        }
    }

    inline fn quickInsert(self: *Compressor, str: u32) u16 {
        return if (self.rolling_hash) self.quickInsertStringRoll(str) else self.quickInsertString(str);
    }

    inline fn insertStrings(self: *Compressor, str: u32, count: u32) void {
        if (self.rolling_hash) self.insertStringRoll(str, count) else self.insertString(str, count);
    }

    /// update_hash variants used by longest_match_slow and fill_window.
    inline fn updateHash(self: *Compressor, h: u32, val: u32) u32 {
        if (self.rolling_hash) {
            return ((h << 5) ^ (val & 0xFF)) & 32767;
        }
        return ((val *% 2654435761) >> 16) & hash_mask;
    }

    // ---- I/O ------------------------------------------------------------

    /// read_buf: copy from src (updating the adler for wrap==1).
    fn readBuf(self: *Compressor, buf: []u8, size: u32) u32 {
        const len: u32 = @intCast(@min(self.src.len - self.src_pos, size));
        if (len == 0) return 0;
        @memcpy(buf[0..len], self.src[self.src_pos..][0..len]);
        if (self.wrap == 1) {
            self.adler = adler32(self.adler, self.src[self.src_pos..][0..len]);
        }
        self.src_pos += len;
        return len;
    }

    /// flush_pending: everything always fits (avail_out never ends).
    fn flushPending(self: *Compressor) void {
        self.trFlushBits();
        if (self.pending == 0) return;
        self.out.appendSlice(self.gpa, self.pending_buf[0..self.pending]) catch @panic("output allocation failed");
        self.pending = 0;
    }

    // ---- bit output ------------------------------------------------------

    inline fn putByte(self: *Compressor, b: u8) void {
        self.pending_buf[self.pending] = b;
        self.pending += 1;
    }

    inline fn putShort(self: *Compressor, w: u16) void {
        std.mem.writeInt(u16, self.pending_buf[self.pending..][0..2], w, .little);
        self.pending += 2;
    }

    inline fn putShortMsb(self: *Compressor, w: u16) void {
        std.mem.writeInt(u16, self.pending_buf[self.pending..][0..2], w, .big);
        self.pending += 2;
    }

    inline fn putUint32(self: *Compressor, dw: u32) void {
        std.mem.writeInt(u32, self.pending_buf[self.pending..][0..4], dw, .little);
        self.pending += 4;
    }

    inline fn putUint32Msb(self: *Compressor, dw: u32) void {
        std.mem.writeInt(u32, self.pending_buf[self.pending..][0..4], dw, .big);
        self.pending += 4;
    }

    inline fn putUint64(self: *Compressor, lld: u64) void {
        std.mem.writeInt(u64, self.pending_buf[self.pending..][0..8], lld, .little);
        self.pending += 8;
    }

    /// send_bits macro over the 64-bit bi_buf.
    inline fn sendBits(self: *Compressor, t_val: u64, t_len: u5) void {
        const total_bits: i32 = self.bi_valid + t_len;
        if (total_bits < @as(i32, bit_buf_size)) {
            self.bi_buf |= t_val << @intCast(self.bi_valid);
            self.bi_valid = total_bits;
        } else if (self.bi_valid == @as(i32, bit_buf_size)) {
            self.putUint64(self.bi_buf);
            self.bi_buf = t_val;
            self.bi_valid = t_len;
        } else {
            self.bi_buf |= t_val << @intCast(self.bi_valid);
            self.putUint64(self.bi_buf);
            self.bi_buf = t_val >> @as(u6, @intCast(@as(i32, bit_buf_size) - self.bi_valid));
            self.bi_valid = total_bits - bit_buf_size;
        }
    }

    /// tr_flush_bits: drain bi_buf to whole bytes (keeping <= 7 bits).
    fn trFlushBits(self: *Compressor) void {
        if (self.bi_valid >= 48) {
            self.putUint32(@truncate(self.bi_buf));
            self.putShort(@truncate(self.bi_buf >> 32));
            self.bi_buf >>= 48;
            self.bi_valid -= 48;
        } else if (self.bi_valid >= 32) {
            self.putUint32(@truncate(self.bi_buf));
            self.bi_buf >>= 32;
            self.bi_valid -= 32;
        }
        if (self.bi_valid >= 16) {
            self.putShort(@truncate(self.bi_buf));
            self.bi_buf >>= 16;
            self.bi_valid -= 16;
        }
        if (self.bi_valid >= 8) {
            self.putByte(@truncate(self.bi_buf));
            self.bi_buf >>= 8;
            self.bi_valid -= 8;
        }
    }

    fn biWindup(self: *Compressor) void {
        if (self.bi_valid > 56) {
            self.putUint64(self.bi_buf);
        } else {
            if (self.bi_valid > 24) {
                self.putUint32(@truncate(self.bi_buf));
                self.bi_buf >>= 32;
                self.bi_valid -= 32;
            }
            if (self.bi_valid > 8) {
                self.putShort(@truncate(self.bi_buf));
                self.bi_buf >>= 16;
                self.bi_valid -= 16;
            }
            if (self.bi_valid > 0) {
                self.putByte(@truncate(self.bi_buf));
            }
        }
        self.bi_buf = 0;
        self.bi_valid = 0;
    }

    // ---- trees -----------------------------------------------------------

    fn trInit(self: *Compressor) void {
        self.l_desc = .{ .stat_desc = &static_l_desc };
        self.d_desc = .{ .stat_desc = &static_d_desc };
        self.bl_desc = .{ .stat_desc = &static_bl_desc };
        self.bi_buf = 0;
        self.bi_valid = 0;
        self.initBlock();
    }

    fn initBlock(self: *Compressor) void {
        // ct_data union mapping (see tables.zig): fc.freq shares the `code`
        // slot, dl.dad shares the `len` slot. init_block zeroes the
        // frequencies (the C leaves len/dad stale; build_tree assigns them
        // fully before any read).
        for (0..l_codes) |n| self.dyn_ltree[n] = .{ .code = 0, .len = 0 };
        for (0..d_codes) |n| self.dyn_dtree[n] = .{ .code = 0, .len = 0 };
        for (0..bl_codes) |n| self.bl_tree[n] = .{ .code = 0, .len = 0 };
        self.dyn_ltree[end_block] = .{ .code = 1, .len = 0 };
        self.opt_len = 0;
        self.static_len = 0;
        self.sym_next = 0;
        self.matches = 0;
    }

    /// zng_tr_tally_lit; true when the block must be flushed.
    fn tallyLit(self: *Compressor, c: u8) bool {
        self.d_buf[self.sym_next] = 0;
        self.l_buf[self.sym_next] = c;
        self.sym_next += 1;
        self.dyn_ltree[c].code +%= 1; // Freq shares the code slot
        return self.sym_next == self.sym_end;
    }

    /// zng_tr_tally_dist; dist is the real distance, len is length-3.
    fn tallyDist(self: *Compressor, dist: u32, len: u32) bool {
        self.d_buf[self.sym_next] = @intCast(dist);
        self.l_buf[self.sym_next] = @intCast(len);
        self.sym_next += 1;
        self.matches += 1;
        const d = dist - 1;
        self.dyn_ltree[tables.length_code[len] + literals + 1].code +%= 1;
        self.dyn_dtree[d_code.of(d)].code +%= 1;
        return self.sym_next == self.sym_end;
    }

    /// Emit a literal through the given tree (zng_emit_lit).
    inline fn emitLit(self: *Compressor, ltree: []const tables.CtData, c: u32) u32 {
        self.sendBits(ltree[c].code, @intCast(ltree[c].len));
        return ltree[c].len;
    }

    /// Emit a match (zng_emit_dist); lc = length - 3.
    inline fn emitDist(self: *Compressor, ltree: []const tables.CtData, dtree: []const tables.CtData, lc_in: u32, dist_in: u32) u32 {
        var lc = lc_in;
        var dist = dist_in;
        var match_bits: u64 = 0;
        var match_bits_len: u32 = 0;

        const code: u8 = tables.length_code[lc];
        const c: u32 = @as(u32, code) + @as(u32, literals) + 1;
        match_bits = ltree[c].code;
        match_bits_len = ltree[c].len;
        const extra: u32 = tables.extra_lbits[code];
        if (extra != 0) {
            lc -= tables.base_length[code];
            match_bits |= @as(u64, lc) << @intCast(match_bits_len);
            match_bits_len += extra;
        }

        dist -= 1;
        const dcode = d_code.of(dist);
        match_bits |= @as(u64, dtree[dcode].code) << @intCast(match_bits_len);
        match_bits_len += dtree[dcode].len;
        const dextra: u32 = tables.extra_dbits[dcode];
        if (dextra != 0) {
            dist -= tables.base_dist[dcode];
            match_bits |= @as(u64, dist) << @intCast(match_bits_len);
            match_bits_len += dextra;
        }

        self.sendBits(match_bits, @intCast(match_bits_len));
        return match_bits_len;
    }

    inline fn emitEndBlock(self: *Compressor, ltree: []const tables.CtData, last: bool) void {
        _ = last;
        self.sendBits(ltree[end_block].code, @intCast(ltree[end_block].len));
    }

    /// zng_tr_emit_end_block: emit the end-of-block code and align the bit
    /// buffer to a byte boundary when this is the last block.
    inline fn trEmitEndBlock(self: *Compressor, ltree: []const tables.CtData, last: bool) void {
        self.emitEndBlock(ltree, last);
        if (last) self.emitAlign();
    }

    inline fn emitTree(self: *Compressor, tree_type: u32, last: bool) void {
        const header_bits: u32 = (tree_type << 1) + @intFromBool(last);
        self.sendBits(header_bits, 3);
    }

    fn emitAlign(self: *Compressor) void {
        self.biWindup();
    }

    /// zng_tr_stored_block.
    fn trStoredBlock(self: *Compressor, buf: ?[*]const u8, stored_len: u32, last: bool) void {
        self.emitTree(stored_block_t, last);
        self.emitAlign();
        self.putShort(@intCast(stored_len));
        self.putShort(@truncate(~stored_len));
        if (stored_len != 0) {
            @memcpy(self.pending_buf[self.pending..][0..stored_len], buf.?[0..stored_len]);
            self.pending += stored_len;
        }
    }

    fn smaller(tree: []const tables.CtData, n: i32, m: i32, depth: []const u8) bool {
        return tree[@intCast(n)].code < tree[@intCast(m)].code or
            (tree[@intCast(n)].code == tree[@intCast(m)].code and depth[@intCast(n)] <= depth[@intCast(m)]);
    }

    fn pqdownheap(self: *Compressor, tree: []tables.CtData, k: i32) void {
        const v = self.heap[@intCast(k)];
        var j = k << 1;
        var kk = k;
        while (j <= self.heap_len) {
            if (j < self.heap_len and smaller(tree, self.heap[@intCast(j + 1)], self.heap[@intCast(j)], &self.depth)) {
                j += 1;
            }
            if (smaller(tree, v, self.heap[@intCast(j)], &self.depth)) break;
            self.heap[@intCast(kk)] = self.heap[@intCast(j)];
            kk = j;
            j <<= 1;
        }
        self.heap[@intCast(kk)] = v;
    }

    fn genBitlen(self: *Compressor, desc: *TreeDesc) void {
        const tree = self.currentTree(desc);
        const max_code = desc.max_code;
        const stree = desc.stat_desc.tree;
        const extra = desc.stat_desc.extra;
        const base = desc.stat_desc.extra_base;
        const max_length = desc.stat_desc.max_length;
        var overflow: i32 = 0;

        for (0..max_bits + 1) |b| self.bl_count[b] = 0;

        tree[@intCast(self.heap[@intCast(self.heap_max)])].len = 0;

        var h: i32 = self.heap_max + 1;
        while (h < heap_size) : (h += 1) {
            const n = self.heap[@intCast(h)];
            var bits: u32 = @as(u32, tree[@intCast(tree[@intCast(n)].len)].len) + 1;
            if (bits > max_length) {
                bits = max_length;
                overflow += 1;
            }
            tree[@intCast(n)].len = @intCast(bits);
            if (n > max_code) continue;
            self.bl_count[bits] += 1;
            var xbits: u32 = 0;
            if (@as(usize, @intCast(n)) >= base)
                xbits = extra[@as(usize, @intCast(n)) - base];
            const f: u32 = tree[@intCast(n)].code; // Freq (the code slot)
            self.opt_len += @as(u64, f) * (bits + xbits);
            if (stree) |st|
                self.static_len += @as(u64, f) * (@as(u64, st[@intCast(n)].len) + xbits);
        }
        if (overflow == 0) return;

        while (overflow > 0) {
            var bits: u32 = max_length - 1;
            while (self.bl_count[bits] == 0) bits -= 1;
            self.bl_count[bits] -= 1;
            self.bl_count[bits + 1] += 2;
            self.bl_count[max_length] -= 1;
            overflow -= 2;
        }

        var bits: u32 = max_length;
        while (bits != 0) : (bits -= 1) {
            var n: i32 = self.bl_count[bits];
            while (n != 0) {
                h -= 1;
                const m = self.heap[@intCast(h)];
                if (m > max_code) continue;
                if (tree[@intCast(m)].len != bits) {
                    self.opt_len += (bits - tree[@intCast(m)].len) * tree[@intCast(m)].code;
                    tree[@intCast(m)].len = @intCast(bits);
                }
                n -= 1;
            }
        }
    }

    fn genCodes(tree: []tables.CtData, max_code: i32, bl_count: []u16) void {
        var next_code: [max_bits + 1]u16 = undefined;
        var code: u32 = 0;
        var bits: usize = 1;
        while (bits <= max_bits) : (bits += 1) {
            code = (code + bl_count[bits - 1]) << 1;
            next_code[bits] = @intCast(code);
        }
        var n: usize = 0;
        while (n <= @as(usize, @intCast(max_code))) : (n += 1) {
            const len: usize = tree[n].len;
            if (len == 0) continue;
            tree[n].code = biReverse(next_code[len], len);
            next_code[len] += 1;
        }
    }

    fn currentTree(self: *Compressor, desc: *TreeDesc) []tables.CtData {
        if (desc.stat_desc == &static_l_desc) return &self.dyn_ltree;
        if (desc.stat_desc == &static_d_desc) return &self.dyn_dtree;
        return &self.bl_tree;
    }

    fn buildTree(self: *Compressor, desc: *TreeDesc) void {
        const tree: []tables.CtData = self.currentTree(desc);
        const stree = desc.stat_desc.tree;
        const elems: i32 = @intCast(desc.stat_desc.elems);
        var n: i32 = undefined;
        var m: i32 = undefined;
        var max_code: i32 = -1;
        var node: i32 = undefined;

        self.heap_len = 0;
        self.heap_max = heap_size;

        var ni: i32 = 0;
        while (ni < elems) : (ni += 1) {
            const i: usize = @intCast(ni);
            if (tree[i].code != 0) { // Freq in the code slot pre-build
                self.heap_len += 1;
                self.heap[@intCast(self.heap_len)] = ni;
                max_code = ni;
                self.depth[i] = 0;
            } else {
                tree[i].len = 0;
            }
        }

        while (self.heap_len < 2) {
            self.heap_len += 1;
            node = if (max_code < 2) blk: {
                max_code += 1;
                break :blk max_code;
            } else 0;
            self.heap[@intCast(self.heap_len)] = node;
            tree[@intCast(node)].code = 1;
            self.depth[@intCast(node)] = 0;
            self.opt_len -%= 1;
            if (stree) |st| self.static_len -%= st[@intCast(node)].len;
        }
        desc.max_code = max_code;

        n = @divTrunc(self.heap_len, 2);
        while (n >= 1) : (n -= 1) {
            self.pqdownheap(tree, n);
        }

        node = elems;
        while (true) {
            // pqremove
            n = self.heap[1];
            self.heap[1] = self.heap[@intCast(self.heap_len)];
            self.heap_len -= 1;
            self.pqdownheap(tree, 1);
            m = self.heap[1];

            self.heap_max -= 1;
            self.heap[@intCast(self.heap_max)] = n;
            self.heap_max -= 1;
            self.heap[@intCast(self.heap_max)] = m;

            tree[@intCast(node)].code = @intCast(tree[@intCast(n)].code + tree[@intCast(m)].code);
            self.depth[@intCast(node)] = @max(self.depth[@intCast(n)], self.depth[@intCast(m)]) + 1;
            tree[@intCast(n)].len = @intCast(node); // Dad in the len slot
            tree[@intCast(m)].len = @intCast(node);

            self.heap[1] = node;
            node += 1;
            self.pqdownheap(tree, 1);
            if (self.heap_len < 2) break;
        }

        self.heap_max -= 1;
        self.heap[@intCast(self.heap_max)] = self.heap[1];

        self.genBitlen(desc);
        genCodes(tree, max_code, &self.bl_count);
    }

    fn scanTree(self: *Compressor, tree: []tables.CtData, max_code: i32) void {
        var n: i32 = 0;
        var prevlen: i32 = -1;
        var curlen: i32 = undefined;
        var nextlen: i32 = tree[0].len;
        var count: u16 = 0;
        var max_count: u16 = 7;
        var min_count: u16 = 4;

        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        }
        tree[@intCast(max_code + 1)].len = 0xffff;

        while (n <= max_code) : (n += 1) {
            curlen = nextlen;
            nextlen = tree[@intCast(n + 1)].len;
            count += 1;
            if (count < max_count and curlen == nextlen) {
                continue;
            } else if (count < min_count) {
                var c = count;
                while (c != 0) : (c -= 1) self.bl_tree[@intCast(curlen)].code +%= 1;
            } else if (curlen != 0) {
                if (curlen != prevlen) self.bl_tree[@intCast(curlen)].code +%= 1;
                self.bl_tree[rep_3_6].code +%= 1;
            } else if (count <= 10) {
                self.bl_tree[repz_3_10].code +%= 1;
            } else {
                self.bl_tree[repz_11_138].code +%= 1;
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

    fn sendTree(self: *Compressor, tree: []tables.CtData, max_code: i32) void {
        var n: i32 = 0;
        var prevlen: i32 = -1;
        var curlen: i32 = undefined;
        var nextlen: i32 = tree[0].len;
        var count: i32 = 0;
        var max_count: i32 = 7;
        var min_count: i32 = 4;

        if (nextlen == 0) {
            max_count = 138;
            min_count = 3;
        }

        while (n <= max_code) : (n += 1) {
            curlen = nextlen;
            nextlen = tree[@intCast(n + 1)].len;
            count += 1;
            if (count < max_count and curlen == nextlen) {
                continue;
            } else if (count < min_count) {
                while (true) {
                    self.sendBits(self.bl_tree[@intCast(curlen)].code, @intCast(self.bl_tree[@intCast(curlen)].len));
                    count -= 1;
                    if (count == 0) break;
                }
            } else if (curlen != 0) {
                if (curlen != prevlen) {
                    self.sendBits(self.bl_tree[@intCast(curlen)].code, @intCast(self.bl_tree[@intCast(curlen)].len));
                    count -= 1;
                }
                self.sendBits(self.bl_tree[rep_3_6].code, @intCast(self.bl_tree[rep_3_6].len));
                self.sendBits(@intCast(count - 3), 2);
            } else if (count <= 10) {
                self.sendBits(self.bl_tree[repz_3_10].code, @intCast(self.bl_tree[repz_3_10].len));
                self.sendBits(@intCast(count - 3), 3);
            } else {
                self.sendBits(self.bl_tree[repz_11_138].code, @intCast(self.bl_tree[repz_11_138].len));
                self.sendBits(@intCast(count - 11), 7);
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

    fn buildBlTree(self: *Compressor) i32 {
        self.scanTree(&self.dyn_ltree, self.l_desc.max_code);
        self.scanTree(&self.dyn_dtree, self.d_desc.max_code);
        self.buildTree(&self.bl_desc);

        var max_blindex: i32 = bl_codes - 1;
        while (max_blindex >= 3) : (max_blindex -= 1) {
            if (self.bl_tree[tables.bl_order[@intCast(max_blindex)]].len != 0) break;
        }
        self.opt_len += 3 * (@as(u64, @intCast(max_blindex)) + 1) + 5 + 5 + 4;
        return max_blindex;
    }

    fn sendAllTrees(self: *Compressor, lcodes: i32, dcodes: i32, blcodes: i32) void {
        self.sendBits(@intCast(lcodes - 257), 5);
        self.sendBits(@intCast(dcodes - 1), 5);
        self.sendBits(@intCast(blcodes - 4), 4);
        var rank: usize = 0;
        while (rank < @as(usize, @intCast(blcodes))) : (rank += 1) {
            self.sendBits(self.bl_tree[tables.bl_order[rank]].len, 3);
        }
        self.sendTree(&self.dyn_ltree, lcodes - 1);
        self.sendTree(&self.dyn_dtree, dcodes - 1);
    }

    fn compressBlock(self: *Compressor, ltree: []const tables.CtData, dtree: []const tables.CtData) void {
        var sx: u32 = 0;
        if (self.sym_next != 0) {
            while (true) {
                const dist: u32 = self.d_buf[sx];
                const lc: u32 = self.l_buf[sx];
                sx += 1;
                if (dist == 0) {
                    _ = self.emitLit(ltree, lc);
                } else {
                    _ = self.emitDist(ltree, dtree, lc, dist);
                }
                if (sx >= self.sym_next) break;
            }
        }
        self.emitEndBlock(ltree, false);
    }

    fn detectDataType(self: *Compressor) i32 {
        var black_mask: u64 = 0xf3ffc07f;
        var n: usize = 0;
        while (n <= 31) : ({
            n += 1;
            black_mask >>= 1;
        }) {
            if ((black_mask & 1) != 0 and self.dyn_ltree[n].len != 0) return 2; // Z_BINARY
        }
        if (self.dyn_ltree[9].len != 0 or self.dyn_ltree[10].len != 0 or self.dyn_ltree[13].len != 0) return 1; // Z_TEXT
        n = 32;
        while (n < literals) : (n += 1) {
            if (self.dyn_ltree[n].len != 0) return 1;
        }
        return 2;
    }

    /// zng_tr_flush_block. buf points at window[block_start] (or none);
    /// stored_len = strstart - block_start.
    fn trFlushBlock(self: *Compressor, buf: ?[]const u8, stored_len: u32, last: bool) void {
        var opt_lenb: u64 = undefined;
        var static_lenb: u64 = undefined;
        var max_blindex: i32 = 0;

        if (self.sym_next == 0) {
            opt_lenb = 0;
            static_lenb = 0;
            self.static_len = 7;
        } else if (self.level > 0) {
            if (self.data_type == 2) {
                self.data_type = self.detectDataType();
            }
            self.buildTree(&self.l_desc);
            self.buildTree(&self.d_desc);
            max_blindex = self.buildBlTree();

            opt_lenb = (self.opt_len + 3 + 7) >> 3;
            static_lenb = (self.static_len + 3 + 7) >> 3;
            if (static_lenb <= opt_lenb or self.strategy == 4) {
                opt_lenb = static_lenb;
            }
        } else {
            opt_lenb = @as(u64, stored_len) + 5;
            static_lenb = opt_lenb;
        }

        if (@as(u64, stored_len) + 4 <= opt_lenb and buf != null) {
            self.trStoredBlock(buf.?.ptr, stored_len, last);
        } else if (static_lenb == opt_lenb) {
            self.emitTree(static_trees_t, last);
            self.compressBlock(&tables.static_ltree, &tables.static_dtree);
        } else {
            self.emitTree(dyn_trees_t, last);
            self.sendAllTrees(self.l_desc.max_code + 1, self.d_desc.max_code + 1, max_blindex + 1);
            self.compressBlock(&self.dyn_ltree, &self.dyn_dtree);
        }
        self.initBlock();

        if (last) {
            self.emitAlign();
        }
    }

    /// FLUSH_BLOCK_ONLY.
    fn flushBlockOnly(self: *Compressor, last: bool) void {
        const buf: ?[]const u8 = if (self.block_start >= 0)
            self.window[@intCast(self.block_start)..]
        else
            null;
        self.trFlushBlock(buf, @intCast(@as(i64, self.strstart) - self.block_start), last);
        self.block_start = self.strstart;
        self.flushPending();
    }

    // ---- fill_window -------------------------------------------------------

    fn fillWindow(self: *Compressor) void {
        var n: u32 = undefined;
        var more: u32 = undefined;
        const wsize = self.w_size;

        while (true) {
            more = self.window_size - self.lookahead - self.strstart;

            if (self.strstart >= wsize + self.maxDist()) {
                std.mem.copyForwards(u8, self.window[0..wsize], self.window[wsize..][0..wsize]);
                if (self.match_start >= wsize) {
                    self.match_start -= wsize;
                } else {
                    self.match_start = 0;
                    self.prev_length = 0;
                }
                self.strstart -= wsize;
                self.block_start -= wsize;
                if (self.insert > self.strstart) self.insert = self.strstart;
                self.slideHash();
                more += wsize;
            }
            if (self.src_pos >= self.src.len) break;

            n = self.readBuf(self.window[self.strstart + self.lookahead ..], more);
            self.lookahead += n;

            if (self.lookahead + self.insert >= std_min_match) {
                const str = self.strstart - self.insert;
                if (self.max_chain_length > 1024) {
                    self.ins_h = self.updateHash(self.window[str], self.window[str + 1]);
                } else if (str >= 1) {
                    _ = self.quickInsert(str + 2 - std_min_match);
                }
                var count = self.insert;
                if (self.lookahead == 1) {
                    count -= 1;
                }
                if (count > 0) {
                    self.insertStrings(str, count);
                    self.insert -= count;
                }
            }

            if (!(self.lookahead < min_lookahead and self.src_pos < self.src.len)) break;
        }

        if (self.high_water < self.window_size) {
            const curr = self.strstart + self.lookahead;
            var init_bytes: u32 = undefined;
            if (self.high_water < curr) {
                init_bytes = self.window_size - curr;
                if (init_bytes > win_init) init_bytes = win_init;
                @memset(self.window[curr..][0..init_bytes], 0);
                self.high_water = curr + init_bytes;
            } else if (self.high_water < curr + win_init) {
                init_bytes = curr + win_init - self.high_water;
                if (init_bytes > self.window_size - self.high_water)
                    init_bytes = self.window_size - self.high_water;
                @memset(self.window[self.high_water..][0..init_bytes], 0);
                self.high_water += init_bytes;
            }
        }
    }

    inline fn maxDist(self: *const Compressor) u32 {
        return self.w_size - min_lookahead;
    }

    // ---- compare / longest match --------------------------------------------

    /// compare256: count equal bytes up to 256. Semantically identical to
    /// the byte loop of compare256_c (and to its SIMD kernels), stepped
    /// 8 bytes at a time.
    fn compare256(src0: []const u8, src1: []const u8) u32 {
        var len: u32 = 0;
        while (len < 256) {
            const a = std.mem.readInt(u64, src0[len..][0..8], .little);
            const b = std.mem.readInt(u64, src1[len..][0..8], .little);
            const diff = a ^ b;
            if (diff != 0) {
                return len + @as(u32, @ctz(diff) >> 3);
            }
            len += 8;
        }
        return 256;
    }

    inline fn memcmpEq(a: []const u8, b: []const u8) bool {
        // zng_memcmp_N equality (2/4/8 bytes), word-wise: identical results
        // to the byte-wise original on every input.
        if (a.len >= 8) {
            return std.mem.readInt(u64, a[0..8], .little) == std.mem.readInt(u64, b[0..8], .little);
        }
        if (a.len >= 4) {
            return std.mem.readInt(u32, a[0..4], .little) == std.mem.readInt(u32, b[0..4], .little);
        }
        return std.mem.readInt(u16, a[0..2], .little) == std.mem.readInt(u16, b[0..2], .little);
    }

    /// longest_match (UNALIGNED64 configuration of match_tpl.h, the
    /// non-slow variant with the early-exit for levels < 5).
    fn longestMatch(self: *Compressor, cur_match_in: u16) u32 {
        var cur_match: u32 = cur_match_in;
        const strstart = self.strstart;
        const wmask = self.w_mask;
        const scan: usize = self.strstart;
        const mbase_start: usize = 0; // window offset base (0: match_offset is always 0 in this variant)
        var mbase_end: usize = undefined;
        var limit: u32 = undefined;
        var best_len: u32 = if (self.prev_length != 0) self.prev_length else std_min_match - 1;
        var offset: u32 = best_len - 1;
        const lookahead = self.lookahead;
        const match_offset: u32 = 0; // always 0 in the non-slow variant

        if (best_len >= 4) {
            offset -= 2;
            if (best_len >= 8) offset -= 4;
        }
        self.scan_start[0..8].* = self.window[scan..][0..8].*;
        self.scan_end[0..8].* = self.window[scan + offset ..][0..8].*;
        mbase_end = offset;

        var chain_length: u32 = self.max_chain_length;
        if (best_len >= self.good_match) chain_length >>= 2;
        const nice_match: u32 = @intCast(self.nice_match);

        limit = if (strstart > self.maxDist()) strstart - self.maxDist() else 0;
        const early_exit = self.level < early_exit_trigger_level;

        while (true) {
            if (cur_match >= strstart) break;

            // Filter by width class (UNALIGNED64 semantics). The current
            // candidate is checked FIRST; the chain advances (GOTO_NEXT_CHAIN)
            // only after a failed check.
            filter: while (true) {
                if (best_len < 4) {
                    if (memcmpEq(self.window[mbase_end + cur_match ..][0..2], self.scan_end[0..2]) and
                        memcmpEq(self.window[mbase_start + cur_match ..][0..2], self.scan_start[0..2]))
                        break :filter;
                } else if (best_len >= 8) {
                    if (memcmpEq(self.window[mbase_end + cur_match ..][0..8], self.scan_end[0..8]) and
                        memcmpEq(self.window[mbase_start + cur_match ..][0..8], self.scan_start[0..8]))
                        break :filter;
                } else {
                    if (memcmpEq(self.window[mbase_end + cur_match ..][0..4], self.scan_end[0..4]) and
                        memcmpEq(self.window[mbase_start + cur_match ..][0..4], self.scan_start[0..4]))
                        break :filter;
                }

                chain_length -= 1;
                if (chain_length == 0) return best_len;
                cur_match = self.prev[cur_match & wmask];
                if (!(cur_match > limit)) return best_len;
            }

            const len: u32 = compare256(self.window[scan + 2 ..], self.window[mbase_start + cur_match + 2 ..]) + 2;
            if (len > best_len) {
                self.match_start = cur_match - match_offset;

                if (len > lookahead) return lookahead;
                best_len = len;
                if (best_len >= nice_match) return best_len;

                offset = best_len - 1;
                if (best_len >= 4) {
                    offset -= 2;
                    if (best_len >= 8) offset -= 4;
                }
                self.scan_end[0..8].* = self.window[scan + offset ..][0..8].*;
                mbase_end = mbase_start + offset;
            } else if (early_exit) {
                break;
            }

            chain_length -= 1;
            if (chain_length == 0) return best_len;
            cur_match = self.prev[cur_match & wmask];
            if (!(cur_match > limit)) return best_len;
        }
        return best_len;
    }

    /// longest_match_slow (LONGEST_MATCH_SLOW variant with the offset
    /// chain search) — level 9.
    fn longestMatchSlow(self: *Compressor, cur_match_in: u16) u32 {
        var cur_match: u32 = cur_match_in;
        const strstart = self.strstart;
        const wmask = self.w_mask;
        const scan: usize = self.strstart;
        var mbase_start: i64 = 0;
        var mbase_end: i64 = undefined;
        var limit: u32 = undefined;
        var limit_base: u32 = undefined;
        var best_len: u32 = if (self.prev_length != 0) self.prev_length else std_min_match - 1;
        var offset: u32 = best_len - 1;
        const lookahead = self.lookahead;
        var match_offset: u32 = 0;

        if (best_len >= 4) {
            offset -= 2;
            if (best_len >= 8) offset -= 4;
        }
        self.scan_start[0..8].* = self.window[scan..][0..8].*;
        self.scan_end[0..8].* = self.window[scan + offset ..][0..8].*;
        mbase_end = offset;

        var chain_length: u32 = self.max_chain_length;
        if (best_len >= self.good_match) chain_length >>= 2;
        const nice_match: u32 = @intCast(self.nice_match);

        limit = if (strstart > self.maxDist()) strstart - self.maxDist() else 0;
        limit_base = limit;
        if (best_len >= std_min_match) {
            var hash: u32 = self.updateHash(0, self.window[scan + 1]);
            hash = self.updateHash(hash, self.window[scan + 2]);

            var i: u32 = 3;
            while (i <= best_len) : (i += 1) {
                hash = self.updateHash(hash, self.window[scan + i]);
                const pos: u32 = self.head[hash];
                if (pos < cur_match) {
                    match_offset = i - 2;
                    cur_match = pos;
                }
            }

            limit = limit_base + match_offset;
            if (cur_match <= limit) {
                if (best_len < self.lookahead) return best_len;
                return self.lookahead;
            }
            mbase_start -%= @as(i64, match_offset);
            mbase_end = mbase_start + @as(i64, offset);
        }

        outer: while (true) {
            if (cur_match >= strstart) break;

            filter: while (true) {
                const mbase_cur: i64 = mbase_start + @as(i64, cur_match);
                const mbase_cur_end: i64 = mbase_end + @as(i64, cur_match);
                if (best_len < 4) {
                    if (memcmpEq(self.window[@intCast(mbase_cur_end)..][0..2], self.scan_end[0..2]) and
                        memcmpEq(self.window[@intCast(mbase_cur)..][0..2], self.scan_start[0..2]))
                        break :filter;
                } else if (best_len >= 8) {
                    if (memcmpEq(self.window[@intCast(mbase_cur_end)..][0..8], self.scan_end[0..8]) and
                        memcmpEq(self.window[@intCast(mbase_cur)..][0..8], self.scan_start[0..8]))
                        break :filter;
                } else {
                    if (memcmpEq(self.window[@intCast(mbase_cur_end)..][0..4], self.scan_end[0..4]) and
                        memcmpEq(self.window[@intCast(mbase_cur)..][0..4], self.scan_start[0..4]))
                        break :filter;
                }

                chain_length -= 1;
                if (chain_length == 0) return best_len;
                cur_match = self.prev[cur_match & wmask];
                if (!(cur_match > limit)) return best_len;
            }

            const len: u32 = compare256(self.window[scan + 2 ..], self.window[@intCast(mbase_start + @as(i64, cur_match) + 2)..]) + 2;
            if (len > best_len) {
                self.match_start = cur_match - match_offset;

                if (len > lookahead) return lookahead;
                best_len = len;
                if (best_len >= nice_match) return best_len;

                offset = best_len - 1;
                if (best_len >= 4) {
                    offset -= 2;
                    if (best_len >= 8) offset -= 4;
                }
                self.scan_end[0..8].* = self.window[scan + offset ..][0..8].*;

                // LONGEST_MATCH_SLOW: look for a better string offset.
                if (len > std_min_match and self.match_start + len < strstart) {
                    var pos: u32 = undefined;
                    var next_pos: u32 = undefined;
                    cur_match -= match_offset;
                    match_offset = 0;
                    next_pos = cur_match;
                    var i: u32 = 0;
                    while (i <= len - std_min_match) : (i += 1) {
                        pos = self.prev[(cur_match + i) & wmask];
                        if (pos < next_pos) {
                            if (pos <= limit_base + i) {
                                if (best_len < self.lookahead) return best_len;
                                return self.lookahead;
                            }
                            next_pos = pos;
                            match_offset = i;
                        }
                    }
                    cur_match = next_pos;

                    const scan_endstr: usize = scan + len - (std_min_match + 1);
                    var hash: u32 = self.updateHash(0, self.window[scan_endstr]);
                    hash = self.updateHash(hash, self.window[scan_endstr + 1]);
                    hash = self.updateHash(hash, self.window[scan_endstr + 2]);

                    pos = self.head[hash];
                    if (pos < cur_match) {
                        match_offset = len - (std_min_match + 1);
                        if (pos <= limit_base + match_offset) {
                            if (best_len < self.lookahead) return best_len;
                            return self.lookahead;
                        }
                        cur_match = pos;
                    }

                    limit = limit_base + match_offset;
                    mbase_start = -%@as(i64, match_offset);
                    mbase_end = mbase_start + @as(i64, offset);
                    continue :outer;
                }
                mbase_end = mbase_start + @as(i64, offset);
            }

            chain_length -= 1;
            if (chain_length == 0) return best_len;
            cur_match = self.prev[cur_match & wmask];
            if (!(cur_match > limit)) return best_len;
        }
        return best_len;
    }

    // ---- compression strategies -----------------------------------------------

    /// deflate_stored (level 0).
    fn deflate_stored(self: *Compressor, flush: i32) BlockState {
        var min_block: u32 = @min(self.pending_buf_size - 5, self.w_size);
        var len: u32 = undefined;
        var left: u32 = undefined;
        var have: u32 = undefined;
        var last: u32 = 0;
        var used: u32 = @intCast(self.src.len - self.src_pos);

        // avail_out is effectively unbounded in the one-shot model.
        const avail_out: u32 = max_stored + 65536;

        while (true) {
            len = max_stored;
            have = @as(u32, @intCast(self.bi_valid + 42)) >> 3;
            if (avail_out < have) break;
            have = avail_out - have;
            left = @intCast(@as(i64, self.strstart) - self.block_start);
            if (len > left + (self.src.len - self.src_pos))
                len = @intCast(left + (self.src.len - self.src_pos));
            len = @min(len, have);

            if (len < min_block and ((len == 0 and flush != Z_FINISH) or flush == Z_NO_FLUSH or len != left + (self.src.len - self.src_pos)))
                break;

            last = if (flush == Z_FINISH and len == left + (self.src.len - self.src_pos)) 1 else 0;
            self.trStoredBlock(null, 0, last != 0);
            self.pending -= 4;
            self.putShort(@intCast(len));
            self.putShort(@truncate(~len));
            self.flushPending();

            if (left != 0) {
                left = @min(left, len);
                self.out.appendSlice(self.gpa, self.window[@intCast(self.block_start)..][0..left]) catch @panic("oom");
                self.block_start += left;
                len -= left;
            }
            if (len != 0) {
                // read_buf directly to next_out.
                _ = self.readBuf(self.out.addManyAsSlice(self.gpa, len) catch @panic("oom"), len);
            }
            if (last == 0) continue;
            break;
        }

        used -= @intCast(self.src.len - self.src_pos);
        if (used != 0) {
            if (used >= self.w_size) {
                self.matches = 2;
                @memcpy(self.window[0..self.w_size], self.src[self.src_pos - self.w_size ..][0..self.w_size]);
                self.strstart = self.w_size;
                self.insert = self.strstart;
            } else {
                if (self.window_size - self.strstart <= used) {
                    self.strstart -= self.w_size;
                    std.mem.copyForwards(u8, self.window[0..self.strstart], self.window[self.w_size..][0..self.strstart]);
                    if (self.matches < 2) self.matches += 1;
                    self.insert = @min(self.insert, self.strstart);
                }
                @memcpy(self.window[self.strstart..][0..used], self.src[self.src_pos - used ..][0..used]);
                self.strstart += used;
                self.insert += @min(used, self.w_size - self.insert);
            }
            self.block_start = self.strstart;
        }
        self.high_water = @max(self.high_water, self.strstart);

        if (last != 0) return .finish_done;

        if (flush != Z_NO_FLUSH and flush != Z_FINISH and self.src_pos >= self.src.len and
            @as(i64, self.strstart) == self.block_start) return .block_done;

        have = self.window_size - self.strstart;
        if (self.src.len - self.src_pos > have and self.block_start >= self.w_size) {
            self.block_start -= self.w_size;
            self.strstart -= self.w_size;
            std.mem.copyForwards(u8, self.window[0..self.strstart], self.window[self.w_size..][0..self.strstart]);
            if (self.matches < 2) self.matches += 1;
            have += self.w_size;
            self.insert = @min(self.insert, self.strstart);
        }

        have = @min(have, @as(u32, @intCast(self.src.len - self.src_pos)));
        if (have != 0) {
            _ = self.readBuf(self.window[self.strstart..], have);
            self.strstart += have;
            self.insert += @min(have, self.w_size - self.insert);
        }
        self.high_water = @max(self.high_water, self.strstart);

        have = @as(u32, @intCast(self.bi_valid + 42)) >> 3;
        have = @min(self.pending_buf_size - have, max_stored);
        min_block = @min(have, self.w_size);
        left = @intCast(@as(i64, self.strstart) - self.block_start);
        if (left >= min_block or ((left != 0 or flush == Z_FINISH) and flush != Z_NO_FLUSH and
            self.src_pos >= self.src.len and left <= have))
        {
            len = @min(left, have);
            last = if (flush == Z_FINISH and self.src_pos >= self.src.len and len == left) 1 else 0;
            self.trStoredBlock(self.window[@intCast(self.block_start)..].ptr, len, last != 0);
            self.block_start += len;
            self.flushPending();
        }

        return if (last != 0) .finish_started else .need_more;
    }

    /// deflate_quick (level 1): static blocks only.
    fn deflate_quick(self: *Compressor, flush: i32) BlockState {
        const last: bool = flush == Z_FINISH;

        if (last and self.block_open != 2) {
            self.quickEndBlock(false);
            self.quickStartBlock(true);
        } else if (self.block_open == 0 and self.lookahead > 0) {
            self.quickStartBlock(last);
        }

        while (true) {
            if (self.pending + ((bit_buf_size + 7) >> 3) >= self.pending_buf_size) {
                self.flushPending();
            }

            if (self.lookahead < min_lookahead) {
                self.fillWindow();
                if (self.lookahead < min_lookahead and flush == Z_NO_FLUSH) return .need_more;
                if (self.lookahead == 0) break;

                if (self.block_open == 0) {
                    self.quickStartBlock(last);
                }
            }

            if (self.lookahead >= want_min_match) {
                const hash_head = self.quickInsert(self.strstart);
                const dist: i64 = @as(i64, self.strstart) - hash_head;

                if (dist <= self.maxDist() and dist > 0) {
                    const str_start: usize = self.strstart;
                    const match_start: usize = hash_head;

                    if (self.window[str_start] == self.window[match_start] and
                        self.window[str_start + 1] == self.window[match_start + 1])
                    {
                        var match_len = compare256(self.window[str_start + 2 ..], self.window[match_start + 2 ..]) + 2;

                        if (match_len >= want_min_match) {
                            if (match_len > self.lookahead) match_len = self.lookahead;
                            if (match_len > std_max_match) match_len = std_max_match;

                            _ = self.emitDist(&tables.static_ltree, &tables.static_dtree, match_len - std_min_match, @intCast(dist));
                            self.lookahead -= match_len;
                            self.strstart += match_len;
                            continue;
                        }
                    }
                }
            }

            _ = self.emitLit(&tables.static_ltree, self.window[self.strstart]);
            self.strstart += 1;
            self.lookahead -= 1;
        }

        self.insert = if (self.strstart < std_min_match - 1) self.strstart else std_min_match - 1;
        if (last) {
            self.quickEndBlock(true);
            return .finish_done;
        }
        self.quickEndBlock(false);
        return .block_done;
    }

    inline fn quickStartBlock(self: *Compressor, last: bool) void {
        self.emitTree(static_trees_t, last);
        self.block_open = @as(i32, 1) + @intFromBool(last);
        self.block_start = self.strstart;
    }

    inline fn quickEndBlock(self: *Compressor, last: bool) void {
        if (self.block_open != 0) {
            self.trEmitEndBlock(&tables.static_ltree, last);
            self.block_open = 0;
            self.block_start = self.strstart;
            self.flushPending();
        }
    }

    /// deflate_fast (level 2).
    fn deflate_fast(self: *Compressor, flush: i32) BlockState {
        var hash_head: u16 = 0;
        var bflush = false;
        var match_len: u32 = 0;

        while (true) {
            if (self.lookahead < min_lookahead) {
                self.fillWindow();
                if (self.lookahead < min_lookahead and flush == Z_NO_FLUSH) return .need_more;
                if (self.lookahead == 0) break;
            }

            if (self.lookahead >= want_min_match) {
                hash_head = self.quickInsert(self.strstart);
                const dist: i64 = @as(i64, self.strstart) - hash_head;

                if (dist <= self.maxDist() and dist > 0 and hash_head != 0) {
                    match_len = self.longestMatch(hash_head);
                }
            }

            if (match_len >= want_min_match) {
                bflush = self.tallyDist(self.strstart - self.match_start, match_len - std_min_match);
                self.lookahead -= match_len;

                if (match_len <= self.max_lazy_match and self.lookahead >= want_min_match) {
                    match_len -= 1;
                    self.strstart += 1;
                    self.insertStrings(self.strstart, match_len);
                    self.strstart += match_len;
                } else {
                    self.strstart += match_len;
                    _ = self.quickInsert(self.strstart + 2 - std_min_match);
                }
                match_len = 0;
            } else {
                bflush = self.tallyLit(self.window[self.strstart]);
                self.lookahead -= 1;
                self.strstart += 1;
            }
            if (bflush) self.flushBlockOnly(false);
        }
        self.insert = if (self.strstart < std_min_match - 1) self.strstart else std_min_match - 1;
        if (flush == Z_FINISH) {
            self.flushBlockOnly(true);
            return .finish_done;
        }
        if (self.sym_next != 0) self.flushBlockOnly(false);
        return .block_done;
    }

    /// deflate_medium (levels 3-6).
    fn deflate_medium(self: *Compressor, flush: i32) BlockState {
        var current_match = MediumMatch{};
        var next_match = MediumMatch{};
        const early_exit = self.level < 5;

        while (true) {
            var hash_head: u16 = 0;
            var bflush = false;

            if (self.lookahead < min_lookahead) {
                self.fillWindow();
                if (self.lookahead < min_lookahead and flush == Z_NO_FLUSH) return .need_more;
                if (self.lookahead == 0) break;
                next_match.match_length = 0;
            }

            if (!early_exit and next_match.match_length > 0) {
                current_match = next_match;
                next_match.match_length = 0;
            } else {
                hash_head = 0;
                if (self.lookahead >= want_min_match) {
                    hash_head = self.quickInsert(self.strstart);
                }

                current_match.strstart = @intCast(self.strstart & 0xFFFF);
                current_match.orgstart = current_match.strstart;

                const dist: i64 = @as(i64, self.strstart) - hash_head;
                if (dist <= self.maxDist() and dist > 0 and hash_head != 0) {
                    current_match.match_length = @intCast(self.longestMatch(hash_head));
                    current_match.match_start = @intCast(self.match_start);
                    if (current_match.match_length < want_min_match)
                        current_match.match_length = 1;
                    if (current_match.match_start >= current_match.strstart) {
                        current_match.match_length = 1;
                    }
                } else {
                    current_match.match_start = 0;
                    current_match.match_length = 1;
                }
            }

            self.insertMatch(current_match);

            if (!early_exit and self.lookahead > min_lookahead and
                @as(u32, current_match.strstart) + current_match.match_length < self.window_size - min_lookahead)
            {
                self.strstart = current_match.strstart + current_match.match_length;
                hash_head = self.quickInsert(self.strstart);

                next_match.strstart = @intCast(self.strstart & 0xFFFF);
                next_match.orgstart = next_match.strstart;

                const dist: i64 = @as(i64, self.strstart) - hash_head;
                if (dist <= self.maxDist() and dist > 0 and hash_head != 0) {
                    next_match.match_length = @intCast(self.longestMatch(hash_head));
                    next_match.match_start = @intCast(self.match_start);
                    if (next_match.match_start >= next_match.strstart) {
                        next_match.match_length = 1;
                    }
                    if (next_match.match_length < want_min_match) {
                        next_match.match_length = 1;
                    } else {
                        self.fizzleMatches(&current_match, &next_match);
                    }
                } else {
                    next_match.match_start = 0;
                    next_match.match_length = 1;
                }
                self.strstart = current_match.strstart;
            } else {
                next_match.match_length = 0;
            }

            bflush = self.emitMatch(current_match);
            self.strstart += current_match.match_length;

            if (bflush) self.flushBlockOnly(false);
        }
        self.insert = if (self.strstart < std_min_match - 1) self.strstart else std_min_match - 1;
        if (flush == Z_FINISH) {
            self.flushBlockOnly(true);
            return .finish_done;
        }
        if (self.sym_next != 0) self.flushBlockOnly(false);
        return .block_done;
    }

    fn emitMatch(self: *Compressor, m_in: MediumMatch) bool {
        // Takes the match BY VALUE like the C (emit_match mutates its copy).
        var m = m_in;
        var bflush: u32 = 0;
        if (m.match_length < want_min_match) {
            while (m.match_length != 0) {
                bflush += @intFromBool(self.tallyLit(self.window[m.strstart]));
                self.lookahead -= 1;
                m.strstart += 1;
                m.match_length -= 1;
            }
            return bflush != 0;
        }
        bflush += @intFromBool(self.tallyDist(@as(u32, m.strstart) - m.match_start, m.match_length - std_min_match));
        self.lookahead -= m.match_length;
        return bflush != 0;
    }

    fn insertMatch(self: *Compressor, m_in: MediumMatch) void {
        // Takes the match BY VALUE like the C (insert_match mutates its copy).
        var m = m_in;
        if (self.lookahead <= @as(u32, m.match_length) + want_min_match) return;

        m.strstart += 1;
        m.match_length -= 1;

        if (m.match_length < want_min_match - 1) {
            if (m.match_length > 0) {
                if (m.strstart >= m.orgstart) {
                    if (m.strstart + m.match_length - 1 >= m.orgstart) {
                        self.insertStrings(m.strstart, m.match_length);
                    } else {
                        self.insertStrings(m.strstart, m.orgstart - m.strstart + 1);
                    }
                    m.strstart += m.match_length;
                    m.match_length = 0;
                }
            }
            return;
        }

        if (m.strstart >= m.orgstart) {
            if (m.strstart + m.match_length - 1 >= m.orgstart) {
                self.insertStrings(m.strstart, m.match_length);
            } else {
                self.insertStrings(m.strstart, m.orgstart - m.strstart + 1);
            }
        } else if (m.orgstart < m.strstart + m.match_length) {
            self.insertStrings(m.orgstart, m.strstart + m.match_length - m.orgstart);
        }
        m.strstart += m.match_length;
        m.match_length = 0;
    }

    fn fizzleMatches(self: *Compressor, current: *MediumMatch, next: *MediumMatch) void {
        var changed: u32 = 0;
        var c = current.*;
        var n = next.*;

        if (current.match_length <= 1) return;
        if (current.match_length > 1 + next.match_start) return;
        if (current.match_length > 1 + next.strstart) return;

        const limit: u32 = if (next.strstart > self.maxDist())
            next.strstart - self.maxDist()
        else
            0;

        // window - current_len + 1 + next_start (>= 0 by the checks above)
        var match: i64 = @as(i64, n.match_start) + 1 - @as(i64, current.match_length);
        var orig: i64 = @as(i64, n.strstart) + 1 - @as(i64, current.match_length);

        if (self.window[@intCast(match)] != self.window[@intCast(orig)]) return;

        match = @as(i64, n.match_start) - 1;
        orig = @as(i64, n.strstart) - 1;

        while (self.window[@intCast(match)] == self.window[@intCast(orig)]) {
            if (c.match_length < 1) break;
            if (n.strstart <= limit) break;
            if (n.match_length >= 256) break;
            if (n.match_start <= 1) break;

            n.strstart -= 1;
            n.match_start -= 1;
            n.match_length += 1;
            c.match_length -= 1;
            match -= 1;
            orig -= 1;
            changed += 1;
        }

        if (changed == 0) return;

        if (c.match_length <= 1 and n.match_length != 2) {
            n.orgstart += 1;
            current.* = c;
            next.* = n;
        }
    }

    /// deflate_slow (levels 7-9).
    fn deflate_slow(self: *Compressor, flush: i32) BlockState {
        var hash_head: u16 = undefined;
        var bflush = false;
        var match_len: u32 = undefined;

        while (true) {
            if (self.lookahead < min_lookahead) {
                self.fillWindow();
                if (self.lookahead < min_lookahead and flush == Z_NO_FLUSH) return .need_more;
                if (self.lookahead == 0) break;
            }

            hash_head = 0;
            if (self.lookahead >= want_min_match) {
                hash_head = self.quickInsert(self.strstart);
            }

            self.prev_match = @intCast(self.match_start);
            match_len = std_min_match - 1;
            const dist: i64 = @as(i64, self.strstart) - hash_head;

            if (dist <= self.maxDist() and dist > 0 and self.prev_length < self.max_lazy_match and hash_head != 0) {
                match_len = if (self.max_chain_length <= 1024)
                    self.longestMatch(hash_head)
                else
                    self.longestMatchSlow(hash_head);

                if (match_len <= 5 and self.strategy == 1) {
                    match_len = std_min_match - 1;
                }
            }

            if (self.prev_length >= std_min_match and match_len <= self.prev_length) {
                const max_insert: u32 = self.strstart + self.lookahead - std_min_match;

                bflush = self.tallyDist(self.strstart - 1 - self.prev_match, self.prev_length - std_min_match);

                self.prev_length -= 1;
                self.lookahead -= self.prev_length;

                const mov_fwd: u32 = self.prev_length - 1;
                if (max_insert > self.strstart) {
                    var insert_cnt = mov_fwd;
                    if (insert_cnt > max_insert - self.strstart)
                        insert_cnt = max_insert - self.strstart;
                    self.insertStrings(self.strstart + 1, insert_cnt);
                }
                self.prev_length = 0;
                self.match_available = 0;
                self.strstart += mov_fwd + 1;

                if (bflush) self.flushBlockOnly(false);
            } else if (self.match_available != 0) {
                bflush = self.tallyLit(self.window[self.strstart - 1]);
                if (bflush) self.flushBlockOnly(false);
                self.prev_length = match_len;
                self.strstart += 1;
                self.lookahead -= 1;
            } else {
                self.prev_length = match_len;
                self.match_available = 1;
                self.strstart += 1;
                self.lookahead -= 1;
            }
        }
        if (self.match_available != 0) {
            _ = self.tallyLit(self.window[self.strstart - 1]);
            self.match_available = 0;
        }
        self.insert = if (self.strstart < std_min_match - 1) self.strstart else std_min_match - 1;
        if (flush == Z_FINISH) {
            self.flushBlockOnly(true);
            return .finish_done;
        }
        if (self.sym_next != 0) self.flushBlockOnly(false);
        return .block_done;
    }

    /// deflate_rle (Z_RLE).
    fn deflate_rle(self: *Compressor, flush: i32) BlockState {
        var bflush = false;
        var match_len: u32 = 0;

        while (true) {
            if (self.lookahead <= std_max_match) {
                self.fillWindow();
                if (self.lookahead <= std_max_match and flush == Z_NO_FLUSH) return .need_more;
                if (self.lookahead == 0) break;
            }

            if (self.lookahead >= std_min_match and self.strstart > 0) {
                const scan: usize = self.strstart - 1;
                if (self.window[scan] == self.window[scan + 1] and
                    self.window[scan + 1] == self.window[scan + 2])
                {
                    match_len = compare256Rle(self.window[scan..]);
                    match_len += 2;
                    match_len = @min(match_len, self.lookahead);
                    match_len = @min(match_len, std_max_match);
                }
            }

            if (match_len >= std_min_match) {
                bflush = self.tallyDist(1, match_len - std_min_match);
                self.lookahead -= match_len;
                self.strstart += match_len;
                match_len = 0;
            } else {
                bflush = self.tallyLit(self.window[self.strstart]);
                self.lookahead -= 1;
                self.strstart += 1;
            }
            if (bflush) self.flushBlockOnly(false);
        }
        self.insert = 0;
        if (flush == Z_FINISH) {
            self.flushBlockOnly(true);
            return .finish_done;
        }
        if (self.sym_next != 0) self.flushBlockOnly(false);
        return .block_done;
    }

    /// deflate_huff (Z_HUFFMAN_ONLY).
    fn deflate_huff(self: *Compressor, flush: i32) BlockState {
        var bflush = false;
        while (true) {
            if (self.lookahead == 0) {
                self.fillWindow();
                if (self.lookahead == 0) {
                    if (flush == Z_NO_FLUSH) return .need_more;
                    break;
                }
            }
            bflush = self.tallyLit(self.window[self.strstart]);
            self.lookahead -= 1;
            self.strstart += 1;
            if (bflush) self.flushBlockOnly(false);
        }
        self.insert = 0;
        if (flush == Z_FINISH) {
            self.flushBlockOnly(true);
            return .finish_done;
        }
        if (self.sym_next != 0) self.flushBlockOnly(false);
        return .block_done;
    }

    // ---- one-shot driver ------------------------------------------------------

    /// The single deflate(Z_FINISH) call of the wrapper: header,
    /// compression to completion, trailer.
    fn deflateFinish(self: *Compressor) !void {
        // Header (INIT_STATE, wrap 1).
        var header: u32 = (8 + ((@as(u32, self.w_bits) - 8) << 4)) << 8;
        var level_flags: u32 = undefined;
        if (self.strategy >= 2 or self.level < 2) {
            level_flags = 0;
        } else if (self.level < 6) {
            level_flags = 1;
        } else if (self.level == 6) {
            level_flags = 2;
        } else {
            level_flags = 3;
        }
        header |= level_flags << 6;
        header += 31 - (header % 31);
        self.putShortMsb(@intCast(header));
        self.status = 2; // BUSY_STATE
        self.flushPending();

        // Compress: with avail_out never exhausted, one call runs the
        // strategy to finish_done.
        while (true) {
            const bstate = if (self.level == 0)
                Compressor.deflate_stored(self, Z_FINISH)
            else if (self.strategy == 2)
                Compressor.deflate_huff(self, Z_FINISH)
            else if (self.strategy == 3)
                Compressor.deflate_rle(self, Z_FINISH)
            else
                compressFuncFor(self.level)(self, Z_FINISH);

            if (bstate == .need_more) {
                // Only reachable when avail_out is exhausted — the wrapper
                // would call deflate() again with the same flush.
                continue;
            }
            if (bstate == .finish_done) break;
            if (bstate == .finish_started) break;
            // block_done cannot happen for Z_FINISH.
            return error.UnexpectedState;
        }

        // Trailer: MSB Adler-32 of the input.
        self.putUint32Msb(self.adler);
        self.flushPending();
        self.wrap = -self.wrap;
    }
};

/// compare256_rle: count how many times window[scan] repeats after the
/// first byte (scan[0]==scan[1]==scan[2] checked by the caller).
fn compare256Rle(scan: []const u8) u32 {
    // C: compare256_rle(scan, scan+3): counts the leading run bytes
    // starting at scan+3 that match the run byte scan[0] (the caller has
    // verified scan[0]==scan[1]==scan[2]). Capped at 256; the caller adds 2.
    var len: u32 = 0;
    while (len < 256) : (len += 1) {
        if (scan[3 + len] != scan[0]) return len;
    }
    return 256;
}

fn biReverse(code: u32, len: usize) u16 {
    const rev8 = struct {
        fn f(b: u32) u8 {
            // The C's uint64 multiplication wraps by definition (unsigned
            // arithmetic); the low 32 result bits are what the shift uses.
            const v = (@as(u64, @truncate(b)) * 0x80200802) & 0x0884422110;
            return @truncate((v *% 0x0101010101) >> 32);
        }
    }.f;
    const a = rev8(code >> 8);
    const b = rev8(code & 0xFF);
    return (@as(u16, a) | (@as(u16, b) << 8)) >> @intCast(16 - len);
}

/// adler32 (the wrapper's fold-copy computes the standard Adler-32).
pub fn adler32(adler: u32, data: []const u8) u32 {
    var s1: u32 = adler & 0xFFFF;
    var s2: u32 = adler >> 16;
    var i: usize = 0;
    while (i < data.len) {
        const chunk_end = @min(i + 5552, data.len);
        while (i < chunk_end) : (i += 1) {
            s1 += data[i];
            s2 += s1;
        }
        s1 %= 65521;
        s2 %= 65521;
    }
    return (s2 << 16) | s1;
}

test "round trip against inflate" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "a",
        "hello hello hello hello hello world!",
        "The quick brown fox jumps over the lazy dog. " ** 30,
    };
    for (cases) |payload| {
        for ([_]i32{ 1, 3, 6, 9 }) |level| {
            var c = Compressor.init(alloc);
            defer c.deinit();
            const out = try c.compressZlib(payload, level, 8, 0, 15);
            defer alloc.free(out);
            try std.testing.expect(out[0] == 0x78);

            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var in_reader = std.Io.Reader.fixed(out);
            var decomp: std.compress.flate.Decompress = .init(&in_reader, .zlib, &window);
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(alloc);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = try decomp.reader.readSliceShort(&chunk);
                if (n == 0) break;
                try got.appendSlice(alloc, chunk[0..n]);
            }
            try std.testing.expectEqualSlices(u8, payload, got.items);
        }
    }
}
