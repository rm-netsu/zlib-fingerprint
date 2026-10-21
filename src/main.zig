//! zlib-fingerprint — CLI entry point.
//!
//! Zig 0.16 port of the original TypeScript tool. Analyzes a zlib stream
//! (RFC 1950), inflates it, then brute-forces external compressor binaries
//! (zlib, zlib-ng, Zopfli, libdeflate, miniz, ...) to find the exact
//! implementation and parameters that reproduce the stream bit-for-bit.

const std = @import("std");
const fingerprint = @import("fingerprint.zig");
const profiles_mod = @import("profiles.zig");
const ui_mod = @import("ui.zig");

const Color = ui_mod.Color;
const Ui = ui_mod.Ui;

// ---------------------------------------------------------------------------
// zlib stream analysis (port of main.ts helpers).
// ---------------------------------------------------------------------------

const ZlibHeaderInfo = struct {
    compression_method: u8,
    window_size: u32,
    window_bits: u8,
    header_valid: bool,
    has_dictionary: bool,
    dictionary_id: ?u32,
    flevel_hint: u8,
    flevel_description: []const u8,
};

const flevel_descriptions = [_][]const u8{
    "Fastest algorithm",
    "Fast algorithm",
    "Default algorithm",
    "Maximum compression",
};

/// Detailed parse of the zlib header (RFC 1950).
fn analyzeZlibStream(buffer: []const u8) error{TooShort}!ZlibHeaderInfo {
    if (buffer.len < 2) return error.TooShort;

    const cmf = buffer[0];
    const flg = buffer[1];

    const header_valid = (@as(u32, cmf) * 256 + @as(u32, flg)) % 31 == 0;
    const compression_method = cmf & 0x0f;
    const cinfo = (cmf >> 4) & 0x0f;

    // zlib window size (256..32768 bytes); windowBits = cinfo + 8.
    const window_bits = cinfo + 8;
    const window_size = @as(u32, 1) << @intCast(window_bits);

    const has_dictionary = (flg & 0x20) != 0;
    const flevel_hint = (flg >> 6) & 0x03;

    var dictionary_id: ?u32 = null;
    if (has_dictionary and buffer.len >= 6) {
        dictionary_id = std.mem.readInt(u32, buffer[2..6], .big);
    }

    return .{
        .compression_method = compression_method,
        .window_size = window_size,
        .window_bits = window_bits,
        .header_valid = header_valid,
        .has_dictionary = has_dictionary,
        .dictionary_id = dictionary_id,
        .flevel_hint = flevel_hint,
        .flevel_description = flevel_descriptions[flevel_hint],
    };
}

const btype_names = [_][]const u8{
    "Stored (uncompressed)",
    "Fixed Huffman",
    "Dynamic Huffman",
    "Reserved (invalid)",
};

/// Quick scan of the first DEFLATE block to characterize stream structure.
fn printDeflateBlocks(ui: *Ui, buffer: []const u8) void {
    ui.print("\n", .{});
    ui.cprint(.bold, "--- Deflate Stream Structure (First blocks scan) ---\n", .{});
    if (buffer.len > 2) {
        const first_byte = buffer[2];
        const bfinal = first_byte & 0x01;
        const btype = (first_byte >> 1) & 0x03;
        ui.print("- First Block BFINAL : {d}\n", .{bfinal});
        ui.print("- First Block BTYPE  : {d} ({s})\n", .{ btype, btype_names[btype] });
    }
    ui.print("--------------------------------------------------\n\n", .{});
}

