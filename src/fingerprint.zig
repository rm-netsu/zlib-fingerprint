//! Brute-force fingerprinting engine.
//!
//! Port of the original `index.ts`: iterates compressor candidates through
//! three search phases and compares each candidate's output byte-for-byte
//! against the original compressed stream.
//!
//! zlib candidates come in two flavors:
//!   * integrated (default) — compressed in-process by the built-in
//!     `deflate/` engine, which reproduces the bit-exact output of every
//!     historical zlib release 1.2.3 .. 1.3.1. The four output-equivalence
//!     classes are collapsed into the minimal set of representatives per
//!     parameter combination (see `collapseGroups`).
//!   * external (legacy, `--external-zlib`) — spawns the historical wrapper
//!     binaries, exactly like the original tool.
//!
//! Zopfli/libdeflate/miniz candidates always spawn external binaries.
//!
//! Phase 1: trust the zlib header metadata (levels 1-2, memLevel 8,
//!          strategies 0/1, windowBits 15).
//! Phase 2: full parameter matrix with the standard window (windowBits 15)
//!          for zlib-type profiles, plus Zopfli/libdeflate/miniz level sweeps.
//! Phase 3: alternative (reduced) window sizes (windowBits 14..8).

const std = @import("std");
const profiles_mod = @import("profiles.zig");
const deflate = @import("deflate/deflate.zig");

pub const Profile = profiles_mod.Profile;
pub const Params = profiles_mod.Params;

/// A successful fingerprint result.
pub const MatchResult = struct {
    tool_name: []const u8,
    binary_path: []const u8,
    params_summary: []const u8,
};

/// Search phase number, 1..3.
pub const PhaseInfo = struct {
    number: u8,
    title: []const u8,
};

/// One compressor invocation reported back to the UI.
pub const AttemptInfo = struct {
    /// "[Phase 1]" / "[Phase 2]" / "[Phase 3]" / "[Libdeflate]" / "[Miniz]"
    phase_tag: []const u8,
    profile_name: []const u8,
    /// Human-readable parameter description, same format as the original.
    description: []const u8,
    matched: bool,
    /// 1-based index of the attempt within the current profile block.
    index_in_block: usize,
    /// Total attempts planned for the current profile block (0 if unknown).
    block_total: usize,
    /// 1-based global attempt counter across the whole search.
    attempt_no: usize,
};

pub const Event = union(enum) {
    phase_start: PhaseInfo,
    phase_end: PhaseInfo,
    attempt: AttemptInfo,
};

/// Callback sink for search events.
pub const Notifier = struct {
    context: ?*anyopaque = null,
    notifyFn: *const fn (context: ?*anyopaque, event: Event) void = &ignore,
    enabled: bool = true,

    fn ignore(_: ?*anyopaque, _: Event) void {}

    pub fn notify(self: Notifier, event: Event) void {
        if (!self.enabled) return;
        self.notifyFn(self.context, event);
    }
};

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    /// Allocator for result strings; an arena is recommended since results
    /// outlive the search (but not the process).
    result_alloc: std.mem.Allocator,
    io: std.Io,
    notifier: Notifier = .{},
    /// Hard cap for captured child stdout — mirrors Node's `maxBuffer` of
    /// 100 MiB. Oversized output counts as a failed candidate.
    max_output: usize = 100 * 1024 * 1024,
    /// Mutable global attempt counter.
    attempts: usize = 0,

    /// Lazily-initialized integrated deflate engine (internal zlib mode).
    compressor: ?deflate.Compressor = null,
    /// Scratch buffer for one compressed candidate (sized once).
    output_buf: ?[]u8 = null,

    fn ensureCompressor(self: *Ctx, uncompressed_len: usize) bool {
        if (self.compressor == null) {
            self.compressor = deflate.Compressor.init(self.gpa) catch return false;
        }
        if (self.output_buf == null) {
            const size = deflate.Compressor.requiredOutputLen(uncompressed_len);
            self.output_buf = self.gpa.alloc(u8, size) catch return false;
        }
        return true;
    }

    fn releaseCompressor(self: *Ctx) void {
        if (self.compressor) |*c| c.deinit();
        self.compressor = null;
        if (self.output_buf) |b| self.gpa.free(b);
        self.output_buf = null;
    }
};

