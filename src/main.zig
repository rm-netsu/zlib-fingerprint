//! zlib-fingerprint — identify the compressor implementation and parameters
//! that produced a zlib (RFC 1950) stream, by bit-exact brute force.
//!
//! The search order is driven by the stream's own metadata (CINFO, FLEVEL,
//! FDICT, FCHECK, first DEFLATE block type), which keeps convergence fast:
//! a default-level stream matches on the very first candidate.

const std = @import("std");
const hints = @import("hints.zig");
const profiles_mod = @import("profiles.zig");
const fingerprint = @import("fingerprint.zig");
const ui = @import("ui.zig");

const usage_text =
    \\Usage: zlib-fingerprint [options] <compressed_file>
    \\
    \\Identifies the compressor implementation and parameter set
    \\(level, memLevel, strategy, windowBits, iterations) that produced a
    \\zlib (RFC 1950) stream, by brute-forcing known implementations until
    \\the output matches the input bit-exactly.
    \\
    \\The enumeration order is driven by the stream's own metadata:
    \\CINFO (windowBits), FLEVEL (level/strategy class), FDICT and the
    \\first DEFLATE block type.
    \\
    \\By default stock zlib candidates are re-compressed in-process by the
    \\integrated engine, which reproduces zlib 1.2.3-1.3.1 bit-exactly.
    \\
    \\Options:
    \\  -v, --verbose    print every candidate attempt
    \\      --no-color   disable ANSI colors
    \\      --paranoid   force the windowBits sweep even for canonical headers
    \\      --external-zlib  spawn per-version zlib binaries instead of the
    \\                       integrated engine
    \\      --binaries <dir>  directory with compressor binaries
    \\                       (default: ./binaries)
    \\  -h, --help       show this help
    \\
    \\Exit codes: 0 = match found, 1 = no match / failure, 2 = usage error.
    \\
;

const Options = struct {
    verbose: bool = false,
    no_color: bool = false,
    paranoid: bool = false,
    external_zlib: bool = false,
    binaries_dir: ?[]const u8 = null,
    file: ?[]const u8 = null,
    help: bool = false,
};

fn parseArgs(init: std.process.Init, arena: std.mem.Allocator) !Options {
    var opts = Options{};
    // initAllocator is the cross-platform constructor (Windows needs heap
    // buffers for WTF-16 -> WTF-8 conversion); the arena owns them, and every
    // argument is duped into the arena because the iterator may reallocate
    // its internal buffer while advancing.
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    _ = it.next(); // skip argv[0]
    while (it.next()) |raw| {
        const a: []const u8 = try arena.dupe(u8, raw);
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--no-color")) {
            opts.no_color = true;
        } else if (std.mem.eql(u8, a, "--paranoid")) {
            opts.paranoid = true;
        } else if (std.mem.eql(u8, a, "--external-zlib")) {
            opts.external_zlib = true;
        } else if (std.mem.eql(u8, a, "--binaries")) {
            const next = it.next() orelse return error.Usage;
            opts.binaries_dir = next;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.help = true;
        } else if (a.len > 1 and a[0] == '-') {
            return error.Usage;
        } else {
            if (opts.file != null) return error.Usage;
            opts.file = a;
        }
    }
    return opts;
}

