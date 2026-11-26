//! Three-stage bit-exact fingerprint search, driven by RFC 1950 metadata.
//!
//! Stage 1 — metadata-guided pass:
//!     Only candidates whose predicted container header (CMF/FLG, derived
//!     from windowBits + FLEVEL mapping of the implementation) equals the
//!     observed header bytes. For a default-level stream (0x78 0x9C) this is
//!     a single try per zlib-family implementation instead of blind sweeps.
//!
//! Stage 2 — trusted window, full coverage:
//!     windowBits fixed to CINFO+8 (any other value provably cannot
//!     reproduce the header bytes). All (level, memLevel, strategy)
//!     combinations whose FLEVEL class matches the observed header, ordered
//!     by proximity to the hinted class. Implementations with a fixed
//!     header (Zopfli) are skipped unless the header bytes can match.
//!
//! Stage 3 — window distrust / anomaly handling:
//!     A windowBits sweep is only meaningful when the observed header is
//!     NOT canonical (custom writer, invalid FCHECK, CINFO=0): a stock
//!     implementation writes CINFO from its own windowBits, so with a
//!     canonical header any windowBits != CINFO+8 emits different header
//!     bytes and can never compare equal. --paranoid forces the sweep.
//!
//! zlib-family candidates are executed by the integrated `deflate/` engine
//! by default: an in-process reimplementation that reproduces the bit-exact
//! output of stock zlib releases 1.2.3 .. 1.3.2 (one-shot), collapsed
//! into the minimal set of output-equivalence-class representatives per
//! parameter combination (see `collapseGroups`). `--external-zlib` skips the
//! integrated engine and spawns the historical per-version binaries instead.
//!
//! Compared to the naive original (fixed level 1-2 probe, then a full
//! matrix hard-coded to windowBits=15, then a blind windowBits sweep), the
//! hint-driven order converges in a handful of attempts for the most common
//! real-world cases and eliminates thousands of provably-futile spawns.

const std = @import("std");
const hints = @import("hints.zig");
const profiles_mod = @import("profiles.zig");
const ui = @import("ui.zig");
const replicant = @import("zlib-replicant");
const zopfli_native = @import("zopfli/native.zig");
const miniz_tdefl = @import("miniz/tdefl.zig");
const zlibng = @import("zlibng/deflate.zig");

pub const Stage = enum {
    hinted,
    trusted,
    distrust,

    pub fn label(s: Stage) []const u8 {
        return switch (s) {
            .hinted => "Stage 1: metadata-guided pass",
            .trusted => "Stage 2: full parameter matrix, trusted window",
            .distrust => "Stage 3: windowBits distrust sweep",
        };
    }

    pub fn tag(s: Stage) []const u8 {
        return switch (s) {
            .hinted => "P1",
            .trusted => "P2",
            .distrust => "P3",
        };
    }
};

pub const Candidate = struct {
    profile: u16,
    level: i8 = 0,
    mem_level: u8 = 8,
    strategy: u8 = 0,
    window_bits: u8 = 15,
    iterations: u32 = 0,
    /// Ordering hint inside the profile (lower = earlier).
    score: u32 = 0,
};

pub const Options = struct {
    binaries_dir: []const u8,
    paranoid: bool = false,
    /// Search additional, uncommon Zopfli iteration counts in stage 2.
    extended_zopfli: bool = false,
    /// Skip the integrated engine and spawn the per-version zlib binaries
    /// instead (the original tool's behavior; useful for cross-checking).
    external_zlib: bool = false,
};

pub const Match = struct {
    profile: profiles_mod.Profile,
    stage: Stage,
    level: i8,
    mem_level: u8,
    strategy: u8,
    window_bits: u8,
    iterations: u32,
    attempts: usize,
    elapsed_ms: i64,
    /// Version range covered by an integrated-engine match ("" otherwise).
    version_range: []const u8 = "",
};

/// Zopfli iteration list, capped for very large inputs: high iteration
/// counts on multi-megabyte inputs take minutes while almost never being
/// the producer of a random stream.
pub fn zopfliIterations(uncompressed_len: usize) []const u32 {
    if (uncompressed_len > 16 * 1024 * 1024) return &.{ 1, 2, 3, 5, 10, 15 };
    if (uncompressed_len > 1024 * 1024) return &.{ 1, 2, 3, 5, 10, 15, 50 };
    return &.{ 1, 2, 3, 5, 10, 15, 50, 100, 250, 500 };
}

/// A second-pass search of iteration counts between the fast defaults.
/// Skipped in ordinary searches: these candidates can each cost far more
/// CPU time than a complete zlib parameter matrix. Explicit opt-in only.
pub fn zopfliExtraIterations(uncompressed_len: usize) []const u32 {
    if (uncompressed_len > 16 * 1024 * 1024) return &.{};
    if (uncompressed_len > 1024 * 1024) return &.{ 4, 6, 8, 12, 20, 25, 30, 40 };
    return &.{ 4, 6, 7, 8, 9, 11, 12, 13, 14, 16, 20, 25, 30, 40, 60, 75, 125, 200, 300, 400 };
}

/// A zlib stream produced with level 0 (stored blocks) always occupies
/// more than uncompressed_len + 11 bytes (2-byte header + 5-byte block
/// header + 4-byte Adler-32 for a single block).
pub fn level0Possible(compressed_len: usize, uncompressed_len: usize) bool {
    return compressed_len >= uncompressed_len + 11;
}

/// Whether the profile takes part in the search in the given mode.
///
/// Default mode: the integrated engine covers every stock zlib release
/// 1.2.3-1.4 (tested one-shot + streaming matrices), so those binaries are redundant.
/// `--external-zlib` flips this: integrated engine off, all binaries on.
pub fn profileWanted(p: profiles_mod.Profile, external_zlib: bool) bool {
    return switch (p.impl_type) {
        .integrated => !external_zlib,
        .zopfli_native => !external_zlib,
        .miniz_native => !external_zlib,
        .zlibng_native => !external_zlib,
        .zopfli => external_zlib,
        .miniz => external_zlib,
        .zlib_family => external_zlib or !p.covered_by_integrated,
        .legacy_zlib => external_zlib,
        else => true,
    };
}

/// Whether the profile runs in-process in the current mode (no binary on
/// disk needed).
fn nativeInProcess(t: profiles_mod.ImplType) bool {
    return switch (t) {
        .integrated, .zopfli_native, .miniz_native, .zlibng_native => true,
        else => false,
    };
}

/// Number of profiles the current mode can actually execute (binary
/// presence checked for external ones) — used for the CLI status line.
pub fn countAvailable(io: std.Io, binaries_dir: []const u8, external_zlib: bool) usize {
    var n: usize = 0;
    for (profiles_mod.profiles) |p| {
        if (!profileWanted(p, external_zlib)) continue;
        if (nativeInProcess(p.impl_type)) {
            n += 1;
            continue;
        }
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ binaries_dir, p.binary }) catch continue;
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            n += 1;
        } else |_| {}
    }
    return n;
}

/// Search state shared by the stage builders and the executor.
const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    compressed: []const u8,
    uncompressed: []const u8,
    header: hints.Header,
    first_block: ?hints.BlockInfo,
    target_header: u16,
    level0_ok: bool,
    paranoid: bool,
    extended_zopfli: bool = false,
    available: []const bool,
    exe_paths: []const []const u8,
    /// Temp file holding the uncompressed payload (fed to child stdin).
    input_tmp_path: []const u8,
    visited: *std.AutoHashMap(u64, void),
    rep: *ui.Reporter,
    attempts: usize = 0,
    stage: Stage = .hinted,
    elapsed_ms: i64 = 0,
    /// Lazily-initialized integrated deflate engine (in-process candidates).
    compressor: ?replicant.Compressor = null,
    /// Scratch buffer for one compressed candidate (sized once).
    output_buf: ?[]u8 = null,
    /// Lazily-initialized native miniz tdefl engine (in-process candidates).
    miniz_compressor: ?miniz_tdefl.Compressor = null,
    /// Lazily-initialized native zlib-ng engine (heap-allocated; the state
    /// including the 64K hash table is several hundred KB).
    zlibng_compressor: ?*zlibng.Compressor = null,

    fn ensureCompressor(self: *Ctx, uncompressed_len: usize) bool {
        if (self.compressor == null) {
            self.compressor = replicant.Compressor.init(self.gpa) catch return false;
        }
        if (self.output_buf == null) {
            const size = replicant.Compressor.requiredOutputLen(uncompressed_len);
            self.output_buf = self.gpa.alloc(u8, size) catch return false;
        }
        return true;
    }

    fn releaseCompressor(self: *Ctx) void {
        if (self.compressor) |*c| c.deinit();
        self.compressor = null;
        if (self.output_buf) |b| self.gpa.free(b);
        self.output_buf = null;
        if (self.miniz_compressor) |*c| c.deinit();
        self.miniz_compressor = null;
        if (self.zlibng_compressor) |c| {
            c.deinit();
            self.gpa.destroy(c);
        }
        self.zlibng_compressor = null;
    }

    fn ensureZlibng(self: *Ctx) bool {
        if (self.zlibng_compressor == null) {
            const c = self.gpa.create(zlibng.Compressor) catch return false;
            c.* = zlibng.Compressor.init(self.gpa);
            self.zlibng_compressor = c;
        }
        return true;
    }

    fn ensureMiniz(self: *Ctx) bool {
        if (self.miniz_compressor == null)
            self.miniz_compressor = miniz_tdefl.Compressor.init(self.gpa);
        return true;
    }
};

