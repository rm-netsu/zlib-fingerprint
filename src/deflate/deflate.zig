//! Integrated zlib deflate — version registry, dispatch and compression
//! driver.
//!
//! The compressed output of zlib historically changed in exactly four
//! places between 1.2.3 and 1.3.1 (established both by diffing every
//! release and by a 29744-run differential matrix over 13 compiled
//! versions):
//!
//!   1. deflate_stored / level 0 — three generations:
//!        1.2.3-1.2.8   (stored_legacy.zig)
//!        1.2.9         (stored_1_2_9.zig; emits no final block for empty input)
//!        1.2.10-1.3.1  (stored.zig)
//!   2. Z_RLE (strategy 3) — 1.2.3 uses deflate_fast/slow with
//!      longest_match_fast; 1.2.4+ has the dedicated deflate_rle (rle.zig).
//!   3. Z_HUFFMAN_ONLY (strategy 2) — 1.2.3 runs deflate_fast/slow with the
//!      match search disabled; 1.2.4+ has the dedicated deflate_huff
//!      (huff.zig) whose fill_window timing changes block boundaries.
//!   4. deflate_fast / deflate_slow internals (strategy checks inside the
//!      functions in 1.2.3 — fast_1_2_3.zig / slow_1_2_3.zig).
//!
//! The 1.2.1-1.2.2 class D also uses the 1.2.3 compressor on the verified
//! one-shot-success domain, with a restricted strategy set (no Z_FIXED).
//! Its original C implementation is retained as an independent test oracle.
//!
//! The three pre-1.2.1 classes are native as well (verified against both
//! the statically linked original C cores and the official release wrapper
//! binaries):
//!   * class A (1.0.1-1.0.5, `stored_1_0_x.zig`): 0xffff-clamped stored
//!     blocks flushed at MAX_DIST, no pending-size cap;
//!   * class B (1.0.6-1.0.9): pending-size-capped stored blocks plus the
//!     still-active _tr_tally early-block-stop heuristic;
//!   * class C (1.1.0-1.2.0): B with the heuristic disabled
//!     (#ifdef TRUNCATE_BLOCK, off by default).
//! All three share the pre-1.2.1 FLEVEL formula `(level-1)>>1` (unsigned,
//! clamped to 3, strategy ignored — level 0 wraps to FLEVEL=3), the old
//! fill_window shape (`state.fillWindowLegacy`) and the {0,1,2} strategy
//! set; windowBits 8 is accepted natively by 1.0.x (level 0 only — at
//! level >= 1 the 256-byte window leads the originals into out-of-bounds
//! reads) and rejected by 1.1.0-1.2.0.
//!
//! Everything else (longest_match, fill_window, trees/Huffman coding,
//! tables, adler32, stream framing) is shared code: it never changed the
//! compressed bytes across the whole range, so single modules serve every
//! version.
//!
//! The output-equivalence classes are:
//!   { 1.0.1-1.0.5 }  { 1.0.6-1.0.9 }  { 1.1.0-1.2.0 }  { 1.2.3 }
//!   { 1.2.4-1.2.8 }  { 1.2.9 }  { 1.2.10-1.3.2 }

const std = @import("std");
const st = @import("state.zig");
const trees = @import("trees.zig");
const tables = @import("tables.zig");

const stored_legacy = @import("stored_legacy.zig");
const stored_1_2_9 = @import("stored_1_2_9.zig");
const stored_modern = @import("stored.zig");
const stored_1_0_x = @import("stored_1_0_x.zig");
const fast_modern = @import("fast.zig");
const slow_modern = @import("slow.zig");
const rle_mod = @import("rle.zig");
const huff_mod = @import("huff.zig");
const fast_1_2_3 = @import("fast_1_2_3.zig");
const slow_1_2_3 = @import("slow_1_2_3.zig");

pub const DeflateState = st.DeflateState;
/// Temporary tree-dump switch for differential debugging.
pub const dbg_enabled = &trees.dbg_enabled;
pub const windowGuardBytes = st.windowGuardBytes;