fn printZlibHeaderInfo(ui: *Ui, info: ZlibHeaderInfo) void {
    ui.print("\n", .{});
    ui.cprint(.bold, "=== Zlib Header Metadata (RFC 1950) ===\n", .{});
    ui.print("- Header Valid (FCHECK) : {s}\n", .{if (info.header_valid) "Yes (OK)" else "No (Corrupt or custom)"});
    ui.print("- Compression Method    : {d}\n", .{info.compression_method});
    ui.print("- Window Size           : {d} bytes (windowBits = {d})\n", .{ info.window_size, info.window_bits });
    if (info.has_dictionary) {
        if (info.dictionary_id) |id| {
            ui.print("- Preset Dictionary     : Yes (ID: {d})\n", .{id});
        } else {
            ui.print("- Preset Dictionary     : Yes (ID unavailable)\n", .{});
        }
    } else {
        ui.print("- Preset Dictionary     : None\n", .{});
    }
    ui.print("- Compression Level Hint: {s} ({d})\n", .{ info.flevel_description, info.flevel_hint });
    ui.print("========================================\n\n", .{});
}

// ---------------------------------------------------------------------------
// Inflation via std.compress.flate (zlib container).
// ---------------------------------------------------------------------------

const InflateError = error{ OutOfMemory, StreamTooLong } || std.compress.flate.Decompress.Error;

fn inflateZlib(
    gpa: std.mem.Allocator,
    compressed: []const u8,
    max_len: usize,
) InflateError![]u8 {
    var in_reader: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in_reader, .zlib, &window);
    return dec.reader.allocRemaining(gpa, .limited(max_len)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
        error.ReadFailed => return dec.err orelse error.EndOfStream,
    };
}

// ---------------------------------------------------------------------------
// Search event observer (drives the colored CLI output).
// ---------------------------------------------------------------------------

const Observer = struct {
    ui: *Ui,
    verbose: bool,

    fn handle(context: ?*anyopaque, event: fingerprint.Event) void {
        const self: *Observer = @ptrCast(@alignCast(context.?));
        switch (event) {
            .phase_start => |p| {
                self.ui.clearProgress();
                self.ui.print("\n", .{});
                self.ui.setColor(.bold);
                self.ui.setColor(.cyan);
                self.ui.print("-- {s}\n", .{p.title});
                self.ui.setColor(.reset);
            },
            .phase_end => |p| {
                _ = p;
                self.ui.clearProgress();
            },
            .attempt => |a| {
                if (self.verbose) {
                    if (a.matched) {
                        self.ui.cprint(.green, "  [#{d:0>4}] {s} -> MATCH FOUND!\n", .{ a.attempt_no, a.description });
                    } else {
                        self.ui.cprint(.bright_black, "  [#{d:0>4}] {s} -> mismatch\n", .{ a.attempt_no, a.description });
                    }
                } else {
                    if (a.block_total > 0) {
                        self.ui.progress("  {s} {s}: {d}/{d}", .{ a.phase_tag, a.profile_name, a.index_in_block, a.block_total });
                    } else {
                        self.ui.progress("  {s} {s}", .{ a.phase_tag, a.profile_name });
                    }
                }
            },
        }
    }
};