fn pack(c: Candidate) u64 {
    var v: u64 = 0;
    v |= @as(u64, c.profile) << 48;
    v |= @as(u64, c.iterations & 0xFFFF) << 32;
    v |= @as(u64, @as(u8, @intCast(c.level + 1))) << 24;
    v |= @as(u64, c.mem_level) << 16;
    v |= @as(u64, c.strategy) << 8;
    v |= c.window_bits;
    return v;
}

/// Header the candidate would emit; null when unpredictable.
fn predictedHeader(p: profiles_mod.Profile, c: Candidate) ?u16 {
    if (p.legacy_class != null or p.impl_type == .legacy_zlib) {
        // The header conventions of every historical class are now verified
        // (source diff + official binaries; see EQUIVALENCE.md): classes A-C
        // use the pre-1.2.1 FLEVEL formula, class D the modern one.
        const class = profiles_mod.zlibClass(p) orelse return null;
        return switch (class) {
            .a, .b, .c => hints.zlibLegacyContainerHeader(c.window_bits, c.level),
            else => hints.zlibContainerHeader(c.window_bits, c.level, c.strategy),
        };
    }
    return switch (p.impl_type) {
        // The integrated engine writes exactly the same container header as
        // any stock zlib-family implementation (see the zlib-replicant
        // engine's pump); so does
        // zlib-ng's compat API (same FLEVEL formula, CINFO from w_bits).
        .integrated, .zlib_family, .zlibng_native => hints.zlibContainerHeader(c.window_bits, c.level, c.strategy),
        .legacy_zlib => null,
        .zopfli, .zopfli_native => profiles_mod.zopfliHeaderOf(p),
        .libdeflate => if (c.level >= 1) hints.libdeflateHeader(@intCast(c.level)) else null,
        .miniz, .miniz_native => if (c.level >= 1) hints.minizHeader(@intCast(c.level)) else null,
        .advdef => null,
    };
}

test "legacy classes now carry the verified pre-1.2.1 header filter" {
    const class_c = profiles_mod.profiles[3];
    try std.testing.expectEqual(profiles_mod.ImplType.integrated, class_c.impl_type);
    try std.testing.expect(class_c.legacy_class != null);
    // level 6 -> legacy FLEVEL 2 (78 9c) regardless of strategy.
    try std.testing.expectEqual(@as(u16, 0x789C), predictedHeader(class_c, .{ .profile = 3, .level = 6 }).?);
    // level 0 -> FLEVEL 3 (78 da).
    try std.testing.expectEqual(@as(u16, 0x78DA), predictedHeader(class_c, .{ .profile = 3, .level = 0 }).?);
    // External class-D binary: modern formula, strategy-aware.
    var class_d_idx: usize = 0;
    for (profiles_mod.profiles, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, "zlib 1.2.2")) class_d_idx = i;
    }
    const class_d_external = profiles_mod.profiles[class_d_idx];
    try std.testing.expectEqual(profiles_mod.ImplType.legacy_zlib, class_d_external.impl_type);
    try std.testing.expectEqual(@as(u16, 0x7801), predictedHeader(class_d_external, .{ .profile = @intCast(class_d_idx), .level = 6, .strategy = 2 }).?);
    try std.testing.expect(!profileWanted(class_d_external, false));
    try std.testing.expect(profileWanted(class_d_external, true));
}

test "historical class priority follows D, C, B, A" {
    try std.testing.expectEqual(@as(u16, 0), effectivePrior(profiles_mod.profiles[0]));
    for (1..5) |i| {
        try std.testing.expectEqual(@as(u16, @intCast(i)), effectivePrior(profiles_mod.profiles[i]));
    }
    try std.testing.expect(effectivePrior(profiles_mod.profiles[5]) > 4);
}

test "in-process Zopfli replaces external CLI only in default search mode" {
    var internal: ?profiles_mod.Profile = null;
    var external: ?profiles_mod.Profile = null;
    for (profiles_mod.profiles) |p| {
        if (p.impl_type == .zopfli_native) internal = p;
        if (p.impl_type == .zopfli) external = p;
    }
    try std.testing.expect(internal != null and external != null);
    try std.testing.expect(profileWanted(internal.?, false));
    try std.testing.expect(!profileWanted(external.?, false));
    try std.testing.expect(!profileWanted(internal.?, true));
    try std.testing.expect(profileWanted(external.?, true));
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    const pa = effectivePrior(profiles_mod.profiles[a.profile]);
    const pb = effectivePrior(profiles_mod.profiles[b.profile]);
    if (pa != pb) return pa < pb;
    return a.score < b.score;
}

/// Modern streams dominate in practice; among early releases the newer
/// generations D and C are likelier than B and A. External alternatives
/// follow the in-process historical classes.
fn effectivePrior(p: profiles_mod.Profile) u16 {
    if (p.legacy_class) |class| return switch (class) {
        .d => 1, .c => 2, .b => 3, .a => 4,
        else => 5,
    };
    if (p.impl_type == .integrated) return 0;
    if (p.impl_type == .zopfli_native) return 39;
    if (p.impl_type == .zlibng_native) return 37; // external zlib-ng's effective prior
    return @as(u16, p.prior) + 10;
}

const StageBuilder = struct {
    ctx: *Ctx,
    alloc: std.mem.Allocator,
    list: std.ArrayList(Candidate) = .empty,
    /// Stage 3 targets headers no stock implementation can emit, so the
    /// prediction filter must be disabled there.
    filter_header: bool = true,

    fn push(self: *StageBuilder, c: Candidate) !void {
        const p = profiles_mod.profiles[c.profile];
        if (self.filter_header) {
            if (predictedHeader(p, c)) |ph| {
                if (ph != self.ctx.target_header) return;
            }
        }
        const key = pack(c);
        if (self.ctx.visited.contains(key)) return;
        try self.ctx.visited.put(key, {});
        try self.list.append(self.alloc, c);
    }

    fn pushScored(self: *StageBuilder, c: Candidate, score: usize) !void {
        var copy = c;
        copy.score = @intCast(score);
        try self.push(copy);
    }
};

/// Hinted (level, strategy) probes for zlib-family implementations,
/// indexed by the observed FLEVEL class.
const ZlibProbe = struct { level: i8, strategy: u8 };

fn hintedZlibProbes(flevel: hints.Flevel, buf: []ZlibProbe) []ZlibProbe {
    return switch (flevel) {
        // FLEVEL=0: level 0..1 (default/filtered strategy) or any level
        // with HUFFMAN_ONLY / RLE / FIXED. HUFFMAN_ONLY output is
        // level-independent in every era (verified: levels 1/4/9 emit
        // identical bytes on text, random, repeat and periodic corpora);
        // RLE is level-independent only from 1.2.4 — the 1.2.3-and-earlier
        // engine runs it through deflate_fast/deflate_slow, so the level-1
        // fast-path twin is probed as well; FIXED goes through
        // deflate_slow and is level-dependent (stage 2 sweeps it).
        0 => blk: {
            var n: usize = 0;
            buf[n] = .{ .level = 1, .strategy = 0 };
            n += 1;
            buf[n] = .{ .level = 1, .strategy = 1 };
            n += 1;
            buf[n] = .{ .level = 9, .strategy = 2 };
            n += 1;
            buf[n] = .{ .level = 9, .strategy = 3 };
            n += 1;
            buf[n] = .{ .level = 1, .strategy = 3 };
            n += 1;
            buf[n] = .{ .level = 9, .strategy = 4 };
            n += 1;
            break :blk buf[0..n];
        },
        1 => blk: {
            const levels = [_]i8{ 5, 4, 3, 2 };
            var n: usize = 0;
            for (levels) |l| {
                buf[n] = .{ .level = l, .strategy = 0 };
                n += 1;
            }
            // Z_FILTERED keeps the level-based FLEVEL; one twin probe so a
            // modern filtered stream is attributed to the modern engine
            // before any legacy class that reproduces the same bytes.
            buf[n] = .{ .level = 5, .strategy = 1 };
            n += 1;
            break :blk buf[0..n];
        },
        2 => blk: {
            buf[0] = .{ .level = 6, .strategy = 0 };
            buf[1] = .{ .level = 6, .strategy = 1 };
            break :blk buf[0..2];
        },
        3 => blk: {
            const levels = [_]i8{ 9, 8, 7 };
            for (levels, 0..) |l, i| buf[i] = .{ .level = l, .strategy = 0 };
            break :blk buf[0..levels.len];
        },
    };
}