fn printAnalysis(rep: *ui.Reporter, h: hints.Header, first_block: ?hints.BlockInfo, compressed_len: usize, uncompressed_len: usize) void {
    rep.line("", .{});
    rep.line("=== Zlib Header Metadata (RFC 1950) ===", .{});
    rep.line("- Header Valid (FCHECK) : {s}", .{if (h.fcheck_ok) "Yes (OK)" else "No (corrupt or custom writer)"});
    rep.line("- Compression Method    : {d}{s}", .{ h.cm, if (h.cm == 8) " (deflate)" else " (unknown!)" });
    rep.line("- Window Size           : {d} bytes (windowBits = {d})", .{ @as(usize, 1) << @intCast(h.window_bits), h.window_bits });
    if (h.fdict) {
        rep.line("- Preset Dictionary     : Yes (DICTID = {x:0>8})", .{h.dict_id orelse 0});
    } else {
        rep.line("- Preset Dictionary     : None", .{});
    }
    rep.line("- Compression Level Hint: {s} (FLEVEL = {d})", .{ h.flevelName(), h.flevel });
    rep.line("- Header Class          : {s}", .{if (h.canonical()) "canonical (produced by a stock zlib-family implementation)" else "non-canonical"});
    if (first_block) |fb| {
        const names = [_][]const u8{ "Stored (uncompressed)", "Fixed Huffman", "Dynamic Huffman", "Reserved (invalid)" };
        rep.line("- First DEFLATE Block   : BFINAL={d}, BTYPE={d} ({s})", .{ fb.bfinal, fb.btype, names[fb.btype] });
    }
    rep.line("- Sizes                 : {d} -> {d} bytes", .{ compressed_len, uncompressed_len });
    rep.line("=======================================", .{});
}