// ---------------------------------------------------------------------------
// CLI entry point.
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -- stdout UI ----------------------------------------------------------
    const out_buf = try arena.alloc(u8, 16 * 1024);
    const fw_storage = try arena.create(std.Io.File.Writer);
    const setup = try ui_mod.setupStdout(io, out_buf, fw_storage, init.environ_map);
    var ui = setup.ui;

    // -- command line -------------------------------------------------------
    const args = try init.minimal.args.toSlice(arena);
    // args[0] is the program name.

    var is_verbose = false;
    var external_zlib = false;
    var positional: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            is_verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--external-zlib")) {
            external_zlib = true;
            continue;
        }
        try positional.append(arena, arg);
    }

    if (positional.items.len < 1) {
        ui.cprint(.yellow, "Usage: zlib-fingerprint [--verbose | -v] [--external-zlib] <compressed_file>\n", .{});
        ui.cprint(.yellow, "  --external-zlib  spawn historical zlib binaries instead of the integrated engine\n", .{});
        return 1;
    }

    const cwd_path = std.process.currentPathAlloc(io, arena) catch "";

    const compressed_path = resolvePath(arena, cwd_path, positional.items[0]) catch {
        std.debug.print("Error: failed to resolve path.\n", .{});
        return 1;
    };

    if (!pathExists(io, compressed_path)) {
        std.debug.print("Error: Compressed file not found: {s}\n", .{compressed_path});
        return 1;
    }

    const original_compressed = std.Io.Dir.cwd().readFileAlloc(io, compressed_path, arena, .limited(1 << 30)) catch |err| {
        std.debug.print("Error: failed to read file: {t}\n", .{err});
        return 1;
    };

    ui.print("Analyzing zlib stream for: ", .{});
    ui.setColor(.bold);
    ui.print("{s}\n", .{std.fs.path.basename(compressed_path)});
    ui.setColor(.reset);

    if (analyzeZlibStream(original_compressed)) |info| {
        printZlibHeaderInfo(&ui, info);
    } else |_| {
        std.debug.print("Warning: Could not fully parse zlib header: Buffer is too short to contain a valid zlib header.\n", .{});
    }

    printDeflateBlocks(&ui, original_compressed);

    ui.print("Decompressing stream to extract uncompressed data...\n", .{});

    const uncompressed = inflateZlib(arena, original_compressed, 1 << 31) catch |err| {
        std.debug.print(
            "Error: Failed to inflate zlib stream. Ensure the file contains a valid zlib-compressed stream.\nDetails: {t}\n",
            .{err},
        );
        return 1;
    };

    ui.print("Successfully unpacked: {d} bytes of raw data.\n\n", .{uncompressed.len});

    // -- locate the binaries directory ---------------------------------------
    // Original resolved `<dist>/../binaries`; the native binary looks for
    // `binaries/` next to the executable itself.
    const binaries_dir = try resolveBinariesDir(arena, io, cwd_path);
    const profiles = try profiles_mod.getProfiles(arena, binaries_dir, external_zlib);

    if (external_zlib) {
        ui.print("Starting parameter search across {d} external compressor profiles...\n", .{profiles.len});
    } else {
        ui.print(
            "Starting parameter search across {d} profiles (integrated zlib 1.2.3-1.3.1 engine + {d} external)...\n",
            .{ profiles.len, profiles.len - 1 },
        );
    }

    // -- run the search ------------------------------------------------------
    var observer = Observer{ .ui = &ui, .verbose = is_verbose };
    var ctx: fingerprint.Ctx = .{
        .gpa = gpa,
        .result_alloc = arena,
        .io = io,
        .notifier = .{ .context = &observer, .notifyFn = &Observer.handle },
    };

    const match = fingerprint.findExactMatch(&ctx, original_compressed, uncompressed, profiles);

    ui.clearProgress();

    if (match) |m| {
        ui.print("\n", .{});
        ui.cprint(.green, "[SUCCESS] Bit-exact match found!\n", .{});
        ui.print("- Implementation: {s}\n", .{m.tool_name});
        ui.print("- Binary path: {s}\n", .{m.binary_path});
        ui.print("- Parameters: {s}\n", .{m.params_summary});
        ui.print("- Attempts: {d}\n", .{ctx.attempts});
    } else {
        ui.print("\n", .{});
        ui.cprint(.yellow, "[RESULT] No bit-exact match was found by any of the available binaries.\n", .{});
        ui.print("Tested {d} compressor invocations.\n", .{ctx.attempts});
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Small filesystem / env helpers.
// ---------------------------------------------------------------------------

/// Same semantics as Node's `path.resolve(cwd, p)`.
fn resolvePath(arena: std.mem.Allocator, cwd_path: []const u8, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p) or cwd_path.len == 0) {
        return std.fs.path.resolve(arena, &.{p});
    }
    return std.fs.path.resolve(arena, &.{ cwd_path, p });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// Resolves the external-binaries directory: `<exe_dir>/binaries` when it
