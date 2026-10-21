//! Internal deflate compression state, bit-level output, window management
//! and match finders.
//!
//! Faithful Zig port of the parts of zlib's `deflate.c`/`deflate.h` that are
//! byte-for-byte identical across zlib 1.2.3 .. 1.3.1:
//!   - the `deflate_state` structure,
//!   - bit output (put_byte / put_short / putShortMSB / send_bits / bi_flush
//!     / bi_windup),
//!   - pending buffer management (flush_pending) and read_buf,
//!   - hash helpers (UPDATE_HASH / INSERT_STRING / CLEAR_HASH / slide_hash),
//!   - fill_window (the 1.2.11 shape: `wsize - more` slide copy + WIN_INIT
//!     zero fill; the older full-window slide copy is output-equivalent on a
//!     zero-initialized window, which is how the historical wrappers ran),
//!   - longest_match (unchanged from 1.2.3 through 1.3.1) and
//!     longest_match_fast (used only by the 1.2.3 strategy paths).
//!
//! Version-specific behavior lives in the sibling modules
//! (stored*.zig / fast*.zig / slow.zig / rle.zig / huff.zig).

const std = @import("std");
const tables = @import("tables.zig");

pub const CtData = tables.CtData;

// Re-export commonly used constants.
pub const MIN_MATCH = tables.MIN_MATCH;
pub const MAX_MATCH = tables.MAX_MATCH;
pub const TOO_FAR = tables.TOO_FAR;
pub const MIN_LOOKAHEAD = tables.MIN_LOOKAHEAD;
pub const WIN_INIT = tables.WIN_INIT;
pub const MAX_BITS = tables.MAX_BITS;
pub const Buf_size = tables.Buf_size;
pub const MAX_STORED = tables.MAX_STORED;
pub const NIL = tables.NIL;
pub const L_CODES = tables.L_CODES;
pub const D_CODES = tables.D_CODES;
pub const BL_CODES = tables.BL_CODES;
pub const HEAP_SIZE = tables.HEAP_SIZE;
pub const END_BLOCK = tables.END_BLOCK;
pub const Z_HUFFMAN_ONLY = tables.Z_HUFFMAN_ONLY;
pub const Z_RLE = tables.Z_RLE;
pub const Z_FIXED = tables.Z_FIXED;
pub const Z_FILTERED = tables.Z_FILTERED;
pub const Z_NO_FLUSH = tables.Z_NO_FLUSH;
pub const Z_FINISH = tables.Z_FINISH;
pub const INIT_STATE = tables.INIT_STATE;
pub const BUSY_STATE = tables.BUSY_STATE;
pub const FINISH_STATE = tables.FINISH_STATE;

/// Return codes of the block-state functions (zlib `block_state`).
pub const BlockState = enum {
    need_more,
    block_done,
    finish_started,
    finish_done,
};