fn printSearchPlan(rep: *ui.Reporter, h: hints.Header, fb: ?hints.BlockInfo, level0_ok: bool) void {
    rep.line("", .{});
    rep.line("Metadata-driven search plan:", .{});
    switch (h.flevel) {
        0 => rep.line("- FLEVEL=0  -> probing level 1 (default/filtered) and huffman-only/rle/fixed strategies first", .{}),
        1 => rep.line("- FLEVEL=1  -> probing levels 5, 4, 3, 2 first", .{}),
        2 => rep.line("- FLEVEL=2  -> probing level 6 (default) first", .{}),
        else => rep.line("- FLEVEL=3  -> probing levels 9, 8, 7 first", .{}),
    }
    rep.line("- windowBits fixed to CINFO+8 = {d} while the header stays trusted", .{h.window_bits});
    if (fb) |b| {
        if (b.btype == 0 and level0_ok) {
            rep.line("- stored first block -> level 0 probe scheduled at the front", .{});
        }
    }
    if (!h.canonical()) {
        rep.line("- non-canonical header -> windowBits sweep enabled for stage 3", .{});
    }
    rep.line("", .{});
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // Command line strings live for the whole run; an arena keeps the
    // cross-platform args iterator allocations out of the leak report.
    var args_arena = std.heap.ArenaAllocator.init(gpa);
    defer args_arena.deinit();

    const opts = parseArgs(init, args_arena.allocator()) catch {
        std.debug.print("zlib-fingerprint: invalid arguments\n{s}", .{usage_text});
        return 2;
    };
    if (opts.help) {
        std.debug.print("{s}", .{usage_text});
        return 0;
    }
    const file_path = opts.file orelse {
        std.debug.print("{s}", .{usage_text});
        return 2;
    };

    var stdout_buf: [1 << 15]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const tty = std.Io.File.stdout().isTty(io) catch false;
    const color = blk: {
        if (opts.no_color) break :blk false;
        if (init.environ_map.get("NO_COLOR") != null) break :blk false;
        if (init.environ_map.get("CLICOLOR_FORCE")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) break :blk true;
        }
        break :blk tty;
    };

    var rep = ui.Reporter.init(stdout, color, tty, opts.verbose);

    // ---- Read the stream --------------------------------------------------
    const compressed = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 31)) catch |err| {
        rep.line("error: cannot read '{s}': {s}", .{ file_path, @errorName(err) });
        return 1;
    };
    defer gpa.free(compressed);
    if (compressed.len < 3) {
        rep.line("error: file is too short to be a zlib stream", .{});
        return 1;
    }

    const base = std.Io.Dir.path.basename(file_path);
    rep.line("Analyzing zlib stream: {s} ({d} bytes)", .{ base, compressed.len });

    // ---- Header analysis --------------------------------------------------
    const header = hints.parseHeader(compressed) catch |err| {
        rep.line("error: cannot parse zlib header: {s}", .{@errorName(err)});
        return 1;
    };
    const first_block = hints.firstBlockInfo(compressed);

    if (header.cm != 8) {
        rep.line("error: not a deflate stream (CM={d}) - nothing to fingerprint", .{header.cm});
        return 1;
    }
    if (header.fdict) {
        rep.line("error: stream requires a preset dictionary (DICTID={x:0>8}); decompression and", .{header.dict_id orelse 0});
        rep.line("       bit-exact reproduction are impossible without that exact dictionary.", .{});
        return 1;
    }

    // ---- Inflate ----------------------------------------------------------
    rep.line("Decompressing stream to extract the uncompressed payload...", .{});
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var in_reader = std.Io.Reader.fixed(compressed);
    var decomp: std.compress.flate.Decompress = .init(&in_reader, .zlib, &window);
    var uncompressed: std.ArrayList(u8) = .empty;
    defer uncompressed.deinit(gpa);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch |err| {
            rep.line("error: inflate failed: {s} (corrupt or unsupported stream)", .{@errorName(err)});
            return 1;
        };
        if (n == 0) break;
        uncompressed.appendSlice(gpa, chunk[0..n]) catch return 1;
    }
    rep.line("Successfully unpacked: {d} bytes of raw data.", .{uncompressed.items.len});

    printAnalysis(&rep, header, first_block, compressed.len, uncompressed.items.len);
    printSearchPlan(&rep, header, first_block, fingerprint.level0Possible(compressed.len, uncompressed.items.len));

    // ---- Search -----------------------------------------------------------
    const binaries_dir = opts.binaries_dir orelse "binaries";
    const available_count = fingerprint.countAvailable(io, binaries_dir, opts.external_zlib);
    if (opts.external_zlib) {
        rep.line("Mode: external binaries only ({d}/{d} available, integrated engine disabled)", .{
            available_count, profiles_mod.profiles.len - 1,
        });
    } else {
        rep.line("Mode: integrated zlib 1.2.3-1.3.1 engine + external alternatives ({d}/{d} available)", .{
            available_count, profiles_mod.profiles.len,
        });
    }
    rep.line("", .{});

    const match = fingerprint.findExactMatch(
        gpa,
        io,
        compressed,
        uncompressed.items,
        header,
        first_block,
        .{ .binaries_dir = binaries_dir, .paranoid = opts.paranoid, .external_zlib = opts.external_zlib },
        &rep,
    ) catch |err| blk: {
        rep.line("search error: {s}", .{@errorName(err)});
        break :blk null;
    };

    if (match) |m| {
        rep.line("", .{});
        rep.line("[SUCCESS] Bit-exact match found!", .{});
        rep.line("- Implementation: {s}", .{m.profile.name});
        rep.line("- Stage         : {s}", .{m.stage.label()});
        switch (m.profile.impl_type) {
            .integrated, .zlib_family => rep.line("- Parameters    : level={d}, memLevel={d}, strategy={s}, windowBits={d}", .{
                m.level, m.mem_level, profiles_mod.STRATEGY_NAMES[@min(m.strategy, 4)], m.window_bits,
            }),
            .zopfli => rep.line("- Parameters    : iterations={d}", .{m.iterations}),
            .libdeflate, .miniz => rep.line("- Parameters    : level={d}", .{m.level}),
            .advdef => rep.line("- Parameters    : level=-{d}", .{m.level}),
        }
        if (m.version_range.len > 0) {
            rep.line("- Versions      : {s} (integrated engine)", .{m.version_range});
        }
        rep.line("- Convergence   : {d} attempt{s}, {d} ms", .{
            m.attempts, if (m.attempts == 1) "" else "s", m.elapsed_ms,
        });
        return 0;
    }

    rep.line("", .{});
    rep.line("[RESULT] No bit-exact match was found by any available implementation.", .{});
    return 1;
}

test {
    _ = @import("hints.zig");
    _ = @import("profiles.zig");
    _ = @import("fingerprint.zig");
    _ = @import("ui.zig");
    _ = @import("deflate/deflate.zig");
    std.testing.refAllDecls(@This());
}