/// All native Zig deflate versions; 1.0.5/1.0.9/1.2.0 represent the
/// empirical legacy classes A/B/C, 1.2.2 represents class D.
pub const Version = enum {
    v1_0_5,
    v1_0_9,
    v1_2_0,
    v1_2_2,
    v1_2_3,
    v1_2_4,
    v1_2_5,
    v1_2_6,
    v1_2_7,
    v1_2_8,
    v1_2_9,
    v1_2_10,
    v1_2_11,
    v1_2_12,
    v1_2_13,
    v1_3_0,
    v1_3_1,
    v1_3_2,
    v1_4,

    /// "1.2.3" style display name.
    pub fn name(self: Version) []const u8 {
        return switch (self) {
            .v1_0_5 => "1.0.5",
            .v1_0_9 => "1.0.9",
            .v1_2_0 => "1.2.0",
            .v1_2_2 => "1.2.2",
            .v1_2_3 => "1.2.3",
            .v1_2_4 => "1.2.4",
            .v1_2_5 => "1.2.5",
            .v1_2_6 => "1.2.6",
            .v1_2_7 => "1.2.7",
            .v1_2_8 => "1.2.8",
            .v1_2_9 => "1.2.9",
            .v1_2_10 => "1.2.10",
            .v1_2_11 => "1.2.11",
            .v1_2_12 => "1.2.12",
            .v1_2_13 => "1.2.13",
            .v1_3_0 => "1.3",
            .v1_3_1 => "1.3.1",
            .v1_3_2 => "1.3.2",
            .v1_4 => "1.4",
        };
    }

    pub fn order(self: Version) u8 {
        return @intFromEnum(self);
    }
};

pub const all_versions = [_]Version{
    .v1_0_5,  .v1_0_9,  .v1_2_0,  .v1_2_2,  .v1_2_3,  .v1_2_4,  .v1_2_5,  .v1_2_6,  .v1_2_7,
    .v1_2_8,  .v1_2_9,  .v1_2_10, .v1_2_11, .v1_2_12, .v1_2_13, .v1_3_0, .v1_3_1, .v1_3_2,
    .v1_4,
};

/// The distinct compressed-output behaviors ("implementation variants").
/// Class D reuses the 1.2.3 algorithm with earlier API limits; the legacy
/// classes A-C differ from 1.2.3 exactly in:
///   A (1.0.1-1.0.5): the 0xffff/MAX_DIST stored-block layout (no
///      pending-size cap),
///   B (1.0.6-1.0.9): A's successor with pending-size-capped stored blocks
///      plus the still-active _tr_tally early-block-stop heuristic,
///   C (1.1.0-1.2.0): B minus that heuristic (TRUNCATE_BLOCK off),
/// and all three share the pre-1.2.1 FLEVEL formula, the old fill_window
/// shape and the {0,1,2} strategy set.
pub const Variant = enum {
    /// zlib 1.0.1-1.0.5: 0xffff-clamped stored blocks flushed at MAX_DIST,
    /// truncate heuristic active, legacy FLEVEL/fill_window, wbits 8-15,
    /// strategies 0-2.
    z1_0_5,
    /// zlib 1.0.6-1.0.9: pending-size-capped stored blocks, truncate
    /// heuristic active, legacy FLEVEL/fill_window, wbits 8-15, strategies
    /// 0-2.
    z1_0_9,
    /// zlib 1.1.0-1.2.0: heuristic disabled (TRUNCATE_BLOCK), legacy
    /// FLEVEL/fill_window, wbits 9-15, strategies 0-2.
    z1_2_0,
    /// zlib 1.2.1-1.2.3: strategy dispatch inside deflate_fast/slow,
    /// longest_match_fast for Z_RLE, legacy deflate_stored.
    z1_2_3,
    /// zlib 1.2.4-1.2.8: dedicated deflate_huff/deflate_rle, legacy
    /// deflate_stored.
    z1_2_4_to_1_2_8,
    /// zlib 1.2.9: rewritten deflate_stored (no final block for empty
    /// input).
    z1_2_9,
    /// zlib 1.2.10-1.3.2: modern deflate_stored (1.3.2 correspondence
    /// checked empirically; arbitrary streaming patterns are deferred).
    z1_2_10_plus,

    pub fn of(version: Version) Variant {
        return switch (version) {
            .v1_0_5 => .z1_0_5,
            .v1_0_9 => .z1_0_9,
            .v1_2_0 => .z1_2_0,
            .v1_2_2, .v1_2_3 => .z1_2_3,
            .v1_2_4, .v1_2_5, .v1_2_6, .v1_2_7, .v1_2_8 => .z1_2_4_to_1_2_8,
            .v1_2_9 => .z1_2_9,
            else => .z1_2_10_plus,
        };
    }

    /// Human-readable version coverage of the variant.
    pub fn rangeName(self: Variant) []const u8 {
        return switch (self) {
            .z1_0_5 => "zlib 0.99-1.0.5",
            .z1_0_9 => "zlib 1.0.6-1.0.9",
            .z1_2_0 => "zlib 1.1.0-1.2.0",
            .z1_2_3 => "zlib 1.2.3",
            .z1_2_4_to_1_2_8 => "zlib 1.2.4-1.2.8",
            .z1_2_9 => "zlib 1.2.9",
            .z1_2_10_plus => "zlib 1.2.10-1.4",
        };
    }

    pub fn covers(self: Variant, version: Version) bool {
        return self.of(version) == self;
    }

    /// Representative version used to run this variant's dispatch.
    pub fn toVersion(self: Variant) Version {
        return switch (self) {
            .z1_0_5 => .v1_0_5,
            .z1_0_9 => .v1_0_9,
            .z1_2_0 => .v1_2_0,
            .z1_2_3 => .v1_2_3,
            .z1_2_4_to_1_2_8 => .v1_2_8,
            .z1_2_9 => .v1_2_9,
            .z1_2_10_plus => .v1_3_2,
        };
    }
};