/// exists, falling back to `<cwd>/binaries`, then to plain `./binaries`.
fn resolveBinariesDir(arena: std.mem.Allocator, io: std.Io, cwd_path: []const u8) ![]const u8 {
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len: usize = if (io.vtable.processExecutablePath(io.userdata, &exe_buf)) |n| n else |_| 0;

    if (exe_len > 0) {
        const exe_path = try arena.dupe(u8, exe_buf[0..exe_len]);
        const dir = std.fs.path.dirname(exe_path) orelse ".";
        const candidate = try std.fs.path.join(arena, &.{ dir, "binaries" });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {}
    }

    if (cwd_path.len > 0) {
        const candidate = try std.fs.path.join(arena, &.{ cwd_path, "binaries" });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {}
        return candidate;
    }
    return "binaries";
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "analyzeZlibStream parses a valid header" {
    // 0x78 0xda: CM=8, CINFO=7 (32K window), FLEVEL=3, FDICT=0, FCHECK ok.
    const stream = [_]u8{ 0x78, 0xda, 0x01, 0x02, 0x03 };
    const info = try analyzeZlibStream(&stream);
    try std.testing.expectEqual(@as(u8, 8), info.compression_method);
    try std.testing.expectEqual(@as(u8, 15), info.window_bits);
    try std.testing.expectEqual(@as(u32, 32768), info.window_size);
    try std.testing.expect(info.header_valid);
    try std.testing.expect(!info.has_dictionary);
    try std.testing.expect(info.dictionary_id == null);
    try std.testing.expectEqualStrings("Maximum compression", info.flevel_description);
}

test "analyzeZlibStream rejects short buffers" {
    try std.testing.expectError(error.TooShort, analyzeZlibStream(&.{0x78}));
    try std.testing.expectError(error.TooShort, analyzeZlibStream(&.{}));
}

test "analyzeZlibStream detects preset dictionary" {
    // FDICT set (0x20); checksum bits adjusted so CMF*256+FLG stays %31==0.
    // 0x78*256 + 0xbb = 30907 = 31 * 997 -> valid.
    const stream = [_]u8{ 0x78, 0xbb, 0xAA, 0xBB, 0xCC, 0xDD, 0x00 };
    const info = try analyzeZlibStream(&stream);
    try std.testing.expect(info.has_dictionary);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), info.dictionary_id.?);
}

test "inflateZlib inflates a known-good stream" {
    const compressed = [_]u8{
        0x78, 0xda, 0xcd, 0x8c, 0xb1, 0x0d, 0x80, 0x30, 0x0c, 0x04, 0x57, 0x79,
        0x7a, 0x60, 0x8e, 0x0c, 0x40, 0x45, 0x17, 0x90, 0x43, 0x2c, 0x99, 0x24,
        0xb2, 0x0d, 0x05, 0xd3, 0x13, 0x31, 0x05, 0xd2, 0x5d, 0x77, 0xba, 0x40,
        0x22, 0x75, 0xc4, 0x23, 0xbc, 0x4d, 0x89, 0xcb, 0x41, 0xda, 0x94, 0x8b,
        0x0f, 0x58, 0x32, 0x1b, 0x3a, 0x11, 0x76, 0x46, 0x11, 0x38, 0x99, 0xe3,
        0xa6, 0xdd, 0xab, 0x22, 0x75, 0x3d, 0x13, 0x56, 0x3e, 0xd0, 0xaa, 0x3a,
        0xae, 0xc2, 0xfe, 0x15, 0x36, 0x87, 0xdf, 0x0f, 0x5f, 0xc4, 0x8d, 0x57,
        0xc1,
    };
    const expected = "Hello, zlib-fingerprint! This is a small test vector for the Zig port unit tests." ** 3;

    const testing = std.testing;

    const out = try inflateZlib(testing.allocator, &compressed, 1 << 20);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, expected, out);
}

test "inflateZlib rejects a corrupt stream" {
    const testing = std.testing;

    const bad = [_]u8{ 0x78, 0xda, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02 };
    const result = inflateZlib(testing.allocator, &bad, 1 << 20);
    try testing.expect(std.meta.isError(result));
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("profiles.zig");
    _ = @import("fingerprint.zig");
    _ = @import("ui.zig");
}