// ---------------------------------------------------------------------------
// Parameter matrices (same values and ordering as the original).
// ---------------------------------------------------------------------------

const all_levels = [_]i32{ 9, 8, 7, 6, 5, 4, 3, 2, 1 };
const all_mem_levels = [_]i32{ 8, 9, 7, 6, 5 };
const all_strategies = [_]i32{ 0, 1, 2, 3, 4 };

const phase1_levels = [_]i32{ 1, 2 };
const phase1_mem_levels = [_]i32{8};
const phase1_strategies = [_]i32{ 1, 0 };
const phase1_window_bits = [_]i32{15};

const zopfli_iterations = [_]i32{ 1, 2, 3, 5, 10, 15, 50, 100, 250, 500 };
const libdeflate_levels = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
const miniz_levels = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
const alternative_window_bits = [_]i32{ 14, 13, 12, 11, 10, 9, 8 };

const phase1_title = "Phase 1/3: trusted metadata (levels 1-2, memLevel 8, strategies 0/1, windowBits 15)";
const phase2_title = "Phase 2/3: full parameter matrix with the standard window (windowBits 15)";
const phase3_title = "Phase 3/3: alternative (reduced) window sizes (windowBits 14..8)";

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

/// Runs all three search phases over `profiles`; returns the first bit-exact
/// match or `null` when every candidate missed.
pub fn findExactMatch(
    ctx: *Ctx,
    original_compressed: []const u8,
    uncompressed: []const u8,
    profiles: []const Profile,
) ?MatchResult {
    defer ctx.releaseCompressor();
    if (runPhase1(ctx, original_compressed, uncompressed, profiles)) |m| return m;
    if (runPhase2(ctx, original_compressed, uncompressed, profiles)) |m| return m;
    if (runPhase3(ctx, original_compressed, uncompressed, profiles)) |m| return m;
    return null;
}

/// True when the binary exists and can be spawned. Mirrors the original
/// `fs.existsSync` guard, so missing binaries are skipped silently.
pub fn binaryExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// Guard for the per-profile loop: zlib candidates run either integrated or
/// through an existing binary; everything else is skipped.
inline fn profileRunnable(io: std.Io, profile: *const Profile) bool {
    if (profile.kind != .zlib) return false;
    if (profile.integrated) return true;
    return binaryExists(io, profile.binary_path);
}

/// Guard for phases that also visit non-zlib profiles.
inline fn profileRunnableAnyKind(io: std.Io, profile: *const Profile) bool {
    if (profile.integrated) return true;
    return binaryExists(io, profile.binary_path);
}

// ---------------------------------------------------------------------------
// Integrated-zlib search-space collapse.
// ---------------------------------------------------------------------------

/// One output-equivalence-class representative of the integrated engine.
const CollapseGroup = struct {
    variant: deflate.Variant,
    /// Version range this representative reproduces bit-exactly for the
    /// current parameter combination.
    range: []const u8,
};

/// Minimal per-combination set of representatives covering all 13 historical
/// releases.
///
/// The engine's four output-equivalence classes are {1.2.3}, {1.2.4-1.2.8},
/// {1.2.9} and {1.2.10-1.3.1} (differing only in level-0 stored-block
/// handling, which the search never visits — levels 1..9). At level >= 1 the
/// only boundary that changes bytes is strategy 2/3 (Z_HUFFMAN_ONLY/Z_RLE):
/// zlib 1.2.3 dispatches inside deflate_fast/deflate_slow, later releases
/// use the dedicated deflate_huff/deflate_rle block states. For every other
/// strategy the whole 1.2.3..1.3.1 range is byte-identical, so one
/// representative per combination is enough.
fn collapseGroups(strategy: i32) []const CollapseGroup {
    return switch (strategy) {
        2, 3 => &[_]CollapseGroup{
            .{ .variant = .z1_2_4_to_1_2_8, .range = "zlib 1.2.4-1.3.1" },
            .{ .variant = .z1_2_3, .range = "zlib 1.2.3" },
        },
        else => &[_]CollapseGroup{
            .{ .variant = .z1_2_4_to_1_2_8, .range = "zlib 1.2.3-1.3.1" },
        },
    };
}