pub const all_variants = [_]Variant{ .z1_0_5, .z1_0_9, .z1_2_0, .z1_2_3, .z1_2_4_to_1_2_8, .z1_2_9, .z1_2_10_plus };

/// Block-state dispatch, mirroring each generation's deflate() exactly.
fn dispatch(s: *DeflateState, flush: u32, variant: Variant) st.BlockState {
    switch (variant) {
        .z1_0_5, .z1_0_9, .z1_2_0 => {
            // 1.0.x-1.2.0: pure configuration-table dispatch; strategies are
            // handled inside deflate_fast/deflate_slow (Z_RLE/Z_FIXED do not
            // exist). Level 0 stored layout differs per class.
            if (s.level == 0) {
                return switch (variant) {
                    .z1_0_5 => stored_1_0_x.deflateStored10x(s, flush),
                    else => stored_legacy.deflateStoredLegacy(s, flush),
                };
            }
            return if (tables.configuration_table[s.level].is_fast)
                fast_1_2_3.deflateFast(s, flush)
            else
                slow_1_2_3.deflateSlow(s, flush);
        },
        .z1_2_3 => {
            // 1.2.3: pure configuration-table dispatch; strategies are
            // handled inside deflate_fast/deflate_slow.
            if (s.level == 0) return stored_legacy.deflateStoredLegacy(s, flush);
            return if (tables.configuration_table[s.level].is_fast)
                fast_1_2_3.deflateFast(s, flush)
            else
                slow_1_2_3.deflateSlow(s, flush);
        },
        .z1_2_4_to_1_2_8 => {
            // 1.2.4-1.2.8: strategy checks come first, so level 0 with
            // Z_HUFFMAN_ONLY/Z_RLE runs deflate_huff/deflate_rle.
            if (s.strategy == tables.Z_HUFFMAN_ONLY) return huff_mod.deflateHuff(s, flush);
            if (s.strategy == tables.Z_RLE) return rle_mod.deflateRle(s, flush);
            if (s.level == 0) return stored_legacy.deflateStoredLegacy(s, flush);
            return if (tables.configuration_table[s.level].is_fast)
                fast_modern.deflateFast(s, flush)
            else
                slow_modern.deflateSlow(s, flush);
        },
        .z1_2_9, .z1_2_10_plus => {
            // 1.2.9+: level 0 is checked first (strategy ignored for stored).
            if (s.level == 0) {
                return switch (variant) {
                    .z1_2_9 => stored_1_2_9.deflateStored129(s, flush),
                    else => stored_modern.deflateStored(s, flush),
                };
            }
            if (s.strategy == tables.Z_HUFFMAN_ONLY) return huff_mod.deflateHuff(s, flush);
            if (s.strategy == tables.Z_RLE) return rle_mod.deflateRle(s, flush);
            return if (tables.configuration_table[s.level].is_fast)
                fast_modern.deflateFast(s, flush)
            else
                slow_modern.deflateSlow(s, flush);
        },
    }
}

// ---------------------------------------------------------------------------
// Compression driver.
// ---------------------------------------------------------------------------

/// deflate() return codes (subset used by the driver).
pub const PumpResult = enum { ok, stream_end };