/// Hinted probes for the pre-1.2.1 classes A-C, whose FLEVEL depends on
/// the level only: (level-1)>>1 clamped to 3, so FLEVEL 0 <- levels 1-2,
/// 1 <- 3-4, 2 <- 5-6, 3 <- 7-9 and level 0. Strategies 1 and 2 exist in
/// these releases and change the payload but not the header, so one twin
/// probe each is included; the modern profile carries the matching filtered
/// twin, so a stream reproducible by both still attributes to modern first.
fn legacyProbes(flevel: hints.Flevel, buf: []ZlibProbe) []ZlibProbe {
    const levels: []const i8 = switch (flevel) {
        0 => &.{ 1, 2 },
        1 => &.{ 3, 4 },
        2 => &.{ 5, 6 },
        3 => &.{ 9, 8, 7 },
    };
    var n: usize = 0;
    for (levels) |l| {
        buf[n] = .{ .level = l, .strategy = 0 };
        n += 1;
    }
    buf[n] = .{ .level = levels[0], .strategy = 1 };
    n += 1;
    buf[n] = .{ .level = levels[0], .strategy = 2 };
    n += 1;
    return buf[0..n];
}

fn firstBlockIsStored(fb: ?hints.BlockInfo) bool {
    const b = fb orelse return false;
    return b.btype == 0;
}

fn buildStage1(ctx: *Ctx, alloc: std.mem.Allocator) ![]Candidate {
    var b = StageBuilder{ .ctx = ctx, .alloc = alloc };

    // A non-canonical header cannot be emitted by any stock implementation,
    // so there is nothing to probe quickly.
    if (!ctx.header.canonical()) return b.list.toOwnedSlice(alloc);

    var probe_buf: [8]ZlibProbe = undefined;
    for (profiles_mod.profiles, 0..) |p, idx| {
        if (!ctx.available[idx]) continue;
        switch (p.impl_type) {
            .integrated, .zlib_family, .legacy_zlib, .zlibng_native => {
                const wb = ctx.header.window_bits;
                const is_legacy_abc = if (p.legacy_class) |cls|
                    (cls == .a or cls == .b or cls == .c)
                else
                    false;
                var score: u32 = 0;
                if (ctx.level0_ok and firstBlockIsStored(ctx.first_block)) {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = 0,
                        .mem_level = 8,
                        .strategy = 0,
                        .window_bits = wb,
                    }, score);
                    score += 1;
                }
                // Classes A-C use the pre-1.2.1 level-only FLEVEL mapping;
                // class D and every modern profile use the modern probes.
                const probes = if (is_legacy_abc)
                    legacyProbes(ctx.header.flevel, &probe_buf)
                else
                    hintedZlibProbes(ctx.header.flevel, &probe_buf);
                for (probes) |probe| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = probe.level,
                        .mem_level = 8,
                        .strategy = probe.strategy,
                        .window_bits = wb,
                    }, score);
                    score += 1;
                }
            },
            .zopfli, .zopfli_native => {
                // Zopfli's zlib container header depends on the release:
                // 1.0.2+ write FLEVEL=3 (0x78DA), 1.0.0/1.0.1 wrote FLEVEL=0
                // (0x7801). The collapsed 1.0.2 profile is skipped: it is
                // byte-identical to the 1.0.3 representative.
                if (p.collapsed_into != null) continue;
                if (ctx.target_header != profiles_mod.zopfliHeaderOf(p)) continue;
                for (zopfliIterations(ctx.uncompressed.len), 0..) |it, i| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .iterations = it,
                        .window_bits = 15,
                    }, @intCast(i));
                }
            },
            .libdeflate => {
                // libdeflate always writes CINFO=7 (fixed 32K window).
                if (ctx.header.cinfo != 7) continue;
                const levels: []const u32 = switch (ctx.header.flevel) {
                    0 => &.{1},
                    1 => &.{ 2, 3, 4, 5 },
                    2 => &.{ 6, 7 },
                    3 => &.{ 8, 9, 10, 11, 12 },
                };
                for (levels, 0..) |l, i| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = @intCast(l),
                        .window_bits = 15,
                    }, @intCast(i));
                }
            },
            .miniz, .miniz_native => {
                if (ctx.header.cinfo != 7) continue;
                const levels: []const u32 = switch (ctx.header.flevel) {
                    0 => &.{1},
                    1 => &.{ 2, 3, 4, 5 },
                    2 => &.{6},
                    3 => &.{ 7, 8, 9, 10 },
                };
                for (levels, 0..) |l, i| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = @intCast(l),
                        .window_bits = 15,
                    }, @intCast(i));
                }
            },
            .advdef => {},
        }
    }
    return b.list.toOwnedSlice(alloc);
}

fn buildStage2(ctx: *Ctx, alloc: std.mem.Allocator) ![]Candidate {
    var b = StageBuilder{ .ctx = ctx, .alloc = alloc };
    const mems = [_]u8{ 8, 9, 7, 6, 5, 4, 3, 2, 1 };

    for (profiles_mod.profiles, 0..) |p, idx| {
        if (!ctx.available[idx]) continue;
        switch (p.impl_type) {
            .integrated, .zlib_family, .legacy_zlib, .zlibng_native => {
                // With a canonical header, any parameter combination whose
                // FLEVEL class differs would emit different FLG bytes.
                if (!ctx.header.canonical()) continue;
                const wb = ctx.header.window_bits;
                const legacy_class = p.legacy_class orelse profiles_mod.zlibClass(p);
                const is_legacy_abc = if (legacy_class) |cls|
                    (cls == .a or cls == .b or cls == .c)
                else
                    false;
                // Classes A-C map FLEVEL from the level only; class D and
                // the modern profiles use the strategy-aware formula (their
                // headers are now all predictable, so the hinted lists
                // prune directly instead of pushing every level).
                const strat01_levels: []const i8 = if (is_legacy_abc) switch (ctx.header.flevel) {
                    0 => &.{ 1, 2 },
                    1 => &.{ 3, 4 },
                    2 => &.{ 5, 6 },
                    3 => &.{ 9, 8, 7, 0 },
                } else switch (ctx.header.flevel) {
                    0 => &.{ 1, 0 },
                    1 => &.{ 5, 4, 3, 2 },
                    2 => &.{6},
                    3 => &.{ 9, 8, 7 },
                };
                for (strat01_levels) |level| {
                    if (level == 0 and !ctx.level0_ok) continue;
                    for ([_]u8{ 0, 1 }, 0..) |strat, srank| {
                        for (mems, 0..) |mem, mrank| {
                            try b.pushScored(.{
                                .profile = @intCast(idx),
                                .level = level,
                                .mem_level = mem,
                                .strategy = strat,
                                .window_bits = wb,
                            }, mrank * 100 + srank * 10);
                        }
                    }
                }
                if (is_legacy_abc) {
                    // Strategies 0-2 exist in 1.0.x-1.2.0 and none of them
                    // touches the header; strategy 2 skips the match search
                    // inside deflate_fast/slow, so every hinted level is a
                    // distinct candidate (unlike class D, where only level 9
                    // suffices because the header forces FLEVEL=0). At level
                    // 0 the strategy is ignored by deflate_stored, so only
                    // the strategy-0 twin above is needed.
                    for (strat01_levels) |level| {
                        if (level == 0) continue;
                        for (mems, 0..) |mem, mrank| {
                            try b.pushScored(.{
                                .profile = @intCast(idx),
                                .level = level,
                                .mem_level = mem,
                                .strategy = 2,
                                .window_bits = wb,
                            }, 1000 + mrank);
                        }
                    }
                } else {
                    // Z_HUFFMAN_ONLY (2) has no match search, so the level
                    // does not matter — but lit_bufsize (memLevel) shifts
                    // the block flush timing, so every memLevel is a
                    // distinct output. One level (9) sweep per strategy.
                    // Z_RLE (3) is level-independent only from 1.2.4
                    // (dedicated deflate_rle); classes D/E implement it
                    // through deflate_fast/deflate_slow with
                    // longest_match_fast, whose search parameters come from
                    // the level's configuration entry — the fast
                    // (levels 1-3) and slow (4-9) families emit different
                    // streams (witness: 65535 repeated bytes, level 1 ->
                    // 150 bytes, level 4+ -> 85). Strategy 3 therefore
                    // sweeps every level, level 9 first so uniform streams
                    // keep converging early. The header-prediction filter
                    // drops these for FLEVEL != 0 (strategies >= 2 always
                    // write FLEVEL=0). Z_FIXED does not exist before 1.2.3,
                    // so class D only gets strategies 2 and 3 here.
                    for ([_]u8{ 2, 3 }, 0..) |strat, srank| {
                        for (mems, 0..) |mem, mrank| {
                            try b.pushScored(.{
                                .profile = @intCast(idx),
                                .level = 9,
                                .mem_level = mem,
                                .strategy = strat,
                                .window_bits = wb,
                            }, 1000 + srank * 100 + mrank);
                        }
                    }
                    const strat3_levels: []const i8 = switch (ctx.header.flevel) {
                        0 => &.{ 1, 2, 3, 4, 5, 6, 7, 8 },
                        else => &.{},
                    };
                    for (strat3_levels, 0..) |level, lrank| {
                        for (mems, 0..) |mem, mrank| {
                            try b.pushScored(.{
                                .profile = @intCast(idx),
                                .level = level,
                                .mem_level = mem,
                                .strategy = 3,
                                .window_bits = wb,
                            }, 1000 + 3 * 100 + lrank * 2 + mrank);
                        }
                    }
                    // Z_FIXED goes through deflate_slow and is
                    // level-dependent (1.2.3+ only).
                    const strat4_levels: []const i8 = if (legacy_class != null) &.{} else switch (ctx.header.flevel) {
                        0 => &.{ 9, 6, 5, 4, 7, 3, 8, 2, 1 },
                        else => &.{},
                    };
                    for (strat4_levels, 0..) |level, lrank| {
                        for (mems, 0..) |mem, mrank| {
                            try b.pushScored(.{
                                .profile = @intCast(idx),
                                .level = level,
                                .mem_level = mem,
                                .strategy = 4,
                                .window_bits = wb,
                            }, 1000 + 4 * 10 + lrank * 2 + mrank);
                        }
                    }
                }
            },
            .zopfli, .zopfli_native => {
                if (p.collapsed_into != null) continue;
                if (ctx.target_header != profiles_mod.zopfliHeaderOf(p)) continue;
                for (zopfliIterations(ctx.uncompressed.len)[6..], 0..) |it, i| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .iterations = it,
                        .window_bits = 15,
                    }, @intCast(i));
                }
                if (ctx.extended_zopfli) {
                    for (zopfliExtraIterations(ctx.uncompressed.len), 0..) |it, i| {
                        try b.pushScored(.{
                            .profile = @intCast(idx),
                            .iterations = it,
                            .window_bits = 15,
                        }, @intCast(1000 + i));
                    }
                }
            },
            .libdeflate => {
                if (ctx.header.cinfo != 7) continue;
                for (1..13) |l| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = @intCast(l),
                        .window_bits = 15,
                    }, @intCast(l));
                }
            },
            .miniz, .miniz_native => {
                if (ctx.header.cinfo != 7) continue;
                for (1..11) |l| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = @intCast(l),
                        .window_bits = 15,
                    }, @intCast(l));
                }
            },
            .advdef => {
                for (1..5) |l| {
                    try b.pushScored(.{
                        .profile = @intCast(idx),
                        .level = @intCast(l),
                    }, @intCast(l));
                }
            },
        }
    }
    std.mem.sort(Candidate, b.list.items, {}, candidateLessThan);
    return b.list.toOwnedSlice(alloc);
}

