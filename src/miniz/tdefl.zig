//! Native Zig port of miniz 3.1.2's tdefl compressor (the one-shot
//! `mz_compress2` producer model), byte-exact against the upstream
//! amalgamation as released — i.e. with its default build configuration:
//! `MINIZ_USE_UNALIGNED_LOADS_AND_STORES` defaults to 0 in miniz 3.1.2
//! (on every architecture, including x86-64), so the reference binaries
//! compile the scalar variants only:
//!   * tdefl_find_match — the byte-wise scalar variant (two one-byte
//!     checks at `probe + match_len` / `probe + match_len - 1`, a
//!     byte-by-byte compare, `return` on reaching the max length);
//!   * tdefl_compress_lz_codes — the plain scalar variant (every symbol
//!     through the 32-bit putBits accumulator; no 64-bit fast path);
//!   * tdefl_compress_fast is not compiled at all (`#if UNALIGNED &&
//!     LITTLE_ENDIAN`), so level 1 runs the greedy tdefl_compress_normal.
//!
//! Ported functions (miniz.c → this file):
//!   tdefl_create_comp_flags_from_zip_params → createCompFlags
//!   tdefl_init                             → tdeflInit
//!   tdefl_radix_sort_syms                  → radixSortSyms
//!   tdefl_calculate_minimum_redundancy     → calculateMinimumRedundancy
//!   tdefl_huffman_enforce_max_code_size    → enforceMaxCodeSize
//!   tdefl_optimize_huffman_table           → optimizeHuffmanTable
//!   tdefl_start_dynamic_block              → startDynamicBlock
//!   tdefl_start_static_block               → startStaticBlock
//!   tdefl_compress_lz_codes (scalar)       → compressLzCodes
//!   tdefl_compress_block                   → compressBlock
//!   tdefl_flush_block                      → flushBlock
//!   tdefl_find_match (scalar)              → findMatch
//!   tdefl_record_literal / _match          → recordLiteral / recordMatch
//!   tdefl_compress_normal                  → compressNormal
//!   tdefl_compress                         → compressWithFlags
//!
//! The `mz_compress2` one-shot call pattern (whole payload, a single
//! MZ_FINISH, output buffer of compressBound+64 bytes) reduces to a
//! single `tdefl_compress` call with TDEFL_FINISH: with the entire input
//! presented at once and the output buffer never exhausted mid-block,
//! the emitted byte stream is a pure function of (input, flags). Every
//! block lands byte-identically whether the C code staged it through
//! `m_output_buf` (small caller buffers) or compressed straight into the
//! caller buffer (>= TDEFL_OUT_BUF_SIZE remaining) — the direct/staged
//! choice never changes bytes, so this port always stages and appends.
//!
//! Determinism-relevant details preserved from the original:
//!   * the level 0 raw-block path (TDEFL_FORCE_ALL_RAW_BLOCKS) and the
//!     raw-block fallback when the coded block would expand the data;
//!   * the miniz FLEVEL computation by reversing the probe-table lookup;
//!   * the greedy/lazy parse with its exact tie handling (`cur_pos ==
//!     cur_match_dist`, MIN_MATCH at dist >= 8K rejection, the >= 128
//!     immediate-match rule, `len_to_move = saved_len - 1` lazy step);
//!   * u16 wrap-around arithmetic in the Moffat/Katajainen in-place
//!     package-merge (`calculateMinimumRedundancy`).
//!
//! Strategy flags (TDEFL_FILTER_MATCHES / RLE_MATCHES / STATIC) are
//! implemented faithfully even though the search only probes the
//! default strategy: the reference wrapper mirrors `mz_compress2`
//! exactly, whose strategy argument is MZ_DEFAULT_STRATEGY.

const std = @import("std");
const tables = @import("tables.zig");

pub const lz_dict_size: u32 = 32768;
const lz_dict_size_mask: u32 = lz_dict_size - 1;
const min_match_len: u32 = 3;
const max_match_len: u32 = 258;
const lz_hash_shift: u32 = 5; // (15 + 2) / 3
const lz_hash_size: u32 = 1 << 15;
const max_huff_symbols_0: usize = 288;
const max_huff_symbols_1: usize = 32;
const max_huff_symbols_2: usize = 19;
const lz_code_buf_size: usize = 64 * 1024;
const out_buf_size: usize = (lz_code_buf_size * 13) / 10; // 83220
const max_supported_huff_codesize: usize = 32;

pub const Flags = struct {
    pub const greedy_parsing: u32 = 0x04000;
    pub const write_zlib_header: u32 = 0x01000;
    pub const compute_adler32: u32 = 0x02000;
    pub const rle_matches: u32 = 0x10000;
    pub const filter_matches: u32 = 0x20000;
    pub const force_all_static_blocks: u32 = 0x40000;
    pub const force_all_raw_blocks: u32 = 0x80000;
    pub const max_probes_mask: u32 = 0xFFF;
};

/// `s_tdefl_num_probes[11]` — level → max probes mapping.
pub const num_probes = [11]u32{ 0, 1, 6, 32, 16, 32, 128, 256, 512, 768, 1500 };

