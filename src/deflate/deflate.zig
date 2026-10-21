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
//! Everything else (longest_match, fill_window, trees/Huffman coding,
//! tables, adler32, stream framing) is shared code: it never changed the
//! compressed bytes across the whole range, so single modules serve every
//! version.
//!
//! The output-equivalence classes are:
//!   { 1.2.3 }  { 1.2.4-1.2.8 }  { 1.2.9 }  { 1.2.10-1.3.1 }

const std = @import("std");
const st = @import("state.zig");
const trees = @import("trees.zig");
const tables = @import("tables.zig");

const stored_legacy = @import("stored_legacy.zig");
const stored_1_2_9 = @import("stored_1_2_9.zig");
const stored_modern = @import("stored.zig");
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

/// All integrated historical zlib versions.
pub const Version = enum {
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

    /// "1.2.3" style display name.
    pub fn name(self: Version) []const u8 {
        return switch (self) {
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
        };
    }

    pub fn order(self: Version) u8 {
        return @intFromEnum(self);
    }
};

pub const all_versions = [_]Version{
    .v1_2_3,  .v1_2_4,  .v1_2_5,  .v1_2_6,  .v1_2_7,  .v1_2_8, .v1_2_9,
    .v1_2_10, .v1_2_11, .v1_2_12, .v1_2_13, .v1_3_0, .v1_3_1,
};

/// The four distinct compressed-output behaviors ("implementation
/// variants"). Searching these four covers all 13 versions.
pub const Variant = enum {
    /// zlib 1.2.3: strategy dispatch inside deflate_fast/slow,
    /// longest_match_fast for Z_RLE, legacy deflate_stored.
    z1_2_3,
    /// zlib 1.2.4-1.2.8: dedicated deflate_huff/deflate_rle, legacy
    /// deflate_stored.
    z1_2_4_to_1_2_8,
    /// zlib 1.2.9: rewritten deflate_stored (no final block for empty
    /// input).
    z1_2_9,
    /// zlib 1.2.10-1.3.1: modern deflate_stored.
    z1_2_10_plus,

    pub fn of(version: Version) Variant {
        return switch (version) {
            .v1_2_3 => .z1_2_3,
            .v1_2_4, .v1_2_5, .v1_2_6, .v1_2_7, .v1_2_8 => .z1_2_4_to_1_2_8,
            .v1_2_9 => .z1_2_9,
            else => .z1_2_10_plus,
        };
    }

    /// Human-readable version coverage of the variant.
    pub fn rangeName(self: Variant) []const u8 {
        return switch (self) {
            .z1_2_3 => "zlib 1.2.3",
            .z1_2_4_to_1_2_8 => "zlib 1.2.4-1.2.8",
            .z1_2_9 => "zlib 1.2.9",
            .z1_2_10_plus => "zlib 1.2.10-1.3.1",
        };
    }

    pub fn covers(self: Variant, version: Version) bool {
        return self.of(version) == self;
    }

    /// Representative version used to run this variant's dispatch.
    pub fn toVersion(self: Variant) Version {
        return switch (self) {
            .z1_2_3 => .v1_2_3,
            .z1_2_4_to_1_2_8 => .v1_2_8,
            .z1_2_9 => .v1_2_9,
            .z1_2_10_plus => .v1_3_1,
        };
    }
};

pub const all_variants = [_]Variant{ .z1_2_3, .z1_2_4_to_1_2_8, .z1_2_9, .z1_2_10_plus };

/// Block-state dispatch, mirroring each generation's deflate() exactly.
fn dispatch(s: *DeflateState, flush: u32, variant: Variant) st.BlockState {
    switch (variant) {
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
        if (s.strategy >= tables.Z_HUFFMAN_ONLY or s.level < 2) {
            level_flags = 0;
        } else if (s.level < 6) {
            level_flags = 1;
        } else if (s.level == 6) {
            level_flags = 2;
        } else {
            level_flags = 3;
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

        const s = &self.state;
        const variant = Variant.of(version);

        // Emulate a freshly-initialized zlib stream.
        s.initParams(level, mem_level, window_bits);
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