/// One deflate() call, following the 1.2.9+ control flow (the pending
/// pre-flush and the "compression must start with an empty pending buffer"
/// rule; both are byte-stream neutral for every version).
pub fn pump(s: *DeflateState, flush: u32, variant: Variant) PumpResult {
    // Flush as much pending output as possible.
    if (s.pending != 0) {
        s.flushPending();
        if (s.avail_out == 0) return .ok;
    }

    // Write the zlib header (wrap == 1).
    if (s.status == st.INIT_STATE) {
        var header: u32 = (@as(u32, tables.DEFLATED) + ((s.w_bits - 8) << 4)) << 8;
        var level_flags: u32 = undefined;
        switch (variant) {
            // zlib 1.0.1-1.2.0: level_flags = (s->level-1) >> 1 in unsigned
            // arithmetic, clamped to 3 — the strategy is NOT consulted and
            // level 0 wraps to FLEVEL=3. Verified against the official
            // 1.0.5/1.0.9/1.2.0 release binaries.
            .z1_0_5, .z1_0_9, .z1_2_0 => {
                const raw: u32 = (s.level -% 1) >> 1;
                level_flags = if (raw > 3) 3 else raw;
            },
            else => {
                if (s.strategy >= tables.Z_HUFFMAN_ONLY or s.level < 2) {
                    level_flags = 0;
                } else if (s.level < 6) {
                    level_flags = 1;
                } else if (s.level == 6) {
                    level_flags = 2;
                } else {
                    level_flags = 3;
                }
            },
        }
        header |= level_flags << 6;
        if (s.strstart != 0) header |= 0x20; // PRESET_DICT (never in our flow)
        header += 31 - (header % 31);

        s.putShortMSB(header);
        s.adler = 1; // adler32(0L, Z_NULL, 0)
        s.status = st.BUSY_STATE;

        // Compression must start with an empty pending buffer.
        s.flushPending();
        if (s.pending != 0) return .ok;
    }

    if (s.trailer_written) return .stream_end;

    // Start a new block or continue the current one.
    if (s.avail_in != 0 or s.lookahead != 0 or
        (flush != tables.Z_NO_FLUSH and s.status != st.FINISH_STATE))
    {
        const bstate = dispatch(s, flush, variant);

        if (bstate == .finish_started or bstate == .finish_done) {
            s.status = st.FINISH_STATE;
        }
        if (bstate == .need_more or bstate == .finish_started) {
            return .ok;
        }
        // block_done only occurs for PARTIAL/SYNC/FULL flushes, which the
        // wrapper call pattern never issues. finish_done falls through to
        // the trailer below.
        if (bstate == .block_done) unreachable;
    }

    if (flush != tables.Z_FINISH) return .ok;

    // Write the trailer (adler32, MSB first).
    s.putShortMSB(s.adler >> 16);
    s.putShortMSB(s.adler & 0xffff);
    s.flushPending();
    s.status = st.FINISH_STATE;
    s.trailer_written = true;
    return if (s.pending != 0) .ok else .stream_end;
}