/// Port of `tdefl_create_comp_flags_from_zip_params` for the wrapper's
/// exact call shape (`mz_deflateInit`: window bits 15, default strategy;
/// mem_level is validated but ignored by tdefl).
pub fn createCompFlags(level: i32, strategy: u8) u32 {
    const lvl: u32 = @intCast(@min(10, @max(0, level)));
    var flags: u32 = num_probes[lvl] | (if (level <= 3) Flags.greedy_parsing else 0);
    flags |= Flags.write_zlib_header; // window_bits > 0 in the wrapper
    if (level == 0) {
        flags |= Flags.force_all_raw_blocks;
    } else if (strategy == 1) { // MZ_FILTERED
        flags |= Flags.filter_matches;
    } else if (strategy == 2) { // MZ_HUFFMAN_ONLY
        flags &= ~Flags.max_probes_mask;
    } else if (strategy == 4) { // MZ_FIXED
        flags |= Flags.force_all_static_blocks;
    } else if (strategy == 3) { // MZ_RLE
        flags |= Flags.rle_matches;
    }
    return flags;
}

const SymFreq = extern struct {
    key: u16,
    sym_index: u16,
};

inline fn bitmask(n: u5) u32 {
    return (@as(u32, 1) << n) - 1;
}

pub const Compressor = struct {
    gpa: std.mem.Allocator,
    /// m_flags
    flags: u32 = 0,
    max_probes: [2]u32 = .{ 1, 1 },
    greedy_parsing: bool = false,
    /// m_dict: 32K window + max-match-1 guard bytes (C array layout).
    dict: [lz_dict_size + max_match_len - 1]u8 = undefined,
    hash: [lz_hash_size]u16 = [_]u16{0} ** lz_hash_size,
    next: [lz_dict_size]u16 = [_]u16{0} ** lz_dict_size,
    lz_code_buf: [lz_code_buf_size]u8 = undefined,
    output_buf: [out_buf_size]u8 = undefined,
    huff_count: [3][max_huff_symbols_0]u16 = undefined,
    huff_code_sizes: [3][max_huff_symbols_0]u8 = undefined,
    huff_codes: [3][max_huff_symbols_0]u16 = undefined,

    p_lz_code_buf: usize = 0,
    p_lz_flags: usize = 0,
    num_flags_left: u32 = 0,
    block_index: u32 = 0,
    lookahead_pos: u32 = 0,
    lookahead_size: u32 = 0,
    dict_size: u32 = 0,
    total_lz_bytes: u32 = 0,
    lz_code_buf_dict_pos: u32 = 0,
    saved_lit: u8 = 0,
    saved_match_dist: u32 = 0,
    saved_match_len: u32 = 0,
    adler32: u32 = 1,
    bit_buffer: u32 = 0,
    bits_in: u32 = 0,
    finished: bool = false,
    output_flush_remaining: u32 = 0,

    // Output staging (mirrors m_output_buf / m_pOutput_buf / m_pOutput_buf_end).
    out_ptr: usize = 0, // index into output_buf
    out_end: usize = 0, // exclusive end index into output_buf

    // Collected output (the caller buffer of the reference one-shot).
    sink: std.ArrayList(u8) = .empty,

    src: []const u8 = undefined,
    src_pos: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Compressor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Compressor) void {
        self.sink.deinit(self.gpa);
    }

    /// One-shot port of the `mz_compress2` call sequence:
    /// `mz_deflateInit(level)` + a single `mz_deflate(MZ_FINISH)` with a
    /// compressBound+64 output buffer.
    pub fn compressZlib(self: *Compressor, input: []const u8, level: u32) ![]u8 {
        const flags = Flags.compute_adler32 | createCompFlags(@intCast(level), 0);
        try self.compressWithFlags(input, flags);
        return self.sink.toOwnedSlice(self.gpa);
    }

    /// Full-control entry: `tdefl_compress` with the whole input and
    /// TDEFL_FINISH semantics (one-shot producer model).
    pub fn compressWithFlags(self: *Compressor, input: []const u8, flags: u32) !void {
        self.tdeflInit(flags);
        self.sink = .empty;
        errdefer self.sink.deinit(self.gpa);
        try self.sink.ensureTotalCapacity(self.gpa, out_buf_size + input.len / 2 + 128);

        self.src = input;
        self.src_pos = 0;

        // tdefl_compress_fast is not compiled in the released scalar
        // configuration: every level runs tdefl_compress_normal (levels
        // 1-3 with the greedy-parsing flag).
        if (!self.compressNormal()) return error.CompressFailed;

        if (flags & (Flags.write_zlib_header | Flags.compute_adler32) != 0) {
            self.adler32 = adler32(self.adler32, input[0..self.src_pos]);
        }
        // flush == TDEFL_FINISH with everything consumed: the final
        // block follows in the same call.
        std.debug.assert(self.lookahead_size == 0 and self.src_pos == input.len);
        if (self.flushBlock(1) != 0) return error.CompressFailed;
        self.finished = true;
    }

    fn tdeflInit(self: *Compressor, flags: u32) void {
        self.flags = flags;
        self.max_probes[0] = 1 + ((flags & 0xFFF) + 2) / 3;
        self.greedy_parsing = (flags & Flags.greedy_parsing) != 0;
        self.max_probes[1] = 1 + (((flags & 0xFFF) >> 2) + 2) / 3;
        // TDEFL_NONDETERMINISTIC_PARSING_FLAG is never set by the wrapper.
        @memset(&self.hash, 0);
        self.lookahead_pos = 0;
        self.lookahead_size = 0;
        self.dict_size = 0;
        self.total_lz_bytes = 0;
        self.lz_code_buf_dict_pos = 0;
        self.bits_in = 0;
        self.output_flush_remaining = 0;
        self.finished = false;
        self.block_index = 0;
        self.bit_buffer = 0;
        self.p_lz_code_buf = 1;
        self.p_lz_flags = 0;
        self.lz_code_buf[0] = 0;
        self.num_flags_left = 8;
        self.out_ptr = 0;
        self.out_end = 0;
        self.saved_match_dist = 0;
        self.saved_match_len = 0;
        self.saved_lit = 0;
        self.adler32 = 1;
        @memset(&self.dict, 0);
        @memset(self.huff_count[0][0..max_huff_symbols_0], 0);
        @memset(self.huff_count[1][0..max_huff_symbols_1], 0);
    }

    // ---- bit output ---------------------------------------------------

    /// TDEFL_PUT_BITS: accumulate into the 32-bit buffer, emit whole bytes
    /// (bytes past `out_end` are dropped exactly like the C macro does).
    inline fn putBits(self: *Compressor, b: u32, l: u5) void {
        self.bit_buffer |= b << @intCast(self.bits_in);
        self.bits_in += l;
        while (self.bits_in >= 8) {
            if (self.out_ptr < self.out_end) {
                self.output_buf[self.out_ptr] = @truncate(self.bit_buffer);
                self.out_ptr += 1;
            }
            self.bit_buffer >>= 8;
            self.bits_in -= 8;
        }
    }

    // ---- Huffman construction ------------------------------------------

    fn radixSortSyms(num_syms: usize, syms0: []SymFreq, syms1: []SymFreq) []SymFreq {
        var hist: [256 * 2]u32 = [_]u32{0} ** (256 * 2);
        for (syms0[0..num_syms]) |*s| {
            const freq: u32 = s.key;
            hist[freq & 0xFF] += 1;
            hist[256 + ((freq >> 8) & 0xFF)] += 1;
        }
        var total_passes: u32 = 2;
        while (total_passes > 1 and num_syms == hist[(total_passes - 1) * 256])
            total_passes -= 1;
        var cur: []SymFreq = syms0;
        var new: []SymFreq = syms1;
        var pass_shift: u4 = 0;
        var pass: u32 = 0;
        while (pass < total_passes) : ({
            pass += 1;
            pass_shift +%= 8;
        }) {
            const phist = hist[pass << 8 ..][0..256];
            var offsets: [256]usize = undefined;
            var cur_ofs: usize = 0;
            for (0..256) |i| {
                offsets[i] = cur_ofs;
                cur_ofs += phist[i];
            }
            for (cur[0..num_syms]) |*s| {
                const o = &offsets[(s.key >> pass_shift) & 0xFF];
                new[o.*] = s.*;
                o.* += 1;
            }
            const t = cur;
            cur = new;
            new = t;
        }
        return cur[0..num_syms];
    }

    /// tdefl_calculate_minimum_redundancy (Moffat/Katajainen 1996) —
    /// in-place code length assignment with the original's exact
    /// tie handling and u16 wrap-around arithmetic.
    fn calculateMinimumRedundancy(a: []SymFreq) void {
        const n: i32 = @intCast(a.len);
        if (n == 0) return;
        if (n == 1) {
            a[0].key = 1;
            return;
        }
        a[0].key = a[0].key +% a[1].key;
        var root: i32 = 0;
        var leaf: i32 = 2;
        var next: i32 = 1;
        while (next < n - 1) : (next += 1) {
            if (leaf >= n or a[@intCast(root)].key < a[@intCast(leaf)].key) {
                a[@intCast(next)].key = a[@intCast(root)].key;
                a[@intCast(root)].key = @intCast(next);
                root += 1;
            } else {
                a[@intCast(next)].key = a[@intCast(leaf)].key;
                leaf += 1;
            }
            if (leaf >= n or (root < next and a[@intCast(root)].key < a[@intCast(leaf)].key)) {
                a[@intCast(next)].key = a[@intCast(next)].key +% a[@intCast(root)].key;
                a[@intCast(root)].key = @intCast(next);
                root += 1;
            } else {
                a[@intCast(next)].key = a[@intCast(next)].key +% a[@intCast(leaf)].key;
                leaf += 1;
            }
        }
        a[@intCast(n - 2)].key = 0;
        next = n - 3;
        while (next >= 0) : (next -= 1)
            a[@intCast(next)].key = a[a[@intCast(next)].key].key +% 1;
        var avbl: i32 = 1;
        var used: i32 = 0;
        var dpth: i32 = 0;
        root = n - 2;
        next = n - 1;
        while (avbl > 0) {
            while (root >= 0 and a[@intCast(root)].key == dpth) {
                used += 1;
                root -= 1;
            }
            while (avbl > used) {
                a[@intCast(next)].key = @intCast(dpth);
                next -= 1;
                avbl -= 1;
            }
            avbl = 2 * used;
            dpth += 1;
            used = 0;
        }
    }

    fn enforceMaxCodeSize(num_codes: []i32, code_list_len: usize, max_code_size: usize) void {
        var total: u32 = 0;
        if (code_list_len <= 1) return;
        var i: usize = max_code_size + 1;
        while (i <= max_supported_huff_codesize) : (i += 1) {
            num_codes[max_code_size] += num_codes[i];
        }
        i = max_code_size;
        while (i > 0) : (i -= 1) {
            total += @as(u32, @intCast(num_codes[i])) << @intCast(max_code_size - i);
        }
        while (total != (@as(u32, 1) << @intCast(max_code_size))) {
            num_codes[max_code_size] -= 1;
            i = max_code_size - 1;
            while (i > 0) : (i -= 1) {
                if (num_codes[i] != 0) {
                    num_codes[i] -= 1;
                    num_codes[i + 1] += 2;
                    break;
                }
            }
            total -= 1;
        }
    }

    fn optimizeHuffmanTable(self: *Compressor, table_num: usize, table_len: usize, code_size_limit: usize, static_table: bool) void {
        var num_codes = [_]i32{0} ** (1 + max_supported_huff_codesize);
        if (static_table) {
            for (0..table_len) |i| {
                num_codes[self.huff_code_sizes[table_num][i]] += 1;
            }
        } else {
            var syms0: [max_huff_symbols_0]SymFreq = undefined;
            var syms1: [max_huff_symbols_0]SymFreq = undefined;
            var num_used_syms: usize = 0;
            for (0..table_len) |i| {
                if (self.huff_count[table_num][i] != 0) {
                    syms0[num_used_syms] = .{
                        .key = self.huff_count[table_num][i],
                        .sym_index = @intCast(i),
                    };
                    num_used_syms += 1;
                }
            }
            const p_syms = radixSortSyms(num_used_syms, syms0[0..], syms1[0..]);
            calculateMinimumRedundancy(p_syms);
            for (p_syms) |*s| {
                num_codes[s.key] += 1;
            }
            enforceMaxCodeSize(&num_codes, num_used_syms, code_size_limit);
            @memset(self.huff_code_sizes[table_num][0..table_len], 0);
            @memset(self.huff_codes[table_num][0..table_len], 0);
            var j: usize = num_used_syms;
            var i: usize = 1;
            while (i <= code_size_limit) : (i += 1) {
                var l: usize = @intCast(num_codes[i]);
                while (l > 0) : (l -= 1) {
                    j -= 1;
                    self.huff_code_sizes[table_num][p_syms[j].sym_index] = @intCast(i);
                }
            }
        }

        var next_code: [max_supported_huff_codesize + 1]u32 = undefined;
        next_code[1] = 0;
        var j: u32 = 0;
        var i: usize = 2;
        while (i <= code_size_limit) : (i += 1) {
            j = (j + @as(u32, @intCast(num_codes[i - 1]))) << 1;
            next_code[i] = j;
        }
        for (0..table_len) |idx| {
            var rev_code: u32 = 0;
            const code_size = self.huff_code_sizes[table_num][idx];
            if (code_size == 0) continue;
            var c: u32 = next_code[code_size];
            next_code[code_size] += 1;
            var l = code_size;
            while (l > 0) : ({
                l -= 1;
                c >>= 1;
            }) {
                rev_code = (rev_code << 1) | (c & 1);
            }
            self.huff_codes[table_num][idx] = @intCast(rev_code);
        }
    }

    // ---- dynamic / static block headers ---------------------------------

    fn rlePrevCodeSize(prev_code_size: *u8, rle_repeat_count: *u32, num_packed: *usize, packed_sizes: *[max_huff_symbols_0 + max_huff_symbols_1]u8, count2: []u16) void {
        if (rle_repeat_count.* != 0) {
            if (rle_repeat_count.* < 3) {
                count2[prev_code_size.*] +%= @intCast(rle_repeat_count.*);
                while (rle_repeat_count.* > 0) : (rle_repeat_count.* -= 1) {
                    packed_sizes[num_packed.*] = prev_code_size.*;
                    num_packed.* += 1;
                }
            } else {
                count2[16] +%= 1;
                packed_sizes[num_packed.*] = 16;
                num_packed.* += 1;
                packed_sizes[num_packed.*] = @intCast(rle_repeat_count.* - 3);
                num_packed.* += 1;
            }
            rle_repeat_count.* = 0;
        }
    }

    fn rleZeroCodeSize(rle_z_count: *u32, num_packed: *usize, packed_sizes: *[max_huff_symbols_0 + max_huff_symbols_1]u8, count2: []u16) void {
        if (rle_z_count.* != 0) {
            if (rle_z_count.* < 3) {
                count2[0] +%= @intCast(rle_z_count.*);
                while (rle_z_count.* > 0) : (rle_z_count.* -= 1) {
                    packed_sizes[num_packed.*] = 0;
                    num_packed.* += 1;
                }
            } else if (rle_z_count.* <= 10) {
                count2[17] +%= 1;
                packed_sizes[num_packed.*] = 17;
                num_packed.* += 1;
                packed_sizes[num_packed.*] = @intCast(rle_z_count.* - 3);
                num_packed.* += 1;
            } else {
                count2[18] +%= 1;
                packed_sizes[num_packed.*] = 18;
                num_packed.* += 1;
                packed_sizes[num_packed.*] = @intCast(rle_z_count.* - 11);
                num_packed.* += 1;
            }
            rle_z_count.* = 0;
        }
    }

    fn startDynamicBlock(self: *Compressor) void {
        var code_sizes_to_pack: [max_huff_symbols_0 + max_huff_symbols_1]u8 = undefined;
        var packed_code_sizes: [max_huff_symbols_0 + max_huff_symbols_1]u8 = undefined;
        var prev_code_size: u8 = 0xFF;
        var rle_z_count: u32 = 0;
        var rle_repeat_count: u32 = 0;
        var num_packed_code_sizes: usize = 0;

        self.huff_count[0][256] = 1;
        self.optimizeHuffmanTable(0, max_huff_symbols_0, 15, false);
        self.optimizeHuffmanTable(1, max_huff_symbols_1, 15, false);

        var num_lit_codes: usize = 286;
        while (num_lit_codes > 257) : (num_lit_codes -= 1) {
            if (self.huff_code_sizes[0][num_lit_codes - 1] != 0) break;
        }
        var num_dist_codes: usize = 30;
        while (num_dist_codes > 1) : (num_dist_codes -= 1) {
            if (self.huff_code_sizes[1][num_dist_codes - 1] != 0) break;
        }

        @memcpy(code_sizes_to_pack[0..num_lit_codes], self.huff_code_sizes[0][0..num_lit_codes]);
        @memcpy(code_sizes_to_pack[num_lit_codes..][0..num_dist_codes], self.huff_code_sizes[1][0..num_dist_codes]);
        const total_code_sizes_to_pack = num_lit_codes + num_dist_codes;

        @memset(self.huff_count[2][0..max_huff_symbols_2], 0);
        for (0..total_code_sizes_to_pack) |i| {
            const code_size = code_sizes_to_pack[i];
            if (code_size == 0) {
                rlePrevCodeSize(&prev_code_size, &rle_repeat_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
                rle_z_count += 1;
                if (rle_z_count == 138)
                    rleZeroCodeSize(&rle_z_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
            } else {
                rleZeroCodeSize(&rle_z_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
                if (code_size != prev_code_size) {
                    rlePrevCodeSize(&prev_code_size, &rle_repeat_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
                    self.huff_count[2][code_size] +%= 1;
                    packed_code_sizes[num_packed_code_sizes] = code_size;
                    num_packed_code_sizes += 1;
                } else {
                    rle_repeat_count += 1;
                    if (rle_repeat_count == 6)
                        rlePrevCodeSize(&prev_code_size, &rle_repeat_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
                }
            }
            prev_code_size = code_size;
        }
        if (rle_repeat_count != 0) {
            rlePrevCodeSize(&prev_code_size, &rle_repeat_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
        } else {
            rleZeroCodeSize(&rle_z_count, &num_packed_code_sizes, &packed_code_sizes, &self.huff_count[2]);
        }

        self.optimizeHuffmanTable(2, max_huff_symbols_2, 7, false);

        self.putBits(2, 2);
        self.putBits(@intCast(num_lit_codes - 257), 5);
        self.putBits(@intCast(num_dist_codes - 1), 5);

        var num_bit_lengths: isize = 18;
        while (num_bit_lengths >= 0) : (num_bit_lengths -= 1) {
            if (self.huff_code_sizes[2][tables.packed_code_size_syms_swizzle[@intCast(num_bit_lengths)]] != 0) break;
        }
        num_bit_lengths = @max(4, num_bit_lengths + 1);
        self.putBits(@intCast(num_bit_lengths - 4), 4);
        for (0..@intCast(num_bit_lengths)) |i| {
            self.putBits(self.huff_code_sizes[2][tables.packed_code_size_syms_swizzle[i]], 3);
        }

        var packed_index: usize = 0;
        while (packed_index < num_packed_code_sizes) {
            const code = packed_code_sizes[packed_index];
            packed_index += 1;
            self.putBits(self.huff_codes[2][code], @intCast(self.huff_code_sizes[2][code]));
            if (code >= 16) {
                const extra_bits = [3]u5{ 2, 3, 7 };
                self.putBits(packed_code_sizes[packed_index], extra_bits[code - 16]);
                packed_index += 1;
            }
        }
    }

    fn startStaticBlock(self: *Compressor) void {
        var i: usize = 0;
        while (i <= 143) : (i += 1) self.huff_code_sizes[0][i] = 8;
        while (i <= 255) : (i += 1) self.huff_code_sizes[0][i] = 9;
        while (i <= 279) : (i += 1) self.huff_code_sizes[0][i] = 7;
        while (i <= 287) : (i += 1) self.huff_code_sizes[0][i] = 8;
        @memset(self.huff_code_sizes[1][0..32], 5);
        self.optimizeHuffmanTable(0, 288, 15, true);
        self.optimizeHuffmanTable(1, 32, 15, true);
        self.putBits(1, 2);
    }

    /// Scalar variant of tdefl_compress_lz_codes (the official miniz 3.1.2
    /// build configuration): a plain flag/token loop emitting every symbol
    /// through the 32-bit putBits accumulator.
    fn compressLzCodes(self: *Compressor) bool {
        var flags: u32 = 1;
        var lz: usize = 0;
        const lz_end = self.p_lz_code_buf;
        while (lz < lz_end) : (flags >>= 1) {
            if (flags == 1) {
                flags = @as(u32, self.lz_code_buf[lz]) | 0x100;
                lz += 1;
            }
            if (flags & 1 != 0) {
                const match_len: u32 = self.lz_code_buf[lz];
                const match_dist: u32 = @as(u32, self.lz_code_buf[lz + 1]) | (@as(u32, self.lz_code_buf[lz + 2]) << 8);
                lz += 3;
                const lsym = tables.len_sym[match_len];
                self.putBits(self.huff_codes[0][lsym], @intCast(self.huff_code_sizes[0][lsym]));
                const lextra = tables.len_extra[match_len];
                self.putBits(match_len & bitmask(@intCast(lextra)), @intCast(lextra));
                const sym: u32 = if (match_dist < 512)
                    tables.small_dist_sym[match_dist]
                else
                    tables.large_dist_sym[match_dist >> 8];
                const num_extra_bits: u32 = if (match_dist < 512)
                    tables.small_dist_extra[match_dist]
                else
                    tables.large_dist_extra[match_dist >> 8];
                self.putBits(self.huff_codes[1][sym], @intCast(self.huff_code_sizes[1][sym]));
                self.putBits(match_dist & bitmask(@intCast(num_extra_bits)), @intCast(num_extra_bits));
            } else {
                const lit: u32 = self.lz_code_buf[lz];
                lz += 1;
                self.putBits(self.huff_codes[0][lit], @intCast(self.huff_code_sizes[0][lit]));
            }
        }
        self.putBits(self.huff_codes[0][256], @intCast(self.huff_code_sizes[0][256]));
        return self.out_ptr < self.out_end;
    }

    fn compressBlock(self: *Compressor, static_block: bool) bool {
        if (static_block) {
            self.startStaticBlock();
        } else {
            self.startDynamicBlock();
        }
        return self.compressLzCodes();
    }

    // ---- block flush -----------------------------------------------------

    /// Port of tdefl_flush_block; `flush` is 0 (mid-stream) or 1
    /// (TDEFL_FINISH — the only flush kind in the one-shot model).
    fn flushBlock(self: *Compressor, flush: u32) i32 {
        var comp_block_succeeded = false;
        const use_raw_block = (self.flags & Flags.force_all_raw_blocks) != 0 and
            (self.lookahead_pos -% self.lz_code_buf_dict_pos) <= self.dict_size;

        self.out_ptr = 0;
        self.out_end = out_buf_size - 16;
        self.output_flush_remaining = 0;

        // `*m_pLZ_flags >>= num_flags_left` (a shift of 8 clears the byte;
        // C evaluates it on the int-promoted value).
        const sh: u3 = @intCast(@min(self.num_flags_left, 7));
        self.lz_code_buf[self.p_lz_flags] >>= sh;
        if (self.num_flags_left == 8) self.p_lz_code_buf -= 1;

        if (self.flags & Flags.write_zlib_header != 0 and self.block_index == 0) {
            const cmf: u32 = 0x78;
            var flevel: u32 = 3;
            var i: usize = 0;
            while (i < num_probes.len) : (i += 1) {
                if (num_probes[i] == (self.flags & 0xFFF)) break;
            }
            if (i < 2) {
                flevel = 0;
            } else if (i < 6) {
                flevel = 1;
            } else if (i == 6) {
                flevel = 2;
            }
            var header: u32 = (cmf << 8) | (flevel << 6);
            header += 31 - (header % 31);
            const flg: u32 = header & 0xFF;
            self.putBits(cmf, 8);
            self.putBits(flg, 8);
        }

        self.putBits(if (flush == 1) 1 else 0, 1);

        const saved_out_ptr = self.out_ptr;
        const saved_bit_buf = self.bit_buffer;
        const saved_bits_in = self.bits_in;

        if (!use_raw_block) {
            comp_block_succeeded = self.compressBlock(
                (self.flags & Flags.force_all_static_blocks) != 0 or self.total_lz_bytes < 48,
            );
        }

        if ((use_raw_block or (self.total_lz_bytes != 0 and
            (self.out_ptr - saved_out_ptr + 1) >= self.total_lz_bytes)) and
            (self.lookahead_pos -% self.lz_code_buf_dict_pos) <= self.dict_size)
        {
            self.out_ptr = saved_out_ptr;
            self.bit_buffer = saved_bit_buf;
            self.bits_in = saved_bits_in;
            self.putBits(0, 2);
            if (self.bits_in != 0) {
                self.putBits(0, @intCast(8 - self.bits_in));
            }
            var total = self.total_lz_bytes;
            var i: u32 = 2;
            while (i != 0) : ({
                i -= 1;
                total ^= 0xFFFF;
            }) {
                self.putBits(total & 0xFFFF, 16);
            }
            i = 0;
            while (i < self.total_lz_bytes) : (i += 1) {
                self.putBits(self.dict[(self.lz_code_buf_dict_pos +% i) & lz_dict_size_mask], 8);
            }
        } else if (!comp_block_succeeded) {
            self.out_ptr = saved_out_ptr;
            self.bit_buffer = saved_bit_buf;
            self.bits_in = saved_bits_in;
            _ = self.compressBlock(true);
        }

        if (flush != 0) {
            // TDEFL_FINISH only.
            if (self.bits_in != 0) {
                self.putBits(0, @intCast(8 - self.bits_in));
            }
            if (self.flags & Flags.write_zlib_header != 0) {
                var a: u32 = self.adler32;
                var i: u32 = 0;
                while (i < 4) : (i += 1) {
                    self.putBits((a >> 24) & 0xFF, 8);
                    a <<= 8;
                }
            }
        }

        @memset(self.huff_count[0][0..max_huff_symbols_0], 0);
        @memset(self.huff_count[1][0..max_huff_symbols_1], 0);

        self.p_lz_code_buf = 1;
        self.p_lz_flags = 0;
        self.num_flags_left = 8;
        self.lz_code_buf_dict_pos += self.total_lz_bytes;
        self.total_lz_bytes = 0;
        self.block_index += 1;

        // Sink the staged block (the reference direct path appends the
        // same bytes to the caller buffer).
        const n = self.out_ptr;
        if (n != 0) {
            self.sink.appendSlice(self.gpa, self.output_buf[0..n]) catch return -1;
        }

        return @intCast(self.output_flush_remaining);
    }

    // ---- match finding ----------------------------------------------------

    /// Scalar variant of tdefl_find_match (the configuration the official
    /// miniz 3.1.2 amalgamation compiles with: MINIZ_USE_UNALIGNED_LOADS_AND_STORES
    /// defaults to 0): two one-byte checks at `probe + match_len` and
    /// `probe + match_len - 1`, byte-by-byte compare, return on reaching
    /// the maximum length.
    fn findMatch(self: *Compressor, lookahead_pos: u32, max_dist: u32, max_match_len_param: u32, match_dist: *u32, match_len: *u32) void {
        const pos: u32 = lookahead_pos & lz_dict_size_mask;
        var mlen: u32 = match_len.*;
        var probe_pos: u32 = pos;
        var num_probes_left: u32 = self.max_probes[if (mlen >= 32) 1 else 0];
        var c0: u8 = self.dict[pos + mlen];
        var c1: u8 = self.dict[pos + mlen - 1];
        if (max_match_len_param <= mlen) return;
        const s: u32 = pos;
        var dist: u32 = 0;

        while (true) {
            probe: while (true) {
                num_probes_left -= 1;
                if (num_probes_left == 0) return;
                // Three TDEFL_PROBEs per counter check (macro unroll shape).
                comptime var unroll: usize = 0;
                inline while (unroll < 3) : (unroll += 1) {
                    const next_probe_pos: u32 = self.next[probe_pos];
                    if (next_probe_pos == 0) return;
                    dist = (lookahead_pos -% next_probe_pos) & 0xFFFF;
                    if (dist > max_dist) return;
                    probe_pos = next_probe_pos & lz_dict_size_mask;
                    if (self.dict[probe_pos + mlen] == c0 and self.dict[probe_pos + mlen - 1] == c1) break :probe;
                }
            }
            if (dist == 0) break;

            var p: u32 = s;
            var q: u32 = probe_pos;
            var probe_len: u32 = 0;
            while (probe_len < max_match_len_param) : (probe_len += 1) {
                if (self.dict[p] != self.dict[q]) break;
                p += 1;
                q += 1;
            }
            if (probe_len > mlen) {
                match_dist.* = dist;
                mlen = probe_len;
                match_len.* = mlen;
                if (mlen == max_match_len_param) return;
                c0 = self.dict[pos + mlen];
                c1 = self.dict[pos + mlen - 1];
            }
        }
    }

    // ---- token recording ---------------------------------------------------

    fn recordLiteral(self: *Compressor, lit: u8) void {
        self.total_lz_bytes += 1;
        self.lz_code_buf[self.p_lz_code_buf] = lit;
        self.p_lz_code_buf += 1;
        self.lz_code_buf[self.p_lz_flags] >>= 1;
        self.num_flags_left -= 1;
        if (self.num_flags_left == 0) {
            self.num_flags_left = 8;
            self.p_lz_flags = self.p_lz_code_buf;
            self.p_lz_code_buf += 1;
        }
        self.huff_count[0][lit] +%= 1;
    }

    fn recordMatch(self: *Compressor, match_len_in: u32, match_dist_in: u32) void {
        self.total_lz_bytes += match_len_in;
        self.lz_code_buf[self.p_lz_code_buf] = @intCast(match_len_in - min_match_len);
        const md = match_dist_in - 1;
        self.lz_code_buf[self.p_lz_code_buf + 1] = @intCast(md & 0xFF);
        self.lz_code_buf[self.p_lz_code_buf + 2] = @intCast(md >> 8);
        self.p_lz_code_buf += 3;
        self.lz_code_buf[self.p_lz_flags] = (self.lz_code_buf[self.p_lz_flags] >> 1) | 0x80;
        self.num_flags_left -= 1;
        if (self.num_flags_left == 0) {
            self.num_flags_left = 8;
            self.p_lz_flags = self.p_lz_code_buf;
            self.p_lz_code_buf += 1;
        }
        const s0: u32 = tables.small_dist_sym[md & 511];
        const s1: u32 = tables.large_dist_sym[(md >> 8) & 127];
        self.huff_count[1][if (md < 512) s0 else s1] +%= 1;
        self.huff_count[0][tables.len_sym[match_len_in - min_match_len]] +%= 1;
    }

    // ---- normal greedy/lazy path (every level in the scalar config) --------

    fn compressNormal(self: *Compressor) bool {
        const src = self.src;
        var src_buf_left: usize = src.len;
        var p_src: usize = 0;

        while (src_buf_left != 0 or self.lookahead_size != 0) {
            // Fill the dictionary / hash chains (keep the lookahead at 258).
            if (self.lookahead_size + self.dict_size >= min_match_len - 1) {
                var dst_pos: u32 = (self.lookahead_pos +% self.lookahead_size) & lz_dict_size_mask;
                var ins_pos: u32 = self.lookahead_pos +% self.lookahead_size -% 2;
                var hash: u32 = @as(u32, self.dict[ins_pos & lz_dict_size_mask]) << @intCast(lz_hash_shift);
                hash ^= self.dict[(ins_pos + 1) & lz_dict_size_mask];
                const num_bytes_to_process: u32 = @intCast(@min(src_buf_left, max_match_len - self.lookahead_size));
                const p_src_end = p_src + num_bytes_to_process;
                src_buf_left -= num_bytes_to_process;
                self.lookahead_size += num_bytes_to_process;
                while (p_src != p_src_end) : (p_src += 1) {
                    const c: u8 = src[p_src];
                    self.dict[dst_pos] = c;
                    if (dst_pos < max_match_len - 1)
                        self.dict[lz_dict_size + dst_pos] = c;
                    hash = ((hash << @intCast(lz_hash_shift)) ^ c) & (lz_hash_size - 1);
                    self.next[ins_pos & lz_dict_size_mask] = self.hash[hash];
                    self.hash[hash] = @intCast(ins_pos);
                    dst_pos = (dst_pos + 1) & lz_dict_size_mask;
                    ins_pos += 1;
                }
            } else {
                while (src_buf_left != 0 and self.lookahead_size < max_match_len) {
                    const c: u8 = src[p_src];
                    p_src += 1;
                    src_buf_left -= 1;
                    const dst_pos: u32 = (self.lookahead_pos +% self.lookahead_size) & lz_dict_size_mask;
                    self.dict[dst_pos] = c;
                    if (dst_pos < max_match_len - 1)
                        self.dict[lz_dict_size + dst_pos] = c;
                    self.lookahead_size += 1;
                    if (self.lookahead_size + self.dict_size >= min_match_len) {
                        const ins_pos: u32 = self.lookahead_pos +% self.lookahead_size -% 1 -% 2;
                        const hash: u32 = ((@as(u32, self.dict[ins_pos & lz_dict_size_mask]) << @intCast(lz_hash_shift * 2)) ^
                            (@as(u32, self.dict[(ins_pos + 1) & lz_dict_size_mask]) << @intCast(lz_hash_shift)) ^ c) & (lz_hash_size - 1);
                        self.next[ins_pos & lz_dict_size_mask] = self.hash[hash];
                        self.hash[hash] = @intCast(ins_pos);
                    }
                }
            }
            self.dict_size = @min(lz_dict_size -% self.lookahead_size, self.dict_size);
            // flush is always set in the one-shot model: no early break.

            // Lazy/greedy parsing state machine.
            var len_to_move: u32 = 1;
            var cur_match_dist: u32 = 0;
            var cur_match_len: u32 = if (self.saved_match_len != 0) self.saved_match_len else min_match_len - 1;
            const cur_pos: u32 = self.lookahead_pos & lz_dict_size_mask;
            if (self.flags & (Flags.rle_matches | Flags.force_all_raw_blocks) != 0) {
                if (self.dict_size != 0 and self.flags & Flags.force_all_raw_blocks == 0) {
                    const c: u8 = self.dict[(cur_pos -% 1) & lz_dict_size_mask];
                    cur_match_len = 0;
                    while (cur_match_len < self.lookahead_size) {
                        if (self.dict[cur_pos + cur_match_len] != c) break;
                        cur_match_len += 1;
                    }
                    if (cur_match_len < min_match_len) {
                        cur_match_len = 0;
                    } else {
                        cur_match_dist = 1;
                    }
                }
            } else {
                self.findMatch(self.lookahead_pos, self.dict_size, self.lookahead_size, &cur_match_dist, &cur_match_len);
            }
            if ((cur_match_len == min_match_len and cur_match_dist >= 8 * 1024) or
                (cur_pos == cur_match_dist) or
                (self.flags & Flags.filter_matches != 0 and cur_match_len <= 5))
            {
                cur_match_dist = 0;
                cur_match_len = 0;
            }
            if (self.saved_match_len != 0) {
                if (cur_match_len > self.saved_match_len) {
                    self.recordLiteral(self.saved_lit);
                    if (cur_match_len >= 128) {
                        self.recordMatch(cur_match_len, cur_match_dist);
                        self.saved_match_len = 0;
                        len_to_move = cur_match_len;
                    } else {
                        self.saved_lit = self.dict[cur_pos];
                        self.saved_match_dist = cur_match_dist;
                        self.saved_match_len = cur_match_len;
                    }
                } else {
                    self.recordMatch(self.saved_match_len, self.saved_match_dist);
                    len_to_move = self.saved_match_len - 1;
                    self.saved_match_len = 0;
                }
            } else if (cur_match_dist == 0) {
                self.recordLiteral(self.dict[@min(cur_pos, self.dict.len - 1)]);
            } else if (self.greedy_parsing or self.flags & Flags.rle_matches != 0 or cur_match_len >= 128) {
                self.recordMatch(cur_match_len, cur_match_dist);
                len_to_move = cur_match_len;
            } else {
                self.saved_lit = self.dict[@min(cur_pos, self.dict.len - 1)];
                self.saved_match_dist = cur_match_dist;
                self.saved_match_len = cur_match_len;
            }

            self.lookahead_pos +%= len_to_move;
            self.lookahead_size -= len_to_move;
            self.dict_size = @min(self.dict_size + len_to_move, lz_dict_size);

            if (self.p_lz_code_buf > lz_code_buf_size - 8 or
                (self.total_lz_bytes > 31 * 1024 and
                    (((self.p_lz_code_buf * 115) >> 7) >= self.total_lz_bytes or
                        self.flags & Flags.force_all_raw_blocks != 0)))
            {
                self.src_pos = p_src;
                const n = self.flushBlock(0);
                if (n != 0) return n < 0;
            }
        }

        self.src_pos = p_src;
        return true;
    }
};

/// mz_adler32 (NMAX 5552 like zlib; miniz's scalar path).
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

test "createCompFlags level mapping" {
    try std.testing.expectEqual(@as(u32, 1 | Flags.greedy_parsing | Flags.write_zlib_header), createCompFlags(1, 0));
    try std.testing.expectEqual(@as(u32, 6 | Flags.greedy_parsing | Flags.write_zlib_header), createCompFlags(2, 0));
    try std.testing.expectEqual(@as(u32, 32 | Flags.greedy_parsing | Flags.write_zlib_header), createCompFlags(3, 0));
    // Level 4: probes drop to 16 and the greedy flag disappears (level > 3).
    try std.testing.expectEqual(@as(u32, 16 | Flags.write_zlib_header), createCompFlags(4, 0));
    try std.testing.expectEqual(@as(u32, 128 | Flags.write_zlib_header), createCompFlags(6, 0));
    try std.testing.expectEqual(@as(u32, 1500 | Flags.write_zlib_header), createCompFlags(10, 0));
}

test "round trip against inflate" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "a",
        "hello hello hello hello hello world!",
        "The quick brown fox jumps over the lazy dog. " ** 20,
    };
    for (cases) |payload| {
        for (1..11) |level| {
            var c = Compressor.init(alloc);
            defer c.deinit();
            const out = try c.compressZlib(payload, @intCast(level));
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