fn buildStage3(ctx: *Ctx, alloc: std.mem.Allocator) ![]Candidate {
    var b = StageBuilder{ .ctx = ctx, .alloc = alloc, .filter_header = false };
    // FDICT streams require the exact preset dictionary: no dict-less
    // candidate can ever reproduce them.
    if (ctx.header.fdict) return b.list.toOwnedSlice(alloc);

    const force_sweep = ctx.paranoid or !ctx.header.canonical();
    if (!force_sweep) return b.list.toOwnedSlice(alloc);

    const mems = [_]u8{ 8, 9, 7, 6, 5, 4, 3, 2, 1 };
    const trusted = ctx.header.window_bits;

    for (profiles_mod.profiles, 0..) |p, idx| {
        if (!ctx.available[idx]) continue;
        if (p.impl_type != .zlib_family and p.impl_type != .integrated and p.impl_type != .legacy_zlib and
            p.impl_type != .zlibng_native) continue;

        const legacy_class = p.legacy_class orelse profiles_mod.zlibClass(p);
        const is_legacy_abc = if (legacy_class) |cls|
            (cls == .a or cls == .b or cls == .c)
        else
            false;

        var wbs: [10]u8 = undefined;
        var n_wbs: usize = 0;
        if (!ctx.header.canonical()) {
            wbs[n_wbs] = trusted;
            n_wbs += 1;
        }
        const tail = [_]u8{ 15, 14, 13, 12, 11, 10, 9, 8 };
        for (tail) |wb| {
            if (wb == trusted and ctx.header.canonical()) continue;
            var dup = false;
            for (wbs[0..n_wbs]) |seen| {
                if (seen == wb) dup = true;
            }
            if (!dup) {
                // windowBits 8: rejected outright by the 1.1.0-1.2.0
                // releases. (The 1.0.x releases accept it; level 0 is probed,
                // level >= 1 is the documented out-of-bounds path and is
                // skipped at run time.)
                if (wb == 8 and legacy_class == .c) continue;
                wbs[n_wbs] = wb;
                n_wbs += 1;
            }
        }

        for (wbs[0..n_wbs], 0..) |wb, wrank| {
            for (0..10) |li| {
                const level: i8 = @intCast(9 - li);
                if (level == 0 and !ctx.level0_ok) continue;
                for (mems, 0..) |mem, mrank| {
                    // Strategy sets per generation: {0,1,2} for classes A-C,
                    // {0,1,2,3} for class D, all five for 1.2.3+.
                    const strats: []const u8 = if (is_legacy_abc) &.{ 0, 1, 2 } else if (legacy_class != null) &.{ 0, 1, 2, 3 } else &.{ 0, 1, 4, 2, 3 };
                    for (strats, 0..) |strat, srank| {
                        try b.pushScored(.{
                            .profile = @intCast(idx),
                            .level = level,
                            .mem_level = mem,
                            .strategy = strat,
                            .window_bits = wb,
                        }, @as(u32, @intCast(wrank)) * 100000 +
                            @as(u32, @intCast(mrank)) * 1000 +
                            srank * 100 + @as(u32, @intCast(li)));
                    }
                }
            }
        }
    }
    std.mem.sort(Candidate, b.list.items, {}, candidateLessThan);
    return b.list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

fn formatLevelArgs(buf: *[16]u8, value: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "0";
}

/// Compress `input` by spawning `argv` with stdin connected to the temp
/// input file. Returns the child's stdout bytes; error when the child could
/// not be spawned or exited with a non-zero status.
fn runChild(ctx: *Ctx, argv: []const []const u8) ![]u8 {
    const gpa = ctx.gpa;
    const io = ctx.io;

    const input_file = std.Io.Dir.cwd().openFile(io, ctx.input_tmp_path, .{}) catch
        return error.SpawnFailed;
    defer input_file.close(io);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = input_file },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.SpawnFailed;
    defer child.kill(io);

    var out_list: std.ArrayList(u8) = .empty;
    errdefer out_list.deinit(gpa);

    var rbuf: [16384]u8 = undefined;
    var file_reader = child.stdout.?.reader(io, &rbuf);
    const reader = &file_reader.interface;
    reader.appendRemaining(gpa, &out_list, .limited(1 << 31)) catch return error.ReadFailed;

    const term = child.wait(io) catch return error.SpawnFailed;
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.NonZeroExit;
    return out_list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Integrated engine (in-process zlib 1.2.3-1.4) execution
// ---------------------------------------------------------------------------

/// One output-equivalence-class representative of the integrated engine.
const CollapseGroup = struct {
    variant: replicant.Variant,
    /// Version range this representative reproduces bit-exactly for the
    /// current parameter combination.
    range: []const u8,
};

/// Minimal per-combination set of representatives covering all 13 historical
/// releases (see the zlib-replicant package for the full equivalence
/// analysis).
///
/// At level >= 1 the only boundary that changes bytes is strategy 2/3
/// (Z_HUFFMAN_ONLY/Z_RLE): zlib 1.2.3 dispatches inside deflate_fast/slow,
/// later releases use the dedicated deflate_huff/deflate_rle block states.
/// At level 0 the stored-block layout has three generations, and 1.2.4+
/// additionally dispatch Z_HUFFMAN_ONLY/Z_RLE to huff/rle *before* the
/// level-0 check (a heap-overflowing UB path in the real binaries).
fn collapseGroups(level: i32, strategy: u8) []const CollapseGroup {
    if (level == 0) {
        return switch (strategy) {
            2, 3 => &[_]CollapseGroup{
                .{ .variant = .z1_2_3, .range = "zlib 1.2.3" },
                .{ .variant = .z1_2_4_to_1_2_8, .range = "zlib 1.2.4-1.2.8" },
                .{ .variant = .z1_2_9, .range = "zlib 1.2.9" },
                .{ .variant = .z1_2_10_plus, .range = "zlib 1.2.10-1.4" },
            },
            else => &[_]CollapseGroup{
                .{ .variant = .z1_2_4_to_1_2_8, .range = "zlib 1.2.3-1.2.8" },
                .{ .variant = .z1_2_9, .range = "zlib 1.2.9" },
                .{ .variant = .z1_2_10_plus, .range = "zlib 1.2.10-1.4" },
            },
        };
    }
    return switch (strategy) {
        2, 3 => &[_]CollapseGroup{
            .{ .variant = .z1_2_4_to_1_2_8, .range = "zlib 1.2.4-1.4" },
            .{ .variant = .z1_2_3, .range = "zlib 1.2.3" },
        },
        else => &[_]CollapseGroup{
            .{ .variant = .z1_2_4_to_1_2_8, .range = "zlib 1.2.3-1.4" },
        },
    };
}

/// Runs one integrated candidate: compresses in-process with every
/// output-equivalence-class representative (1-4 attempts) and reports each.
fn runIntegrated(ctx: *Ctx, c: Candidate, stage: Stage) ?Match {
    const p = profiles_mod.profiles[c.profile];
    if (p.legacy_class) |class| return runLegacyIntegrated(ctx, c, stage, class);
    if (!ctx.ensureCompressor(ctx.uncompressed.len)) {
        report(ctx, p, c, false);
        return null;
    }

    for (collapseGroups(c.level, c.strategy)) |group| {
        ctx.attempts += 1;
        const matched = compressIntegrated(ctx, group.variant, c);

        var desc_buf: [160]u8 = undefined;
        const desc = std.fmt.bufPrint(
            &desc_buf,
            "{s} {s} | lvl={d} mem={d} strat={s} wBits={d} [{s}]",
            .{
                ctx.stage.tag(), p.name, c.level, c.mem_level,
                profiles_mod.STRATEGY_NAMES[@min(c.strategy, 4)], c.window_bits, group.range,
            },
        ) catch "attempt";
        ctx.rep.attempt(desc, matched);

        if (matched) {
            return .{
                .profile = p,
                .stage = stage,
                .level = c.level,
                .mem_level = c.mem_level,
                .strategy = c.strategy,
                .window_bits = c.window_bits,
                .iterations = c.iterations,
                .attempts = ctx.attempts,
                .elapsed_ms = ctx.elapsed_ms,
                .version_range = refineRange(ctx, group, c),
            };
        }
    }
    return null;
}

/// Historical class search. Every class now runs the shared native Zig
/// deflate engine with its class-specific variant and parameter limits
/// (class D since the earlier migration, classes A-C since the native port;
/// the original statically linked C cores remain available as differential
/// oracles through the `zlegacy` tool of the zlib-replicant package).
fn runLegacyIntegrated(ctx: *Ctx, c: Candidate, stage: Stage, class: profiles_mod.ZlibClass) ?Match {
    const p = profiles_mod.profiles[c.profile];
    if (!ctx.ensureCompressor(ctx.uncompressed.len)) return null;

    // Historical releases contain documented memory-unsafe or
    // non-deterministic edge paths. Do not probe them: the streams the
    // originals would emit there either do not exist (crashes) or depend
    // on out-of-bounds reads. They remain reachable with --external-zlib.
    //
    // * class A level 0 memLevel < 8: the 0xffff-clamped stored block
    //   overruns the pending buffer and the real 1.0.1-1.0.5 abort;
    // * level 0 with strategy >= 2: byte-identical to strategy 0 in these
    //   releases (deflate_stored ignores the strategy), so the strategy-0
    //   twin already covers the stream;
    // * classes A/B windowBits 8 at level >= 1: the 256-byte window makes
    //   MAX_DIST underflow and the match finder follows stale chain
    //   entries with wrapped distances into out-of-bounds reads;
    // * class C windowBits 8: rejected outright by 1.1.0-1.2.0;
    // * class D strategy 4: Z_FIXED does not exist before 1.2.3.
    if (class == .d and c.strategy > 3) return null;
    if (class != .d and c.level == 0 and c.strategy >= 2) return null;
    if (class == .a and c.level == 0 and c.mem_level < 8) return null;
    if (class == .a or class == .b) {
        if (c.window_bits == 8 and c.level >= 1) return null;
    }
    if (class == .c and c.window_bits == 8) return null;

    const version: replicant.Version = switch (class) {
        .a => .v1_0_5,
        .b => .v1_0_9,
        .c => .v1_2_0,
        .d => .v1_2_2,
        else => return null,
    };

    ctx.attempts += 1;
    const matched = blk: {
        _ = ctx.compressor.?.compressExpect(version, @intCast(@max(c.level, 0)),
            c.mem_level, c.strategy, c.window_bits, ctx.uncompressed,
            ctx.output_buf.?, ctx.compressed) catch break :blk false;
        break :blk true;
    };
    var desc_buf: [160]u8 = undefined;
    const desc = std.fmt.bufPrint(&desc_buf, "{s} {s} | lvl={d} mem={d} strat={s} wBits={d}", .{
        ctx.stage.tag(), p.name, c.level, c.mem_level,
        profiles_mod.STRATEGY_NAMES[@min(c.strategy, 4)], c.window_bits,
    }) catch "attempt";
    ctx.rep.attempt(desc, matched);
    if (!matched) return null;
    return .{
        .profile = p, .stage = stage, .level = c.level,
        .mem_level = c.mem_level, .strategy = c.strategy,
        .window_bits = c.window_bits, .iterations = 0,
        .attempts = ctx.attempts, .elapsed_ms = ctx.elapsed_ms,
        .version_range = profiles_mod.classRange(class),
    };
}

/// Compresses `ctx.uncompressed` in-process and compares the output against
/// the original stream with early abort on the first divergent output chunk.
fn compressIntegrated(ctx: *Ctx, variant: replicant.Variant, c: Candidate) bool {
    const compressor = &ctx.compressor.?;
    const out = ctx.output_buf.?;
    _ = compressor.compressExpect(
        variant.toVersion(),
        @intCast(@max(c.level, 0)),
        c.mem_level,
        c.strategy,
        c.window_bits,
        ctx.uncompressed,
        out,
        ctx.compressed,
    ) catch return false;
    return true;
}

/// Widens the reported version range when the matched class
/// representative's output is also reproduced by the neighboring classes.
///
/// The byte-level differences between classes need particular block
/// layouts to actually materialize; when they do not, every class whose
/// representative reproduces the stream is honestly part of the range.
/// Silent re-compressions only (not counted as search attempts).
fn refineRange(ctx: *Ctx, group: CollapseGroup, c: Candidate) []const u8 {
    switch (group.variant) {
        .z1_2_4_to_1_2_8 => {
            if (c.level < 1) {
                // Level 0: the legacy stored layout may coincide with the
                // newer generations on this particular payload.
                if (compressIntegrated(ctx, .z1_2_9, c)) {
                    if (compressIntegrated(ctx, .z1_2_10_plus, c)) return "zlib 1.2.3-1.4";
                    return "zlib 1.2.3-1.2.9";
                }
                return group.range;
            }
            // Level >= 1: strategies 2/3 split off the 1.2.3 block states;
            // the divergence needs the fill_window/block-flush timings to
            // drift apart.
            if (c.strategy != 2 and c.strategy != 3) return group.range;
            if (compressIntegrated(ctx, .z1_2_3, c)) return "zlib 1.2.3-1.4";
            return group.range;
        },
        .z1_2_9 => {
            if (compressIntegrated(ctx, .z1_2_10_plus, c)) return "zlib 1.2.9-1.4";
            return group.range;
        },
        else => return group.range,
    }
}

fn runCandidateInner(ctx: *Ctx, c: Candidate, stage: Stage) ?Match {
    const p = profiles_mod.profiles[c.profile];

    if (p.impl_type == .integrated) {
        return runIntegrated(ctx, c, stage);
    }
    if (p.impl_type == .zopfli_native) {
        ctx.attempts += 1;
        const output = zopfli_native.compress(ctx.gpa, ctx.uncompressed, c.iterations, p.release orelse .v1_0_3) catch {
            report(ctx, p, c, false);
            return null;
        };
        defer ctx.gpa.free(output);
        const matched = std.mem.eql(u8, output, ctx.compressed);
        report(ctx, p, c, matched);
        if (!matched) return null;
        return .{
            .profile = p, .stage = stage, .level = c.level,
            .mem_level = c.mem_level, .strategy = c.strategy,
            .window_bits = c.window_bits, .iterations = c.iterations,
            .attempts = ctx.attempts, .elapsed_ms = ctx.elapsed_ms,
            .version_range = profiles_mod.zopfliGroupRange(p) orelse "",
        };
    }
    if (p.impl_type == .miniz_native) {
        ctx.attempts += 1;
        if (!ctx.ensureMiniz()) {
            report(ctx, p, c, false);
            return null;
        }
        const output = ctx.miniz_compressor.?.compressZlib(ctx.uncompressed, @intCast(@max(c.level, 1))) catch {
            report(ctx, p, c, false);
            return null;
        };
        defer ctx.gpa.free(output);
        const matched = std.mem.eql(u8, output, ctx.compressed);
        report(ctx, p, c, matched);
        if (!matched) return null;
        return .{
            .profile = p, .stage = stage, .level = c.level,
            .mem_level = c.mem_level, .strategy = c.strategy,
            .window_bits = 15, .iterations = 0,
            .attempts = ctx.attempts, .elapsed_ms = ctx.elapsed_ms,
            .version_range = "miniz 3.1.2",
        };
    }

    if (p.impl_type == .zlibng_native) {
        ctx.attempts += 1;
        if (!ctx.ensureZlibng()) {
            report(ctx, p, c, false);
            return null;
        }
        // windowBits fixed to 15: the reference wrapper accepts the argument
        // but passes a literal 15 to deflateInit2.
        const out = ctx.zlibng_compressor.?.compressZlib(ctx.uncompressed, c.level, c.mem_level, c.strategy, 15) catch {
            report(ctx, p, c, false);
            return null;
        };
        defer ctx.gpa.free(out);
        const matched = std.mem.eql(u8, out, ctx.compressed);
        report(ctx, p, c, matched);
        if (!matched) return null;
        return .{
            .profile = p, .stage = stage, .level = c.level,
            .mem_level = c.mem_level, .strategy = c.strategy,
            .window_bits = 15, .iterations = 0,
            .attempts = ctx.attempts, .elapsed_ms = ctx.elapsed_ms,
            .version_range = "zlib-ng 2.2.1",
        };
    }

    ctx.attempts += 1;

    var nb: [4][16]u8 = undefined;
    var argv_buf: [8][]const u8 = undefined;
    argv_buf[0] = ctx.exe_paths[c.profile];
    var argv_len: usize = 1;
    var advdef_tmp: ?[]const u8 = null;

    switch (p.impl_type) {
        // .integrated never reaches this path (handled above).
        .integrated, .zopfli_native, .miniz_native, .zlibng_native => unreachable,
        .zlib_family, .legacy_zlib => {
            argv_buf[1] = formatLevelArgs(&nb[0], c.level);
            argv_buf[2] = formatLevelArgs(&nb[1], c.mem_level);
            argv_buf[3] = formatLevelArgs(&nb[2], c.strategy);
            argv_buf[4] = formatLevelArgs(&nb[3], c.window_bits);
            argv_len = 5;
        },
        .zopfli => {
            // zopfli reads a FILE argument (stdin is ignored) and, with -c,
            // writes the zlib container to stdout. The shared temp input file
            // is read-only for zopfli, so it can be reused across attempts.
            argv_buf[1] = "--zlib";
            argv_buf[2] = "-c";
            const it_arg = std.fmt.bufPrint(&nb[0], "--i{d}", .{c.iterations}) catch "--i1";
            argv_buf[3] = it_arg;
            argv_buf[4] = ctx.input_tmp_path;
            argv_len = 5;
        },
        .libdeflate, .miniz => {
            argv_buf[1] = formatLevelArgs(&nb[0], c.level);
            argv_len = 2;
        },
        .advdef => {
            const lvl = std.fmt.bufPrint(&nb[0], "-{d}", .{c.level}) catch "-1";
            argv_buf[1] = lvl;
            argv_buf[2] = "-z";
            argv_buf[3] = "-k";
            argv_buf[4] = "zf-advdef-tmp.bin";
            advdef_tmp = argv_buf[4];
            argv_len = 5;
        },
    }
    const argv = argv_buf[0..argv_len];

    var matched = false;
    if (advdef_tmp) |tmp_path| {
        advdef: {
            var work = std.Io.Dir.cwd().createFile(ctx.io, tmp_path, .{}) catch break :advdef;
            work.writeStreamingAll(ctx.io, ctx.uncompressed) catch {
                work.close(ctx.io);
                break :advdef;
            };
            work.close(ctx.io);
            defer std.Io.Dir.cwd().deleteFile(ctx.io, tmp_path) catch {};
            _ = runChild(ctx, argv) catch break :advdef;
            const recompressed = std.Io.Dir.cwd().readFileAlloc(ctx.io, tmp_path, ctx.gpa, .limited(1 << 31)) catch break :advdef;
            defer ctx.gpa.free(recompressed);
            matched = std.mem.eql(u8, recompressed, ctx.compressed);
        }
    } else {
        const out = runChild(ctx, argv) catch {
            report(ctx, p, c, false);
            return null;
        };
        defer ctx.gpa.free(out);
        matched = std.mem.eql(u8, out, ctx.compressed);
    }

    report(ctx, p, c, matched);

    if (matched) {
        return .{
            .profile = p,
            .stage = stage,
            .level = c.level,
            .mem_level = c.mem_level,
            .strategy = c.strategy,
            .window_bits = c.window_bits,
            .iterations = c.iterations,
            .attempts = ctx.attempts,
            .elapsed_ms = ctx.elapsed_ms,
            .version_range = if (p.impl_type == .legacy_zlib)
                (if (profiles_mod.zlibClass(p)) |group| profiles_mod.classRange(group) else "")
            else "",
        };
    }
    return null;
}

fn report(ctx: *Ctx, p: profiles_mod.Profile, c: Candidate, matched: bool) void {
    var desc_buf: [160]u8 = undefined;
    const tag = ctx.stage.tag();
    const desc = switch (p.impl_type) {
        .integrated => unreachable,
        .zlib_family, .legacy_zlib, .zlibng_native => std.fmt.bufPrint(&desc_buf, "{s} {s} | lvl={d} mem={d} strat={s} wBits={d}", .{
            tag, p.name, c.level, c.mem_level,
            profiles_mod.STRATEGY_NAMES[@min(c.strategy, 4)], c.window_bits,
        }) catch "attempt",
        .zopfli, .zopfli_native => std.fmt.bufPrint(&desc_buf, "{s} {s} | iterations={d}", .{
            tag, p.name, c.iterations,
        }) catch "attempt",
        .libdeflate, .miniz => std.fmt.bufPrint(&desc_buf, "{s} {s} | level={d}", .{
            tag, p.name, c.level,
        }) catch "attempt",
        .miniz_native => std.fmt.bufPrint(&desc_buf, "{s} {s} | level={d}", .{
            tag, p.name, c.level,
        }) catch "attempt",
        .advdef => std.fmt.bufPrint(&desc_buf, "{s} {s} | level=-{d}", .{
            tag, p.name, c.level,
        }) catch "attempt",
    };
    ctx.rep.attempt(desc, matched);
}

pub fn findExactMatch(
    gpa: std.mem.Allocator,
    io: std.Io,
    compressed: []const u8,
    uncompressed: []const u8,
    header: hints.Header,
    first_block: ?hints.BlockInfo,
    opts: Options,
    rep: *ui.Reporter,
) !?Match {
    // Availability scan: one stat per profile up front.
    var available: [profiles_mod.profiles.len]bool = undefined;
    var exe_paths: [profiles_mod.profiles.len][]const u8 = undefined;
    for (profiles_mod.profiles, 0..) |p, idx| {
        const path = try std.Io.Dir.path.join(gpa, &.{ opts.binaries_dir, p.binary });
        exe_paths[idx] = path;
        available[idx] = switch (p.impl_type) {
            // The integrated and in-process engines need no binary on disk.
            .integrated, .zopfli_native, .miniz_native, .zlibng_native => !opts.external_zlib,
            else => blk: {
                if (!profileWanted(p, opts.external_zlib)) break :blk false;
                std.Io.Dir.cwd().access(io, path, .{}) catch break :blk false;
                break :blk true;
            },
        };
    }
    defer for (exe_paths) |path| gpa.free(path);

    // Stash the uncompressed payload once in a temp file: every candidate
    // reads it through stdin without re-writing megabytes per attempt.
    const input_tmp_path = "zf-input-tmp.bin";
    {
        var f = std.Io.Dir.cwd().createFile(io, input_tmp_path, .{}) catch return error.TempFileFailed;
        defer f.close(io);
        f.writeStreamingAll(io, uncompressed) catch return error.TempFileFailed;
    }
    defer std.Io.Dir.cwd().deleteFile(io, input_tmp_path) catch {};

    var visited = std.AutoHashMap(u64, void).init(gpa);
    defer visited.deinit();

    const start_ts = std.Io.Timestamp.now(io, .awake);

    var ctx = Ctx{
        .gpa = gpa,
        .io = io,
        .compressed = compressed,
        .uncompressed = uncompressed,
        .header = header,
        .first_block = first_block,
        .target_header = header.word(),
        .level0_ok = level0Possible(compressed.len, uncompressed.len),
        .paranoid = opts.paranoid,
        .extended_zopfli = opts.extended_zopfli,
        .available = &available,
        .exe_paths = &exe_paths,
        .input_tmp_path = input_tmp_path,
        .visited = &visited,
        .rep = rep,
    };
    defer ctx.releaseCompressor();

    const stages = [_]Stage{ .hinted, .trusted, .distrust };
    for (stages) |st| {
        ctx.stage = st;
        ctx.elapsed_ms = elapsedMs(start_ts, ctx.io);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const list = switch (st) {
            .hinted => try buildStage1(&ctx, arena.allocator()),
            .trusted => try buildStage2(&ctx, arena.allocator()),
            .distrust => try buildStage3(&ctx, arena.allocator()),
        };
        // `list` is arena-owned: arena.deinit() (above) releases it.

        if (list.len == 0) {
            explainEmptyStage(&ctx, st);
            continue;
        }

        rep.stageStart(st.label(), list.len);
        for (list) |c| {
            if (runCandidateInner(&ctx, c, st)) |m0| {
                var m = m0;
                m.elapsed_ms = elapsedMs(start_ts, ctx.io);
                return m;
            }
        }
        rep.stageDone(st.label());
    }

    return null;
}

fn elapsedMs(start: std.Io.Timestamp, io: std.Io) i64 {
    const now = std.Io.Timestamp.now(io, .awake);
    const dur = start.durationTo(now);
    return @intCast(@divTrunc(dur.nanoseconds, std.time.ns_per_ms));
}

fn explainEmptyStage(ctx: *Ctx, st: Stage) void {
    switch (st) {
        .hinted => {
            if (!ctx.header.canonical()) {
                ctx.rep.note("stage 1 skipped: header is not canonical (CM={d}, CINFO={d}, FCHECK {s}{s})", .{
                    ctx.header.cm,
                    ctx.header.cinfo,
                    if (ctx.header.fcheck_ok) "ok" else "invalid",
                    if (ctx.header.fdict) ", FDICT set" else "",
                });
            }
        },
        .trusted => {
            if (!ctx.header.canonical()) {
                ctx.rep.note("stage 2 skipped: parameter matrix cannot reproduce a non-canonical header", .{});
            } else if (ctx.header.fdict) {
                ctx.rep.note("stage 2/3 skipped: preset dictionary (DICTID={x}) streams cannot be reproduced without the dictionary", .{ctx.header.dict_id orelse 0});
            }
        },
        .distrust => {
            if (ctx.header.fdict) {
                ctx.rep.note("stage 3 skipped: preset dictionary streams are out of reach", .{});
            } else if (ctx.header.canonical() and !ctx.paranoid) {
                ctx.rep.note("stage 3 skipped: a canonical header implies windowBits={d} (any other window would emit different header bytes); use --paranoid to sweep anyway", .{ctx.header.window_bits});
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "pack produces unique keys for distinct candidates" {
    const a = Candidate{ .profile = 0, .level = 6, .mem_level = 8, .strategy = 0, .window_bits = 15 };
    const b = Candidate{ .profile = 0, .level = 6, .mem_level = 8, .strategy = 0, .window_bits = 14 };
    const c = Candidate{ .profile = 1, .level = 6, .mem_level = 8, .strategy = 0, .window_bits = 15 };
    const d = Candidate{ .profile = 0, .level = 0, .mem_level = 8, .strategy = 0, .window_bits = 15 };
    try testing.expect(pack(a) != pack(b));
    try testing.expect(pack(a) != pack(c));
    try testing.expect(pack(a) != pack(d));
    try testing.expectEqual(pack(a), pack(a));
}

test "zopfliIterations shrinks for large inputs" {
    try testing.expectEqual(@as(usize, 10), zopfliIterations(1024).len);
    try testing.expectEqual(@as(usize, 7), zopfliIterations(2 * 1024 * 1024).len);
    try testing.expectEqual(@as(usize, 6), zopfliIterations(32 * 1024 * 1024).len);
}

test "supplementary Zopfli candidates never duplicate the standard schedule" {
    for ([_]usize{ 0, 1024, 2 * 1024 * 1024, 20 * 1024 * 1024 }) |size| {
        const primary = zopfliIterations(size);
        const extra = zopfliExtraIterations(size);
        for (extra, 0..) |iteration, i| {
            try std.testing.expect(iteration > 0 and iteration <= 500);
            for (primary) |existing| try std.testing.expect(iteration != existing);
            for (extra[0..i]) |previous| try std.testing.expect(iteration != previous);
        }
    }
}

test "level0Possible rejects impossible stored streams" {
    try testing.expect(!level0Possible(100, 100));
    try testing.expect(!level0Possible(105, 100));
    try testing.expect(level0Possible(112, 100));
}

test "stage1 for a default-level header starts with the hinted candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header = try hints.parseHeader(&[_]u8{ 0x78, 0x9C, 0x00 });
    var visited = std.AutoHashMap(u64, void).init(alloc);
    var rep = ui.Reporter.init(undefined, false, false, false);

    var available = [_]bool{false} ** profiles_mod.profiles.len;
    available[0] = true; // only the integrated engine present

    var exe_paths: [profiles_mod.profiles.len][]const u8 = undefined;
    for (&exe_paths) |*e| e.* = "/dev/null";

    var ctx = Ctx{
        .gpa = alloc,
        .io = undefined,
        .compressed = &.{},
        .input_tmp_path = "",
        .uncompressed = &.{},
        .header = header,
        .first_block = .{ .bfinal = 1, .btype = 2 },
        .target_header = header.word(),
        .level0_ok = false,
        .paranoid = false,
        .available = &available,
        .exe_paths = &exe_paths,
        .visited = &visited,
        .rep = &rep,
    };

    const list = try buildStage1(&ctx, alloc);
    // (6, default) first, then its Z_FILTERED twin (same FLEVEL class).
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(i8, 6), list[0].level);
    try testing.expectEqual(@as(u8, 8), list[0].mem_level);
    try testing.expectEqual(@as(u8, 0), list[0].strategy);
    try testing.expectEqual(@as(u8, 15), list[0].window_bits);
    try testing.expectEqual(@as(i8, 6), list[1].level);
    try testing.expectEqual(@as(u8, 1), list[1].strategy);
}

test "stage1 excludes implementations whose fixed header cannot match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // FLEVEL=2 (0x78 0x9C): Zopfli (always 0x7801) must be excluded.
    const header = try hints.parseHeader(&[_]u8{ 0x78, 0x9C, 0x00 });
    var visited = std.AutoHashMap(u64, void).init(alloc);
    var rep = ui.Reporter.init(undefined, false, false, false);

    var available = [_]bool{false} ** profiles_mod.profiles.len;
    for (&available) |*a| a.* = true;

    var exe_paths: [profiles_mod.profiles.len][]const u8 = undefined;
    for (&exe_paths) |*e| e.* = "/dev/null";

    var ctx = Ctx{
        .gpa = alloc,
        .io = undefined,
        .compressed = &.{},
        .input_tmp_path = "",
        .uncompressed = &.{},
        .header = header,
        .first_block = .{ .bfinal = 1, .btype = 2 },
        .target_header = header.word(),
        .level0_ok = false,
        .paranoid = false,
        .available = &available,
        .exe_paths = &exe_paths,
        .visited = &visited,
        .rep = &rep,
    };

    const list = try buildStage1(&ctx, alloc);
    for (list) |c| {
        const impl = profiles_mod.profiles[c.profile].impl_type;
        try testing.expect(impl != .zopfli);
        try testing.expect(impl != .advdef);
    }
}

test "stage2 with FLEVEL=2 only contains level-6 candidates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header = try hints.parseHeader(&[_]u8{ 0x78, 0x9C, 0x00 });
    var visited = std.AutoHashMap(u64, void).init(alloc);
    var rep = ui.Reporter.init(undefined, false, false, false);

    var available = [_]bool{false} ** profiles_mod.profiles.len;
    available[0] = true;

    var exe_paths: [profiles_mod.profiles.len][]const u8 = undefined;
    for (&exe_paths) |*e| e.* = "/dev/null";

    var ctx = Ctx{
        .gpa = alloc,
        .io = undefined,
        .compressed = &.{},
        .input_tmp_path = "",
        .uncompressed = &.{},
        .header = header,
        .first_block = null,
        .target_header = header.word(),
        .level0_ok = false,
        .paranoid = false,
        .available = &available,
        .exe_paths = &exe_paths,
        .visited = &visited,
        .rep = &rep,
    };

    // Stage 1 first: it must not leak candidates into stage 2 via dedup.
    const s1 = try buildStage1(&ctx, alloc);
    try testing.expect(s1.len > 0);

    const list = try buildStage2(&ctx, alloc);
    try testing.expect(list.len > 0);
    for (list) |c| {
        try testing.expectEqual(@as(i8, 6), c.level);
        try testing.expect(c.strategy <= 1);
        try testing.expectEqual(@as(u8, 15), c.window_bits);
    }
}

test "stage3 is empty for canonical headers unless paranoid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const header = try hints.parseHeader(&[_]u8{ 0x78, 0x9C, 0x00 });
    var visited = std.AutoHashMap(u64, void).init(alloc);
    var rep = ui.Reporter.init(undefined, false, false, false);

    var available = [_]bool{false} ** profiles_mod.profiles.len;
    for (&available) |*a| a.* = true;

    var exe_paths: [profiles_mod.profiles.len][]const u8 = undefined;
    for (&exe_paths) |*e| e.* = "/dev/null";

    var ctx = Ctx{
        .gpa = alloc,
        .io = undefined,
        .compressed = &.{},
        .input_tmp_path = "",
        .uncompressed = &.{},
        .header = header,
        .first_block = null,
        .target_header = header.word(),
        .level0_ok = false,
        .paranoid = false,
        .available = &available,
        .exe_paths = &exe_paths,
        .visited = &visited,
        .rep = &rep,
    };

    _ = try buildStage1(&ctx, alloc);
    _ = try buildStage2(&ctx, alloc);
    const s3 = try buildStage3(&ctx, alloc);
    try testing.expectEqual(@as(usize, 0), s3.len);

    ctx.paranoid = true;
    const s3p = try buildStage3(&ctx, alloc);
    try testing.expect(s3p.len > 0);
    for (s3p) |c| {
        try testing.expect(c.window_bits != 15);
    }
}