/// Reusable compressor with fixed-capacity buffers (sized for the largest
/// parameter set: wBits 15, memLevel 9). Repeated `compress` calls emulate
/// a fresh zlib stream each time by zeroing the window and hash tables.
pub const Compressor = struct {
    allocator: std.mem.Allocator,
    state: DeflateState,
    window_buf: []u8,
    head_buf: []u16,
    prev_buf: []u16,
    pending_buf: []u8,

    const max_window_size = 2 * (1 << 15);
    const max_hash_size = 1 << (9 + 7); // memLevel 9
    const max_w_size = 1 << 15;
    const max_pending = (1 << (9 + 6)) * 4; // lit_bufsize * 4, memLevel 9

    /// Extra pending-buffer headroom for the legacy level-0 path.
    ///
    /// In zlib 1.2.4-1.2.8, running deflate_huff/deflate_rle at level 0 hits
    /// `_tr_flush_block`'s `level == 0 -> force a stored block` branch with
    /// `stored_len` up to `(lit_bufsize-1) * MAX_MATCH` (131838 bytes at
    /// memLevel 9) — far beyond zlib's own `lit_bufsize * 4` pending buffer.
    /// Genuine zlib 1.2.4-1.2.8 heap-overflows there and emits corrupted
    /// streams (undefined behavior; verified with AddressSanitizer against
    /// the unmodified C sources). This port instead models the idealized
    /// behavior — the valid stream the code path WOULD produce — by giving
    /// the pending buffer room for the largest such block. The search itself
    /// never visits level 0 (levels 1..9 only), so this only affects the
    /// development tools and the documented known-divergence class.
    const stored_block_headroom = 1 << 18;

    pub fn init(allocator: std.mem.Allocator) !Compressor {
        const window_buf = try allocator.alloc(u8, max_window_size + windowGuardBytes);
        errdefer allocator.free(window_buf);
        const head_buf = try allocator.alloc(u16, max_hash_size);
        errdefer allocator.free(head_buf);
        const prev_buf = try allocator.alloc(u16, max_w_size);
        errdefer allocator.free(prev_buf);
        const pending_buf = try allocator.alloc(u8, max_pending + stored_block_headroom);
        errdefer allocator.free(pending_buf);

        @memset(window_buf, 0);
        @memset(head_buf, 0);
        @memset(prev_buf, 0);

        var c = Compressor{
            .allocator = allocator,
            .state = .{},
            .window_buf = window_buf,
            .head_buf = head_buf,
            .prev_buf = prev_buf,
            .pending_buf = pending_buf,
        };
        c.bindBuffers();
        return c;
    }

    pub fn deinit(self: *Compressor) void {
        self.allocator.free(self.window_buf);
        self.allocator.free(self.head_buf);
        self.allocator.free(self.prev_buf);
        self.allocator.free(self.pending_buf);
    }

    fn bindBuffers(self: *Compressor) void {
        self.state.window = self.window_buf;
        self.state.head = self.head_buf;
        self.state.prev = self.prev_buf;
        self.state.pending_buf = self.pending_buf;
    }

    /// Upper bound for the compressed size of `input_len` bytes across all
    /// integrated versions and parameters (stored blocks with memLevel 1
    /// give ~0.8%, static-Huffman blocks ~12.5% worst case). The returned
    /// length includes the 16384-byte slack the driver needs for its final
    /// `avail_out = 16384` call, so callers can simply allocate this much.
    pub fn requiredOutputLen(input_len: usize) usize {
        return input_len + (input_len >> 2) + (1 << 16) + 4096 + 16384;
    }

    /// Compress `input` exactly like the one-shot wrapper binaries do: the
    /// whole payload as a single input buffer and one deflate(Z_FINISH) call
    /// chain until Z_STREAM_END. The resulting stream is byte-identical to
    /// `zlib-<version> <level> <memLevel> <strategy> <windowBits>` with zlib
    /// wrap=1, and to the most common real-world producers (zlib.compress in
    /// Python, deflateSync in Node, ...). For levels 1-9 the call pattern is
    /// byte-neutral; for level 0 (deflate_stored) the block layout depends
    /// on it, which is why the one-shot pattern is the modeled one.
    ///
    /// Per-release parameter limits (deflateInit2_ validation):
    ///   * 1.0.1-1.2.0: strategies 0-2 only; windowBits 9-15 (1.1.0+ rejects
    ///     8, the 1.0.x releases accept it — at level 0 only, because at
    ///     level >= 1 the 256-byte window makes the originals follow hash
    ///     chains with wrapped distances into out-of-bounds reads);
    ///   * 1.2.1-1.2.2: adds Z_RLE, remaps windowBits 8 to 9;
    ///   * 1.2.3+: full modern matrix.
    pub fn compress(
        self: *Compressor,
        version: Version,
        level: u32,
        mem_level: u32,
        strategy: u32,
        window_bits: u32,
        input: []const u8,
        output: []u8,
    ) PumpError!usize {
        return self.compressExpect(version, level, mem_level, strategy, window_bits, input, output, null);
    }

    /// Same as `compress`, but with an early-abort reference: while the
    /// output still matches `expect` byte-for-byte the compression continues;
    /// on the first divergent 16 KiB output chunk (or a longer-than-`expect`
    /// output) `error.OutputMismatch` is returned and the remaining work is
    /// skipped. A full pass without the error means the produced stream is
    /// byte-identical to `expect` (length included).
    ///
    /// This is a pure search optimization: mismatches abort after the first
    /// divergent block, which for typical inputs happens within the first
    /// few output chunks instead of after compressing everything.
    pub fn compressExpect(
        self: *Compressor,
        version: Version,
        level: u32,
        mem_level: u32,
        strategy: u32,
        window_bits: u32,
        input: []const u8,
        output: []u8,
        expect: ?[]const u8,
    ) PumpError!usize {
        if (level > 9 or mem_level < 1 or mem_level > 9 or
            window_bits < 8 or window_bits > 15 or strategy > tables.Z_FIXED)
        {
            return error.InvalidParams;
        }
        const legacy_ab = version == .v1_0_5 or version == .v1_0_9;
        if (legacy_ab or version == .v1_2_0) {
            // Z_RLE/Z_FIXED do not exist before 1.2.1.
            if (strategy > tables.Z_HUFFMAN_ONLY) return error.InvalidParams;
        }
        if (legacy_ab) {
            // The 1.0.x releases keep the 256-byte window of windowBits 8.
            // At level 0 that path is deterministic (and reproduced); at
            // level >= 1 the match finder follows stale chain entries with
            // wrapped distances and the original performs out-of-bounds
            // reads — not reproducible, refuse it.
            if (window_bits == 8 and level >= 1) return error.InvalidParams;
        }
        if (version == .v1_2_0) {
            // 1.1.0-1.2.0 reject windowBits < 9 outright.
            if (window_bits < 9) return error.InvalidParams;
        }
        if (version == .v1_2_2 and strategy > tables.Z_RLE) {
            return error.InvalidParams;
        }

        const s = &self.state;
        const variant = Variant.of(version);

        // windowBits == 8 is remapped to 9 by zlib 1.2.1+ ("until 256-byte
        // window bug fixed"); the 1.0.x releases keep it.
        var eff_window_bits = window_bits;
        if (eff_window_bits == 8 and !legacy_ab) eff_window_bits = 9;

        // Emulate a freshly-initialized zlib stream.
        s.initParams(level, mem_level, eff_window_bits);
        s.legacy_fill = variant == .z1_0_5 or variant == .z1_0_9 or variant == .z1_2_0;
        s.truncate_block = variant == .z1_0_5 or variant == .z1_0_9;
        @memset(self.window_buf[0 .. 2 * s.w_size + windowGuardBytes], 0);
        @memset(self.head_buf[0..s.hash_size], 0);
        @memset(self.prev_buf[0..s.w_size], 0);
        s.window = self.window_buf;
        s.head = self.head_buf;
        s.prev = self.prev_buf;
        s.pending_buf = self.pending_buf;
        s.sym_buf = self.pending_buf[s.lit_bufsize .. s.lit_bufsize * 4];
        s.reset(level, strategy);
        s.trailer_written = false;

        // One-shot call pattern: the whole input is handed to deflate with a
        // single Z_FINISH. For levels 1-9 output chunking is byte-neutral,
        // so the driver drains 16 KiB chunks to keep the early-abort
        // reference comparison cheap. Level 0 (deflate_stored, 1.2.10+) is
        // the exception: its block layout is avail_out-dependent — the
        // one-shot wrapper binaries hand deflate the whole output buffer in
        // a single call, so that is exactly what must be emulated.
        const chunk = 16384;
        var out_pos: usize = 0;
        s.input = input;
        s.next_in = 0;
        s.avail_in = @intCast(input.len);

        if (level == 0) {
            s.output = output;
            s.next_out = 0;
            s.avail_out = @intCast(output.len);
            const r = pump(s, tables.Z_FINISH, variant);
            out_pos = output.len - s.avail_out;
            if (r != .stream_end) return error.OutputTooSmall;
            if (expect) |ref| {
                if (out_pos != ref.len) return error.OutputMismatch;
                if (!std.mem.eql(u8, output[0..out_pos], ref)) return error.OutputMismatch;
            }
            return out_pos;
        }

        while (true) {
            if (out_pos + chunk > output.len) return error.OutputTooSmall;
            s.output = output;
            s.next_out = out_pos;
            s.avail_out = chunk;
            const r = pump(s, tables.Z_FINISH, variant);
            const have = chunk - s.avail_out;
            out_pos += have;
            if (expect) |ref| {
                if (out_pos > ref.len) return error.OutputMismatch;
                if (!std.mem.eql(u8, output[out_pos - have .. out_pos], ref[out_pos - have .. out_pos])) {
                    return error.OutputMismatch;
                }
            }
            if (r == .stream_end) break;
            // Every .ok return of pump() implies a full output buffer.
            if (s.avail_out != 0) return error.OutputTooSmall;
        }
        if (expect) |ref| {
            if (out_pos != ref.len) return error.OutputMismatch;
        }
        return out_pos;
    }

    pub const PumpError = error{
        InvalidParams,
        OutputTooSmall,
        OutputMismatch,
    };
};

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "compress empty input like zlib 1.3.1" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out = [_]u8{0} ** Compressor.requiredOutputLen(0);
    // zlib 1.3.1 lvl 6 mem 8 strat 0 wbits 15 on empty input:
    // 78 9c 03 00 00 00 00 01
    const n = try c.compress(.v1_3_1, 6, 8, 0, 15, "", &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 }, out[0..n]);
}