/// The internal compression state (zlib `deflate_state`), self-contained:
/// the z_stream's in/out cursors are folded into the struct so the ported
/// block-state functions read like the C originals.
///
/// Buffer capacities are fixed for the largest parameter set
/// (wBits 15, memLevel 9); the active sizes are set by `initParams`.
pub const DeflateState = struct {
    // -- parameters ---------------------------------------------------------
    w_bits: u32 = 0,
    w_size: u32 = 0,
    w_mask: u32 = 0,
    hash_bits: u32 = 0,
    hash_size: u32 = 0,
    hash_mask: u32 = 0,
    hash_shift: u32 = 0,
    lit_bufsize: u32 = 0,
    pending_buf_size: u32 = 0,
    window_size: u64 = 0,
    level: u32 = 0,
    strategy: u32 = 0,
    max_chain_length: u32 = 0,
    max_lazy: u32 = 0,
    good_match: u32 = 0,
    nice_match: i32 = 0,

    // -- window / hash (heap-allocated, sized for the max parameters) ------
    window: []u8 = &.{},
    prev: []u16 = &.{},
    head: []u16 = &.{},

    // -- pending output -----------------------------------------------------
    pending_buf: []u8 = &.{},
    pending: u32 = 0,
    pending_out: u32 = 0, // index into pending_buf

    // -- symbol buffer (3 bytes per symbol, zlib >= 1.2.12 layout) ----------
    // The 1.2.12 sym_buf overlay is output-equivalent to the older
    // d_buf/l_buf overlay (same flush points, same capacities), so one
    // layout serves every version.
    sym_buf: []u8 = &.{}, // slice into pending_buf
    sym_next: u32 = 0,
    sym_end: u32 = 0,

    // -- stream cursors (z_stream equivalents) ------------------------------
    next_in: usize = 0, // index into input
    avail_in: u32 = 0,
    next_out: usize = 0, // index into output
    avail_out: u32 = 0,
    input: []const u8 = &.{},
    output: []u8 = &.{},

    // -- match state --------------------------------------------------------
    ins_h: u32 = 0,
    block_start: i64 = 0,
    match_length: u32 = 0,
    prev_match: u32 = 0,
    match_available: bool = false,
    strstart: u32 = 0,
    match_start: u32 = 0,
    lookahead: u32 = 0,
    prev_length: u32 = 0,
    matches: u32 = 0,
    insert: u32 = 0,
    high_water: u64 = 0,

    // -- trees.c workspace --------------------------------------------------
    dyn_ltree: [HEAP_SIZE]CtData = undefined, // literal and length tree
    dyn_dtree: [2 * D_CODES + 1]CtData = undefined, // distance tree
    bl_tree: [2 * BL_CODES + 1]CtData = undefined, // bit length tree

    l_desc: trees_mod.TreeDesc = undefined,
    d_desc: trees_mod.TreeDesc = undefined,
    bl_desc: trees_mod.TreeDesc = undefined,

    bl_count: [MAX_BITS + 1]u16 = undefined,
    heap: [HEAP_SIZE]i32 = undefined, // heap used to build the Huffman trees
    heap_len: usize = 0,
    heap_max: usize = 0,
    depth: [HEAP_SIZE]u8 = undefined,

    opt_len: u64 = 0, // bit length of current block with optimal trees
    static_len: u64 = 0, // bit length of current block with static trees

    // -- bit output ---------------------------------------------------------
    bi_buf: u16 = 0,
    bi_valid: i32 = 0,

    /// Set once the adler32 trailer has been emitted (zlib negates `wrap`).
    trailer_written: bool = false,

    /// zlib's status field (kept out of initParams for clarity).
    status: u32 = INIT_STATE,

    /// adler32 of the consumed input (zlib wrap == 1).
    adler: u32 = 1,

    /// Computes the derived parameter values from (level, memLevel, wBits).
    /// Mirrors deflateInit2_'s clamping, including the historical
    /// `windowBits == 8 -> 9` special case.
    pub fn initParams(self: *DeflateState, level: u32, mem_level: u32, window_bits_in: u32) void {
        var window_bits = window_bits_in;
        if (window_bits == 8) window_bits = 9; // until 256-byte window bug fixed

        self.level = level;
        self.strategy = 0; // set by init()
        self.w_bits = window_bits;
        self.w_size = @as(u32, 1) << @intCast(window_bits);
        self.w_mask = self.w_size - 1;
        self.hash_bits = mem_level + 7;
        self.hash_size = @as(u32, 1) << @intCast(self.hash_bits);
        self.hash_mask = self.hash_size - 1;
        self.hash_shift = (self.hash_bits + MIN_MATCH - 1) / MIN_MATCH;
        self.lit_bufsize = @as(u32, 1) << @intCast(mem_level + 6);
        self.pending_buf_size = self.lit_bufsize * 4;
        self.window_size = 2 * @as(u64, self.w_size);
    }

    /// deflateReset + lm_init: resets all stream state. The caller must have
    /// zeroed window/head/prev beforehand to match a freshly-initialized
    /// zlib stream.
    pub fn reset(self: *DeflateState, level: u32, strategy: u32) void {
        const cfg = tables.configuration_table[level];
        self.strategy = strategy;
        self.max_lazy = cfg.max_lazy;
        self.good_match = cfg.good_length;
        self.nice_match = @intCast(cfg.nice_length);
        self.max_chain_length = cfg.max_chain;

        self.pending = 0;
        self.pending_out = 0;
        self.status = INIT_STATE;

        self.strstart = 0;
        self.block_start = 0;
        self.lookahead = 0;
        self.insert = 0;
        self.match_length = MIN_MATCH - 1;
        self.prev_length = MIN_MATCH - 1;
        self.match_available = false;
        self.ins_h = 0;
        self.matches = 0;
        self.high_water = 0;
        self.bi_buf = 0;
        self.bi_valid = 0;
        self.sym_next = 0;
        self.sym_end = (self.lit_bufsize - 1) * 3;
        self.next_in = 0;
        self.next_out = 0;
        self.match_start = 0;
        self.prev_match = 0;
        self.adler = 1;

        trees_mod.trInit(self);
    }

    // -- bit output ---------------------------------------------------------

    /// put_byte: append one byte to the pending buffer.
    pub inline fn putByte(self: *DeflateState, b: u8) void {
        self.pending_buf[self.pending] = b;
        self.pending += 1;
    }

    /// put_short: LSB first.
    pub inline fn putShort(self: *DeflateState, w: u16) void {
        self.putByte(@truncate(w & 0xff));
        self.putByte(@truncate(w >> 8));
    }

    /// putShortMSB: MSB first (zlib header / trailer).
    pub inline fn putShortMSB(self: *DeflateState, b: u32) void {
        self.putByte(@truncate(b >> 8));
        self.putByte(@truncate(b & 0xff));
    }

    /// send_bits: append `length` (<= 16) bits of `value`, LSB first.
    /// C relies on int arithmetic plus truncation to `ush` (a shift by 16
    /// leaves bi_buf unchanged); reproduced exactly here.
    pub inline fn sendBits(self: *DeflateState, value: u32, length: i32) void {
        if (self.bi_valid > Buf_size - length) {
            const val: u32 = value & 0xffff;
            self.bi_buf |= @truncate(val << @intCast(self.bi_valid));
            self.putShort(self.bi_buf);
            self.bi_buf = @intCast(val >> @intCast(Buf_size - self.bi_valid));
            self.bi_valid += length - Buf_size;
        } else {
            const val: u32 = value & 0xffff;
            self.bi_buf |= @truncate(val << @intCast(self.bi_valid));
            self.bi_valid += length;
        }
    }

    /// send_code: send one Huffman code from a tree.
    pub inline fn sendCode(self: *DeflateState, tree: []const CtData, code_index: usize) void {
        self.sendBits(tree[code_index].code(), @intCast(tree[code_index].len()));
    }

    /// bi_flush: flush the bit buffer, keeping at most 7 bits.
    pub fn biFlush(self: *DeflateState) void {
        if (self.bi_valid == 16) {
            self.putShort(self.bi_buf);
            self.bi_buf = 0;
            self.bi_valid = 0;
        } else if (self.bi_valid >= 8) {
            self.putByte(@truncate(self.bi_buf));
            self.bi_buf >>= 8;
            self.bi_valid -= 8;
        }
    }

    /// bi_windup: flush the bit buffer and align on a byte boundary.
    pub fn biWindup(self: *DeflateState) void {
        if (self.bi_valid > 8) {
            self.putShort(self.bi_buf);
        } else if (self.bi_valid > 0) {
            self.putByte(@truncate(self.bi_buf));
        }
        self.bi_buf = 0;
        self.bi_valid = 0;
    }

    // -- pending buffer <-> output ------------------------------------------

    /// flush_pending: move bytes from pending_buf to the output.
    pub fn flushPending(self: *DeflateState) void {
        self.biFlush(); // 1.2.6+ semantics; byte order is preserved
        var len = self.pending;
        if (len > self.avail_out) len = self.avail_out;
        if (len == 0) return;
        @memcpy(
            self.output[self.next_out .. self.next_out + len],
            self.pending_buf[self.pending_out .. self.pending_out + len],
        );
        self.next_out += len;
        self.pending_out += len;
        self.avail_out -= len;
        self.pending -= len;
        if (self.pending == 0) self.pending_out = 0;
    }

    /// read_buf: copy from next_in, updating the adler32 checksum.
    pub fn readBuf(self: *DeflateState, dst: []u8) u32 {
        var len = self.avail_in;
        if (len > dst.len) len = @intCast(dst.len);
        if (len == 0) return 0;
        self.avail_in -= len;
        const src = self.input[self.next_in .. self.next_in + len];
        @memcpy(dst[0..len], src);
        self.adler = adler32(self.adler, dst[0..len]);
        self.next_in += len;
        return len;
    }


    // -- hash helpers -------------------------------------------------------

    /// UPDATE_HASH: h = ((h << hash_shift) ^ c) & hash_mask.
    pub inline fn updateHash(self: *DeflateState, c: u8) void {
        self.ins_h = ((self.ins_h << @intCast(self.hash_shift)) ^ c) & self.hash_mask;
    }

    /// INSERT_STRING: hash the string at `str`, link it into the hash chain
    /// and return the previous head.
    pub inline fn insertString(self: *DeflateState, str: u32) u32 {
        self.updateHash(self.window[str + MIN_MATCH - 1]);
        const match_head = self.head[self.ins_h];
        self.prev[str & self.w_mask] = match_head;
        self.head[self.ins_h] = @intCast(str);
        return match_head;
    }

    /// CLEAR_HASH: zero the hash table.
    pub fn clearHash(self: *DeflateState) void {
        @memset(self.head[0..self.hash_size], 0);
    }

    /// slide_hash: shift the hash chains after a window slide.
    pub fn slideHash(self: *DeflateState) void {
        const wsize = self.w_size;
        var n = self.hash_size;
        while (n != 0) {
            n -= 1;
            const m = self.head[n];
            self.head[n] = if (m >= wsize) @intCast(m - wsize) else NIL;
        }
        n = wsize;
        while (n != 0) {
            n -= 1;
            const m = self.prev[n];
            self.prev[n] = if (m >= wsize) @intCast(m - wsize) else NIL;
        }
    }

    pub inline fn maxDist(self: *const DeflateState) u32 {
        return self.w_size - MIN_LOOKAHEAD;
    }

    // -- window management --------------------------------------------------

    /// fill_window (1.2.11 shape): fill the window with input, slide when
    /// needed and zero-fill WIN_INIT bytes past the data end.
    ///
    /// NOTE: the underlying `window` allocation must carry
    /// `windowGuardBytes` zeroed bytes beyond `window_size`: the C match
    /// finders deliberately read up to 7 bytes past strend (their cursors
    /// overshoot the comparison loop), which is a harmless in-bounds-of-heap
    /// read in zlib but must be a zeroed guard region here.
    pub fn fillWindow(self: *DeflateState) void {
        const wsize = self.w_size;

        while (true) {
            var more: u64 = self.window_size - self.lookahead - self.strstart;

            if (self.strstart >= wsize + self.maxDist()) {
                const copy_len: usize = @intCast(wsize - more);
                std.mem.copyForwards(u8, self.window[0..copy_len], self.window[wsize .. wsize + copy_len]);
                self.match_start -%= wsize;
                self.strstart -%= wsize;
                self.block_start -%= @as(i64, wsize);
                if (self.insert > self.strstart) self.insert = self.strstart;
                self.slideHash();
                more += wsize;
            }
            if (self.avail_in == 0) break;

            const n = self.readBuf(self.window[@intCast(self.strstart + self.lookahead)..@intCast(self.strstart + self.lookahead + more)]);
            self.lookahead += n;

            // Initialize the hash value now that we have some input.
            if (self.lookahead + self.insert >= MIN_MATCH) {
                var str = self.strstart - self.insert;
                self.ins_h = self.window[str];
                self.updateHash(self.window[str + 1]);
                while (self.insert != 0) {
                    self.updateHash(self.window[str + MIN_MATCH - 1]);
                    self.prev[str & self.w_mask] = self.head[self.ins_h];
                    self.head[self.ins_h] = @intCast(str);
                    str += 1;
                    self.insert -= 1;
                    if (self.lookahead + self.insert < MIN_MATCH) break;
                }
            }

            if (self.lookahead < MIN_LOOKAHEAD and self.avail_in != 0) continue;
            break;
        }

        // Zero the WIN_INIT bytes after the end of the current data if they
        // have never been written (deterministic matches past the lookahead).
        if (self.high_water < self.window_size) {
            const curr: u64 = @as(u64, self.strstart) + self.lookahead;
            var init_len: u64 = undefined;

            if (self.high_water < curr) {
                init_len = self.window_size - curr;
                if (init_len > WIN_INIT) init_len = WIN_INIT;
                @memset(self.window[@intCast(curr)..@intCast(curr + init_len)], 0);
                self.high_water = curr + init_len;
            } else if (self.high_water < curr + WIN_INIT) {
                init_len = curr + WIN_INIT - self.high_water;
                if (init_len > self.window_size - self.high_water) init_len = self.window_size - self.high_water;
                @memset(self.window[@intCast(self.high_water)..@intCast(self.high_water + init_len)], 0);
                self.high_water += init_len;
            }
        }
    }

    // -- block flush (zlib FLUSH_BLOCK / FLUSH_BLOCK_ONLY macros) -----------

    /// FLUSH_BLOCK_ONLY + the FLUSH_BLOCK early-exit: flushes the current
    /// block through _tr_flush_block, resets block_start and drains the
    /// pending buffer. Returns the block state the caller must return when
    /// the output space is exhausted (`finish_started` / `need_more`),
    /// `null` when the caller may continue.
    pub fn flushBlock(self: *DeflateState, last: bool) ?BlockState {
        const buf: ?[]const u8 = if (self.block_start >= 0) self.window[@intCast(self.block_start)..] else null;
        trees_mod.trFlushBlock(
            self,
            buf,
            @intCast(@as(i64, self.strstart) - self.block_start),
            last,
        );
        self.block_start = self.strstart;
        self.flushPending();
        if (self.avail_out == 0) {
            return if (last) BlockState.finish_started else BlockState.need_more;
        }
        return null;
    }

    /// FLUSH_BLOCK_ONLY: flush the block without the early-exit check
    /// (used by deflate_slow's literal path).
    pub fn flushBlockOnlyNoExit(self: *DeflateState, last: bool) void {
        const buf: ?[]const u8 = if (self.block_start >= 0) self.window[@intCast(self.block_start)..] else null;
        trees_mod.trFlushBlock(
            self,
            buf,
            @intCast(@as(i64, self.strstart) - self.block_start),
            last,
        );
        self.block_start = self.strstart;
        self.flushPending();
    }

    // -- match finders ------------------------------------------------------

    /// longest_match (unchanged from 1.2.3 through 1.3.1, non-UNALIGNED_OK
    /// variant). Sets match_start and returns the match length clamped to
    /// the lookahead.
    pub fn longestMatch(self: *DeflateState, cur_match_in: u32) u32 {
        var chain_length = self.max_chain_length;
        const scan: usize = @as(usize, self.strstart); // index into window
        var best_len: i32 = @intCast(self.prev_length);
        var nice_match = self.nice_match;
        const limit: u32 = if (self.strstart > self.maxDist()) self.strstart - self.maxDist() else NIL;
        const prev = self.prev;
        const wmask = self.w_mask;
        const window = self.window;
        const strend: usize = self.strstart + MAX_MATCH;

        var cur_match = cur_match_in;

        // scan_end1/scan_end track scan[best_len-1] and scan[best_len].
        var scan_end1: u8 = window[scan + @as(usize, @intCast(best_len)) - 1];
        var scan_end: u8 = window[scan + @as(usize, @intCast(best_len))];

        // Do not waste too much time if we already have a good match.
        if (self.prev_length >= self.good_match) chain_length >>= 2;
        // Do not look for matches beyond the end of the input.
        if (nice_match > @as(i32, @intCast(self.lookahead))) nice_match = @intCast(self.lookahead);

        while (true) {
            const match: usize = cur_match; // index into window
            const bl: usize = @intCast(best_len);

            // Skip to next match if the match length cannot increase or if
            // the match length is less than 2.
            const pass = window[match + bl] == scan_end and
                window[match + bl - 1] == scan_end1 and
                window[match] == window[scan] and
                window[match + 1] == window[scan + 1];

            if (pass) {
                // Here scan[2] == match[2] always holds (hash property), so
                // both cursors start at offset +2 and compare +3.. onwards.
                var s = scan + 2;
                var m = match + 2;
                // 8 comparisons per unrolled iteration, exactly like the C
                // do/while: cursors end ON the first mismatching byte, or
                // past strend when the tail (zero-filled) bytes all match.
                while (true) {
                    if (window[s + 1] != window[m + 1]) { s += 1; m += 1; break; }
                    if (window[s + 2] != window[m + 2]) { s += 2; m += 2; break; }
                    if (window[s + 3] != window[m + 3]) { s += 3; m += 3; break; }
                    if (window[s + 4] != window[m + 4]) { s += 4; m += 4; break; }
                    if (window[s + 5] != window[m + 5]) { s += 5; m += 5; break; }
                    if (window[s + 6] != window[m + 6]) { s += 6; m += 6; break; }
                    if (window[s + 7] != window[m + 7]) { s += 7; m += 7; break; }
                    if (window[s + 8] != window[m + 8]) { s += 8; m += 8; break; }
                    s += 8;
                    m += 8;
                    if (!(s < strend)) break;
                }
                const len: i32 = @as(i32, MAX_MATCH) - @as(i32, @intCast(strend)) + @as(i32, @intCast(s));

                if (len > best_len) {
                    self.match_start = cur_match;
                    best_len = len;
                    if (len >= nice_match) break;
                    scan_end1 = window[scan + @as(usize, @intCast(best_len)) - 1];
                    scan_end = window[scan + @as(usize, @intCast(best_len))];
                }
            }

            cur_match = prev[cur_match & wmask];
            chain_length -= 1;
            if (cur_match <= limit or chain_length == 0) break;
        }

        if (@as(u32, @intCast(best_len)) <= self.lookahead) return @intCast(best_len);
        return self.lookahead;
    }

    /// longest_match_fast (zlib < 1.2.4 only): optimized match finder used
    /// for FASTEST and for Z_RLE distance-1 matches. Sets match_start.
    pub fn longestMatchFast(self: *DeflateState, cur_match: u32) u32 {
        const window = self.window;
        const scan: usize = self.strstart;
        const match: usize = cur_match;
        const strend: usize = self.strstart + MAX_MATCH;

        // Return failure if the match length is less than 2.
        if (window[match] != window[scan] or window[match + 1] != window[scan + 1]) return MIN_MATCH - 1;

        var s = scan + 2;
        var m = match + 2;
        while (true) {
            if (window[s + 1] != window[m + 1]) { s += 1; m += 1; break; }
            if (window[s + 2] != window[m + 2]) { s += 2; m += 2; break; }
            if (window[s + 3] != window[m + 3]) { s += 3; m += 3; break; }
            if (window[s + 4] != window[m + 4]) { s += 4; m += 4; break; }
            if (window[s + 5] != window[m + 5]) { s += 5; m += 5; break; }
            if (window[s + 6] != window[m + 6]) { s += 6; m += 6; break; }
            if (window[s + 7] != window[m + 7]) { s += 7; m += 7; break; }
            if (window[s + 8] != window[m + 8]) { s += 8; m += 8; break; }
            s += 8;
            m += 8;
            if (!(s < strend)) break;
        }

        const len: u32 = @intCast(@as(i64, MAX_MATCH) - (@as(i64, @intCast(strend)) - @as(i64, @intCast(s))));
        if (len < MIN_MATCH) return MIN_MATCH - 1;

        self.match_start = cur_match;
        return if (len <= self.lookahead) len else self.lookahead;
    }
};

const trees_mod = @import("trees.zig");

/// Zeroed guard bytes appended to the window allocation (see fillWindow).
pub const windowGuardBytes = 64;

// ---------------------------------------------------------------------------
// adler32 (RFC 1950 checksum; identical across all zlib versions).
// ---------------------------------------------------------------------------

const ADLER_BASE = 65521;

pub fn adler32(adler_in: u32, data: []const u8) u32 {
    var a: u32 = adler_in & 0xffff;
    var b: u32 = (adler_in >> 16) & 0xffff;
    for (data) |byte| {
        a += byte;
        if (a >= ADLER_BASE) a -= ADLER_BASE;
        b += a;
        if (b >= ADLER_BASE) b -= ADLER_BASE;
    }
    return (b << 16) | a;
}

test "adler32 known vector" {
    // zlib.crc32/adler32("123456789") = 0x091E01DE per RFC 1950 examples.
    try std.testing.expectEqual(@as(u32, 0x091E01DE), adler32(1, "123456789"));
    try std.testing.expectEqual(@as(u32, 1), adler32(1, ""));
}