test "stage3 sweeps all windows for a non-canonical header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Invalid FCHECK (0x78 0x9D) -> non-canonical.
    const header = try hints.parseHeader(&[_]u8{ 0x78, 0x9D, 0x00 });
    try testing.expect(!header.canonical());

    var visited = std.AutoHashMap(u64, void).init(alloc);
    var rep = ui.Reporter.init(undefined, false, false, false);

    var available = [_]bool{false} ** profiles_mod.profiles.len;
    available[0] = true;

    var exe_paths: [profiles_mod.profiles.len][]const u8 = undefined;
    for (&exe_paths) |*e| e.* = "/dev/null";

    var ctx = Ctx{
        .gpa = alloc,
        .io = undefined,
        .compressed = &.{},
        .input_tmp_path = "",
        .uncompressed = &.{},
        .header = header,
        .first_block = null,
        .target_header = header.word(),
        .level0_ok = false,
        .paranoid = false,
        .available = &available,
        .exe_paths = &exe_paths,
        .visited = &visited,
        .rep = &rep,
    };

    const s3 = try buildStage3(&ctx, alloc);
    try testing.expect(s3.len > 0);
    var seen_wb = [_]bool{false} ** 16;
    for (s3) |c| seen_wb[c.window_bits] = true;
    for (8..16) |wb| try testing.expect(seen_wb[wb]);
}