test "compress empty input like zlib 1.2.9 level 0 (no final block)" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out = [_]u8{0} ** Compressor.requiredOutputLen(0);
    // zlib 1.2.9 level 0 emits NO deflate block for empty input:
    // 78 01 00 00 00 01
    const n = try c.compress(.v1_2_9, 0, 8, 0, 15, "", &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x01, 0x00, 0x00, 0x00, 0x01 }, out[0..n]);
}

test "compress empty input like zlib 1.2.10 level 0" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out = [_]u8{0} ** Compressor.requiredOutputLen(0);
    // zlib 1.2.10+ level 0 emits the final empty stored block:
    // 78 01 01 00 00 ff ff 00 00 00 01
    const n = try c.compress(.v1_2_10, 0, 8, 0, 15, "", &out);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x78, 0x01, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 },
        out[0..n],
    );
}

test "hello world header and roundtrip size" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out: [Compressor.requiredOutputLen(128)]u8 = undefined;
    const input = "hello hello hello hello hello zlib fingerprint";
    const n = try c.compress(.v1_3_1, 6, 8, 0, 15, input, &out);
    // zlib header 0x78 0x9c for level 6, adler32 trailer at the end.
    try std.testing.expectEqual(@as(u8, 0x78), out[0]);
    try std.testing.expectEqual(@as(u8, 0x9c), out[1]);
    try std.testing.expect(n > 8 and n < input.len);
}