// ---------------------------------------------------------------------------
// Phase 1.
// ---------------------------------------------------------------------------

fn runPhase1(
    ctx: *Ctx,
    original_compressed: []const u8,
    uncompressed: []const u8,
    profiles: []const Profile,
) ?MatchResult {
    ctx.notifier.notify(.{ .phase_start = .{ .number = 1, .title = phase1_title } });
    defer ctx.notifier.notify(.{ .phase_end = .{ .number = 1, .title = phase1_title } });

    const block_total = phase1_levels.len * phase1_mem_levels.len *
        phase1_strategies.len * phase1_window_bits.len;

    for (profiles) |*profile| {
        if (!profileRunnable(ctx.io, profile)) continue;

        var index: usize = 0;
        for (phase1_levels) |level| {
            for (phase1_mem_levels) |mem_level| {
                for (phase1_strategies) |strategy| {
                    for (phase1_window_bits) |window_bits| {
                        index += 1;
                        const params: Params = .{
                            .level = level,
                            .mem_level = mem_level,
                            .strategy = strategy,
                            .window_bits = window_bits,
                        };
                        if (tryZlibCandidate(ctx, profile, params, original_compressed, uncompressed, "[Phase 1]", index, block_total)) {
                            return zlibSummary(ctx, profile, params, null, 1);
                        }
                    }
                }
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Phase 2.
// ---------------------------------------------------------------------------

fn runPhase2(
    ctx: *Ctx,
    original_compressed: []const u8,
    uncompressed: []const u8,
    profiles: []const Profile,
) ?MatchResult {
    ctx.notifier.notify(.{ .phase_start = .{ .number = 2, .title = phase2_title } });
    defer ctx.notifier.notify(.{ .phase_end = .{ .number = 2, .title = phase2_title } });

    for (profiles) |*profile| {
        if (!profileRunnableAnyKind(ctx.io, profile)) continue;

        switch (profile.kind) {
            .zlib => {
                const skipped = phase1_levels.len * phase1_mem_levels.len * phase1_strategies.len;
                const block_total = all_levels.len * all_mem_levels.len * all_strategies.len - skipped;

                var index: usize = 0;
                for (all_levels) |level| {
                    for (all_mem_levels) |mem_level| {
                        for (all_strategies) |strategy| {
                            // Skip combinations already tested in Phase 1.
                            if (contains(i32, &phase1_levels, level) and
                                contains(i32, &phase1_mem_levels, mem_level) and
                                contains(i32, &phase1_strategies, strategy))
                            {
                                continue;
                            }
                            index += 1;
                            const params: Params = .{
                                .level = level,
                                .mem_level = mem_level,
                                .strategy = strategy,
                                .window_bits = 15,
                            };
                            if (tryZlibCandidate(ctx, profile, params, original_compressed, uncompressed, "[Phase 2]", index, block_total)) {
                                return zlibSummary(ctx, profile, params, null, 2);
                            }
                        }
                    }
                }
            },
            .zopfli => {
                var index: usize = 0;
                for (zopfli_iterations) |iteration| {
                    index += 1;
                    const params: Params = .{ .iteration = iteration };
                    if (tryGenericCandidate(ctx, profile, params, original_compressed, uncompressed, "[Phase 2]", index, zopfli_iterations.len)) {
                        return iterationsSummary(ctx, profile, iteration);
                    }
                }
            },
            .libdeflate => {
                var index: usize = 0;
                for (libdeflate_levels) |level| {
                    index += 1;
                    const params: Params = .{ .level = level };
                    if (tryGenericCandidate(ctx, profile, params, original_compressed, uncompressed, "[Libdeflate]", index, libdeflate_levels.len)) {
                        return levelSummary(ctx, profile, level);
                    }
                }
            },
            .miniz => {
                var index: usize = 0;
                for (miniz_levels) |level| {
                    index += 1;
                    const params: Params = .{ .level = level };
                    if (tryGenericCandidate(ctx, profile, params, original_compressed, uncompressed, "[Miniz]", index, miniz_levels.len)) {
                        return levelSummary(ctx, profile, level);
                    }
                }
            },
            // Parity with the original engine: advdef profiles are listed but
            // never dispatched by the search.
            .advdef => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Phase 3.
// ---------------------------------------------------------------------------

fn runPhase3(
    ctx: *Ctx,
    original_compressed: []const u8,
    uncompressed: []const u8,
    profiles: []const Profile,
) ?MatchResult {
    ctx.notifier.notify(.{ .phase_start = .{ .number = 3, .title = phase3_title } });
    defer ctx.notifier.notify(.{ .phase_end = .{ .number = 3, .title = phase3_title } });

    const block_total = alternative_window_bits.len * all_levels.len *
        all_mem_levels.len * all_strategies.len;

    for (profiles) |*profile| {
        if (!profileRunnable(ctx.io, profile)) continue;

        var index: usize = 0;
        for (alternative_window_bits) |window_bits| {
            for (all_levels) |level| {
                for (all_mem_levels) |mem_level| {
                    for (all_strategies) |strategy| {
                        index += 1;
                        const params: Params = .{
                            .level = level,
                            .mem_level = mem_level,
                            .strategy = strategy,
                            .window_bits = window_bits,
                        };
                        if (tryZlibCandidate(ctx, profile, params, original_compressed, uncompressed, "[Phase 3]", index, block_total)) {
                            return zlibSummary(ctx, profile, params, null, 3);
                        }
                    }
                }
            }
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Candidate execution.
// ---------------------------------------------------------------------------

/// Runs one zlib candidate (level/memLevel/strategy/windowBits) and reports
/// the attempt(s) to the notifier.
///
/// Integrated profiles expand every parameter combination into the minimal
/// set of output-equivalence-class representatives (1 or 2 attempts, see
/// `collapseGroups`); external profiles spawn their binary once.
fn tryZlibCandidate(
    ctx: *Ctx,
    profile: *const Profile,
    params: Params,
    original_compressed: []const u8,
    uncompressed: []const u8,
    phase_tag: []const u8,
    index_in_block: usize,
    block_total: usize,
) bool {
    if (profile.integrated) {
        if (!ctx.ensureCompressor(uncompressed.len)) return false;

        for (collapseGroups(params.strategy)) |group| {
            ctx.attempts += 1;
            const matched = compressIntegrated(
                ctx,
                group.variant,
                params,
                original_compressed,
                uncompressed,
            );

            var desc_buf: [256]u8 = undefined;
            const desc = std.fmt.bufPrint(
                &desc_buf,
                "{s} {s} | lvl={d}, mem={d}, strat={d}, wBits={d} [{s}]",
                .{ phase_tag, profile.name, params.level, params.mem_level, params.strategy, params.window_bits, group.range },
            ) catch phase_tag;

            ctx.notifier.notify(.{ .attempt = .{
                .phase_tag = phase_tag,
                .profile_name = profile.name,
                .description = desc,
                .matched = matched,
                .index_in_block = index_in_block,
                .block_total = block_total,
                .attempt_no = ctx.attempts,
            } });
            if (matched) {
                last_group_range = refineRange(ctx, group, params, original_compressed, uncompressed);
                return true;
            }
        }
        return false;
    }

    ctx.attempts += 1;
    const matched = runCandidate(ctx, profile, params, original_compressed, uncompressed);

    var desc_buf: [192]u8 = undefined;
    const desc = std.fmt.bufPrint(
        &desc_buf,
        "{s} {s} | lvl={d}, mem={d}, strat={d}, wBits={d}",
        .{ phase_tag, profile.name, params.level, params.mem_level, params.strategy, params.window_bits },
    ) catch phase_tag;

    ctx.notifier.notify(.{ .attempt = .{
        .phase_tag = phase_tag,
        .profile_name = profile.name,
        .description = desc,
        .matched = matched,
        .index_in_block = index_in_block,
        .block_total = block_total,
        .attempt_no = ctx.attempts,
    } });
    return matched;
}

/// Range name of the group that produced the last internal match (read by
/// `zlibSummary` right after `tryZlibCandidate` returns true).
var last_group_range: []const u8 = "";

/// Widens the reported version range when the class representative's match
/// is also reproduced by the next class.
///
/// At strategies 2/3 the 1.2.3 and 1.2.4+ block states produce identical
/// bytes on many (level, memLevel, input) combinations — the divergence only
/// appears when the two fill_window/block-flush timings drift apart. When
/// the modern representative matched, check the 1.2.3 representative once
/// (silent, not counted as a search attempt) and widen the range if it
/// reproduces the stream as well.
fn refineRange(
    ctx: *Ctx,
    group: CollapseGroup,
    params: Params,
    original_compressed: []const u8,
    uncompressed: []const u8,
) []const u8 {
    if (group.variant != .z1_2_4_to_1_2_8) return group.range;
    if (params.strategy != 2 and params.strategy != 3) return group.range;
    if (compressIntegrated(ctx, .z1_2_3, params, original_compressed, uncompressed)) {
        return "zlib 1.2.3-1.3.1";
    }
    return group.range;
}

/// Compresses `uncompressed` in-process with the integrated deflate engine
/// and compares the result byte-for-byte against `original_compressed`.
///
/// Uses the early-abort reference comparison: a mismatch aborts at the first
/// divergent output chunk, which keeps the brute-force matrix cheap.
fn compressIntegrated(
    ctx: *Ctx,
    variant: deflate.Variant,
    params: Params,
    original_compressed: []const u8,
    uncompressed: []const u8,
) bool {
    const compressor = &ctx.compressor.?;
    const out = ctx.output_buf.?;
    const level: u32 = @intCast(params.level);
    const mem_level: u32 = @intCast(params.mem_level);
    const strategy: u32 = @intCast(params.strategy);
    const window_bits: u32 = @intCast(params.window_bits);

    _ = compressor.compressExpect(
        variant.toVersion(),
        level,
        mem_level,
        strategy,
        window_bits,
        uncompressed,
        out,
        original_compressed,
    ) catch return false;
    return true;
}

/// Runs one non-zlib candidate (zopfli / libdeflate / miniz) and reports it.
fn tryGenericCandidate(
    ctx: *Ctx,
    profile: *const Profile,
    params: Params,
    original_compressed: []const u8,
    uncompressed: []const u8,
    phase_tag: []const u8,
    index_in_block: usize,
    block_total: usize,
) bool {
    ctx.attempts += 1;
    const matched = runCandidate(ctx, profile, params, original_compressed, uncompressed);

    var desc_buf: [192]u8 = undefined;
    const desc = switch (profile.kind) {
        .zopfli => std.fmt.bufPrint(
            &desc_buf,
            "{s} {s} | iterations={d}",
            .{ phase_tag, profile.name, params.iteration },
        ) catch phase_tag,
        .libdeflate, .miniz => std.fmt.bufPrint(
            &desc_buf,
            "{s} {s} | level={d}",
            .{ phase_tag, profile.name, params.level },
        ) catch phase_tag,
        else => phase_tag,
    };

    ctx.notifier.notify(.{ .attempt = .{
        .phase_tag = phase_tag,
        .profile_name = profile.name,
        .description = desc,
        .matched = matched,
        .index_in_block = index_in_block,
        .block_total = block_total,
        .attempt_no = ctx.attempts,
    } });
    return matched;
}

/// Spawns the external compressor with `uncompressed` on stdin, captures
/// stdout, and compares it byte-for-byte against `original_compressed`.
///
/// Corresponds to Node's `cp.spawnSync(binaryPath, args, { input, maxBuffer })`
/// from the original `tryRunZlib`/`tryRunZopfli` helpers.
fn runCandidate(
    ctx: *Ctx,
    profile: *const Profile,
    params: Params,
    original_compressed: []const u8,
    uncompressed: []const u8,
) bool {
    var scratch: profiles_mod.ArgScratch = .{};
    const argv = profile.getArgs(params, &scratch);

    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;

    // Feed stdin from a worker thread so the parent can drain stdout at the
    // same time — same deadlock avoidance Node performs internally.
    var feeder: Feeder = .{ .io = ctx.io, .file = child.stdin.?, .data = uncompressed };
    const feeder_thread = std.Thread.spawn(.{}, Feeder.run, .{&feeder}) catch {
        child.stdin.?.close(ctx.io);
        child.stdin = null;
        child.kill(ctx.io);
        return false;
    };

    // Drain stdout to EOF while the feeder writes.
    var read_buf: [16 * 1024]u8 = undefined;
    var fr = child.stdout.?.readerStreaming(ctx.io, &read_buf);
    var output: []u8 = &.{};
    var read_ok = true;
    if (fr.interface.allocRemaining(ctx.gpa, .limited(ctx.max_output))) |data| {
        output = data;
    } else |_| {
        read_ok = false;
    }

    feeder_thread.join();
    child.stdin = null; // Feeder already closed the write end.

    const term: std.process.Child.Term = child.wait(ctx.io) catch {
        if (output.len > 0) ctx.gpa.free(output);
        return false;
    };
    defer if (output.len > 0) ctx.gpa.free(output);

    // Same success rule as the original: exit status 0 and byte-equal output.
    if (!read_ok) return false;
    if (term != .exited or term.exited != 0) return false;
    return std.mem.eql(u8, output, original_compressed);
}

/// Writes `data` into the child's stdin pipe, then closes it so the child
/// observes EOF. Failures (e.g. the child exited early) are ignored —
/// the original tool treats every spawn hiccup as a plain mismatch.
const Feeder = struct {
    io: std.Io,
    file: std.Io.File,
    data: []const u8,

    fn run(self: *Feeder) void {
        var buf: [16 * 1024]u8 = undefined;
        var fw = self.file.writerStreaming(self.io, &buf);
        fw.interface.writeAll(self.data) catch {};
        fw.interface.flush() catch {};
        self.file.close(self.io);
    }
};

// ---------------------------------------------------------------------------
// Result summaries (same wording as the original).
// ---------------------------------------------------------------------------

fn zlibSummary(ctx: *Ctx, profile: *const Profile, params: Params, version_range: ?[]const u8, phase: u8) MatchResult {
    const range = version_range orelse (if (profile.integrated) last_group_range else null);
    const summary = if (range) |r|
        std.fmt.allocPrint(
            ctx.result_alloc,
            "level={d}, memLevel={d}, strategy={d}, windowBits={d}, {s} (Phase {d})",
            .{ params.level, params.mem_level, params.strategy, params.window_bits, r, phase },
        ) catch "zlib candidate matched"
    else
        std.fmt.allocPrint(
            ctx.result_alloc,
            "level={d}, memLevel={d}, strategy={d}, windowBits={d} (Phase {d})",
            .{ params.level, params.mem_level, params.strategy, params.window_bits, phase },
        ) catch "zlib candidate matched";
    return .{
        .tool_name = profile.name,
        .binary_path = profile.binary_path,
        .params_summary = summary,
    };
}

fn iterationsSummary(ctx: *Ctx, profile: *const Profile, iteration: i32) MatchResult {
    const summary = std.fmt.allocPrint(
        ctx.result_alloc,
        "iterations={d} (Phase 2)",
        .{iteration},
    ) catch "zopfli candidate matched";
    return .{
        .tool_name = profile.name,
        .binary_path = profile.binary_path,
        .params_summary = summary,
    };
}

fn levelSummary(ctx: *Ctx, profile: *const Profile, level: i32) MatchResult {
    const summary = std.fmt.allocPrint(
        ctx.result_alloc,
        "level={d}",
        .{level},
    ) catch "candidate matched";
    return .{
        .tool_name = profile.name,
        .binary_path = profile.binary_path,
        .params_summary = summary,
    };
}

// ---------------------------------------------------------------------------
// Small helpers.
// ---------------------------------------------------------------------------

fn contains(comptime T: type, haystack: []const T, needle: T) bool {
    for (haystack) |v| {
        if (v == needle) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "integrated engine finds its own level-6 stream in phase 2" {
    const testing = std.testing;

    const input = "The quick brown fox jumps over the lazy dog. " ** 24;

    var c = try deflate.Compressor.init(testing.allocator);
    defer c.deinit();
    var reference: [deflate.Compressor.requiredOutputLen(input.len)]u8 = undefined;
    const n = try c.compress(.v1_3_1, 6, 8, 0, 15, input, &reference);
    const compressed = reference[0..n];

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // Internal mode: the integrated profile needs no binaries on disk.
    const profiles = try profiles_mod.getProfiles(arena_state.allocator(), "/nonexistent", false);
    var ctx: Ctx = .{
        .gpa = testing.allocator,
        .result_alloc = arena_state.allocator(),
        .io = threaded.io(),
    };
    const match = findExactMatch(&ctx, compressed, input, profiles) orelse return error.NoMatch;
    try testing.expectEqualStrings("zlib (integrated)", match.tool_name);
    try testing.expect(std.mem.indexOf(u8, match.params_summary, "level=6, memLevel=8, strategy=0, windowBits=15") != null);
    try testing.expect(std.mem.indexOf(u8, match.params_summary, "zlib 1.2.3-1.3.1") != null);
}

test "integrated engine distinguishes 1.2.3 on Z_HUFFMAN_ONLY" {
    const testing = std.testing;

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

    var c = try deflate.Compressor.init(testing.allocator);
    defer c.deinit();
    var out_a: [deflate.Compressor.requiredOutputLen(input.len)]u8 = undefined;
    var out_b: [deflate.Compressor.requiredOutputLen(input.len)]u8 = undefined;
    const n_a = try c.compress(.v1_2_3, 1, 9, 2, 15, input, &out_a);
    const n_b = try c.compress(.v1_2_8, 1, 9, 2, 15, input, &out_b);
    try testing.expect(n_a != n_b or !std.mem.eql(u8, out_a[0..n_a], out_b[0..n_b]));
    const compressed = out_a[0..n_a];

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const profiles = try profiles_mod.getProfiles(arena_state.allocator(), "/nonexistent", false);
    var ctx: Ctx = .{
        .gpa = testing.allocator,
        .result_alloc = arena_state.allocator(),
        .io = threaded.io(),
    };
    const match = findExactMatch(&ctx, compressed, input, profiles) orelse return error.NoMatch;
    try testing.expectEqualStrings("zlib (integrated)", match.tool_name);
    // Z_HUFFMAN_ONLY hides the level in the header (FLEVEL = 0 for every
    // level), so the search legitimately reports the highest level first.
    try testing.expect(std.mem.indexOf(u8, match.params_summary, "memLevel=9, strategy=2") != null);
    try testing.expect(std.mem.indexOf(u8, match.params_summary, "zlib 1.2.3") != null);
}

test "no match on a stream the engine cannot reproduce" {
    const testing = std.testing;

    const input = "unmatched payload " ** 8;
    // A zlib header + arbitrary garbage payload: never reproduced exactly.
    const compressed = [_]u8{ 0x78, 0x9c } ++ [_]u8{0xab} ** 40;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const profiles = try profiles_mod.getProfiles(arena_state.allocator(), "/nonexistent", false);
    var ctx: Ctx = .{
        .gpa = testing.allocator,
        .result_alloc = arena_state.allocator(),
        .io = threaded.io(),
    };
    try testing.expect(findExactMatch(&ctx, &compressed, input, profiles) == null);
}