test "collapseGroups minimizes representatives per parameter combination" {
    // Level >= 1, default strategy: one representative covers 1.2.3-1.3.1.
    {
        const groups = collapseGroups(6, 0);
        try testing.expectEqual(@as(usize, 1), groups.len);
        try testing.expectEqualStrings("zlib 1.2.3-1.4", groups[0].range);
    }
    // Z_HUFFMAN_ONLY / Z_RLE split off the 1.2.3 block states.
    {
        const groups = collapseGroups(6, 2);
        try testing.expectEqual(@as(usize, 2), groups.len);
        try testing.expectEqualStrings("zlib 1.2.4-1.4", groups[0].range);
        try testing.expectEqualStrings("zlib 1.2.3", groups[1].range);
    }
    // Level 0: three stored-block generations (1.2.3 and 1.2.4-1.2.8 share
    // the legacy layout).
    {
        const groups = collapseGroups(0, 0);
        try testing.expectEqual(@as(usize, 3), groups.len);
        try testing.expectEqualStrings("zlib 1.2.3-1.2.8", groups[0].range);
        try testing.expectEqualStrings("zlib 1.2.9", groups[1].range);
        try testing.expectEqualStrings("zlib 1.2.10-1.4", groups[2].range);
    }
    // Level 0 with huff/rle: 1.2.3 stays stored, 1.2.4+ dispatch huff/rle.
    {
        const groups = collapseGroups(0, 2);
        try testing.expectEqual(@as(usize, 4), groups.len);
    }
}