// ---------------------------------------------------------------------------
// Legacy classes A-C (zlib 1.0.1-1.2.0) — golden vectors captured from the
// official 1.0.5 / 1.0.9 / 1.2.0 release wrapper binaries.
// ---------------------------------------------------------------------------

test "legacy FLEVEL formula: (level-1)>>1, strategy ignored, level 0 -> 3" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out: [Compressor.requiredOutputLen(16)]u8 = undefined;
    const cases = [_]struct { v: Version, level: u32, strategy: u32, header: u16 }{
        .{ .v = .v1_0_5, .level = 0, .strategy = 0, .header = 0x78DA },
        .{ .v = .v1_0_9, .level = 0, .strategy = 0, .header = 0x78DA },
        .{ .v = .v1_2_0, .level = 0, .strategy = 0, .header = 0x78DA },
        .{ .v = .v1_0_5, .level = 1, .strategy = 0, .header = 0x7801 },
        .{ .v = .v1_2_0, .level = 2, .strategy = 0, .header = 0x7801 },
        .{ .v = .v1_0_9, .level = 5, .strategy = 0, .header = 0x789C },
        .{ .v = .v1_2_0, .level = 6, .strategy = 0, .header = 0x789C },
        .{ .v = .v1_0_5, .level = 9, .strategy = 0, .header = 0x78DA },
        // Strategy is NOT consulted before 1.2.1 (modern zlib writes 0x7801
        // for huffman-only at level 6).
        .{ .v = .v1_0_5, .level = 6, .strategy = 2, .header = 0x789C },
        .{ .v = .v1_0_9, .level = 6, .strategy = 2, .header = 0x789C },
        .{ .v = .v1_2_0, .level = 6, .strategy = 2, .header = 0x789C },
    };
    for (cases) |case| {
        const n = try c.compress(case.v, case.level, 8, case.strategy, 15, "test", &out);
        try std.testing.expectEqual(@as(u8, @truncate(case.header >> 8)), out[0]);
        try std.testing.expectEqual(@as(u8, @truncate(case.header & 0xff)), out[1]);
        try std.testing.expect(n >= 8);
    }
}

test "legacy class A stored layout: 65535-byte first block" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    const input = "A" ** 65535;
    var out = try std.testing.allocator.alloc(u8, Compressor.requiredOutputLen(input.len));
    defer std.testing.allocator.free(out);

    // zlib 1.0.5 level 0 mem 8 wbits 15: 78 da 00 ff ff 00 00 41 41 ...
    // (first stored block is the full 65535 bytes; 1.0.9+ emit 65531).
    const n = try c.compress(.v1_0_5, 0, 8, 0, 15, input, out);
    try std.testing.expectEqual(@as(usize, 65551), n);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda, 0x00, 0xff, 0xff, 0x00, 0x00, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41 }, out[0..16]);

    // Classes B and C: 78 da 00 fb ff 04 00 41 41 ... (65531 + 4 split).
    const n_b = try c.compress(.v1_0_9, 0, 8, 0, 15, input, out);
    try std.testing.expectEqual(@as(usize, 65551), n_b);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda, 0x00, 0xfb, 0xff, 0x04, 0x00, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41 }, out[0..16]);
    const n_c = try c.compress(.v1_2_0, 0, 8, 0, 15, input, out);
    try std.testing.expectEqual(@as(usize, 65551), n_c);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda, 0x00, 0xfb, 0xff, 0x04, 0x00, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41 }, out[0..16]);
}

test "legacy classes: empty input golden vectors" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out: [Compressor.requiredOutputLen(16)]u8 = undefined;
    // All three legacy classes at level 0: 78 da 01 00 00 ff ff 00 00 00 01
    // (final empty stored block), at level 6: 78 9c 03 00 00 00 00 01.
    for ([_]Version{ .v1_0_5, .v1_0_9, .v1_2_0 }) |v| {
        const n0 = try c.compress(v, 0, 8, 0, 15, "", &out);
        try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 }, out[0..n0]);
        const n6 = try c.compress(v, 6, 8, 0, 15, "", &out);
        try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 }, out[0..n6]);
    }
}

test "legacy classes: level 6 stream matches the 1.0.5/1.0.9/1.2.0 binaries" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out: [Compressor.requiredOutputLen(128)]u8 = undefined;
    const input = "hello hello hello hello hello zlib fingerprint";
    const golden = [_]u8{
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0xc0, 0x41, 0x56, 0xe5, 0x64, 0x26, 0x29,
        0xa4, 0x65, 0xe6, 0xa5, 0xa7, 0x16, 0x15, 0x14, 0x65, 0xe6, 0x95, 0x00, 0x00, 0x94, 0x24, 0x11,
        0x7e,
    };
    for ([_]Version{ .v1_0_5, .v1_0_9, .v1_2_0 }) |v| {
        const n = try c.compress(v, 6, 8, 0, 15, input, &out);
        try std.testing.expectEqualSlices(u8, &golden, out[0..n]);
    }
}

test "legacy windowBits 8: accepted by 1.0.x at level 0, rejected later" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    var out: [Compressor.requiredOutputLen(16)]u8 = undefined;
    // zlib 1.0.5/1.0.9 level 0 windowBits 8 on "hello":
    // 08 d7 01 05 00 fa ff 68 65 6c 6c 6f 06 2c 02 15
    for ([_]Version{ .v1_0_5, .v1_0_9 }) |v| {
        const n = try c.compress(v, 0, 8, 0, 8, "hello", &out);
        try std.testing.expectEqualSlices(u8, &.{ 0x08, 0xd7, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x06, 0x2c, 0x02, 0x15 }, out[0..n]);
    }
    // 1.1.0-1.2.0 reject windowBits < 9; level >= 1 at windowBits 8 is the
    // documented out-of-bounds path of the originals and is refused.
    try std.testing.expectError(error.InvalidParams, c.compress(.v1_2_0, 0, 8, 0, 8, "hello", &out));
    try std.testing.expectError(error.InvalidParams, c.compress(.v1_0_5, 6, 8, 0, 8, "hello", &out));
    // Z_RLE / Z_FIXED do not exist before 1.2.1.
    try std.testing.expectError(error.InvalidParams, c.compress(.v1_2_0, 6, 8, 3, 15, "hello", &out));
    try std.testing.expectError(error.InvalidParams, c.compress(.v1_0_9, 6, 8, 4, 15, "hello", &out));
}

test "legacy windowBits 8 level 0 long input: corrupt empty-block stream" {
    var c = try Compressor.init(std.testing.allocator);
    defer c.deinit();

    // The 256-byte window makes MAX_DIST underflow, so no stored block is
    // flushed mid-stream; block_start slides negative and the final flush
    // emits an empty static block. zlib 1.0.5/1.0.9 really lose the data
    // this way — the port reproduces the (corrupt) bytes exactly.
    const input = "B" ** 500;
    var out: [Compressor.requiredOutputLen(input.len)]u8 = undefined;
    for ([_]Version{ .v1_0_5, .v1_0_9 }) |v| {
        const n = try c.compress(v, 0, 8, 0, 8, input, &out);
        try std.testing.expectEqualSlices(u8, &.{ 0x08, 0xd7, 0x03, 0x00, 0x2c, 0x5a, 0x80, 0xe9 }, out[0..n]);
    }
}