test "integrated engine reproduces its own default stream on the first attempt" {
    const input = "The quick brown fox jumps over the lazy dog. " ** 24;

    var c = try replicant.Compressor.init(testing.allocator);
    defer c.deinit();
    var reference: [replicant.Compressor.requiredOutputLen(input.len)]u8 = undefined;
    const n = try c.compress(.v1_3_1, 6, 8, 0, 15, input, &reference);
    const compressed = reference[0..n];

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var rep_buf: [4096]u8 = undefined;
    var rep_writer = std.Io.Writer.fixed(&rep_buf);
    var rep = ui.Reporter.init(&rep_writer, false, false, false);
    const header = try hints.parseHeader(compressed);
    const match = try findExactMatch(
        testing.allocator,
        threaded.io(),
        compressed,
        input,
        header,
        hints.firstBlockInfo(compressed),
        .{ .binaries_dir = "/nonexistent" },
        &rep,
    );
    const m = match orelse return error.NoMatch;
    try testing.expect(m.profile.impl_type == .integrated);
    try testing.expectEqual(Stage.hinted, m.stage);
    try testing.expectEqual(@as(usize, 1), m.attempts);
    try testing.expectEqualStrings("zlib 1.2.3-1.4", m.version_range);
}

test "integrated engine distinguishes zlib 1.2.3 on Z_HUFFMAN_ONLY" {
    // Deterministic pseudo-random input; at (level 1, memLevel 9, strategy 2)
    // the 1.2.3 and 1.2.4+ block states produce different bytes once the
    // fill_window/block-flush timings drift apart (verified against the real
    // zlib-1.2.3/zlib-1.2.8 binaries at this exact size).
    var prng: u32 = 0x12345678;
    var input_buf: [65536]u8 = undefined;
    for (&input_buf) |*b| {
        prng = prng *% 1664525 +% 1013904223;
        b.* = @truncate(prng >> 24);
    }
    const input = &input_buf;

    var c = try replicant.Compressor.init(testing.allocator);
    defer c.deinit();
    var reference: [replicant.Compressor.requiredOutputLen(input.len)]u8 = undefined;
    const n = try c.compress(.v1_2_3, 1, 9, 2, 15, input, &reference);
    const compressed = reference[0..n];

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var rep_buf: [4096]u8 = undefined;
    var rep_writer = std.Io.Writer.fixed(&rep_buf);
    var rep = ui.Reporter.init(&rep_writer, false, false, false);
    const header = try hints.parseHeader(compressed);
    const match = try findExactMatch(
        testing.allocator,
        threaded.io(),
        compressed,
        input,
        header,
        hints.firstBlockInfo(compressed),
        .{ .binaries_dir = "/nonexistent" },
        &rep,
    );
    const m = match orelse return error.NoMatch;
    try testing.expect(m.profile.impl_type == .integrated);
    try testing.expectEqualStrings("zlib 1.2.3", m.version_range);
    // Z_HUFFMAN_ONLY hides the level in the header (FLEVEL = 0 for every
    // level), so the search legitimately reports the highest level first.
    try testing.expectEqual(@as(i8, 9), m.level);
    try testing.expectEqual(@as(u8, 9), m.mem_level);
    try testing.expectEqual(@as(u8, 2), m.strategy);
}

test "no match on a stream the integrated engine cannot reproduce" {
    const input = "unmatched payload " ** 8;
    // A valid zlib header + arbitrary garbage payload: never reproduced.
    const compressed = [_]u8{ 0x78, 0x9c } ++ [_]u8{0xab} ** 40;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var rep_buf: [4096]u8 = undefined;
    var rep_writer = std.Io.Writer.fixed(&rep_buf);
    var rep = ui.Reporter.init(&rep_writer, false, false, false);
    const header = try hints.parseHeader(&compressed);
    const match = try findExactMatch(
        testing.allocator,
        threaded.io(),
        &compressed,
        input,
        header,
        hints.firstBlockInfo(&compressed),
        .{ .binaries_dir = "/nonexistent" },
        &rep,
    );
    try testing.expect(match == null);
}
