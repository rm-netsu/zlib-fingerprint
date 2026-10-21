//! Development tool: compress stdin -> stdout exactly like the historical
//! zlib wrapper binaries, for the differential verification harness.
//!
//! Usage: zcompress <version> <level> <memLevel> <strategy> <windowBits>
//! (version is e.g. "1.2.3" or "1.3.1")

const std = @import("std");
const deflate = @import("deflate");
const dbg = false;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len < 6) {
        std.debug.print("usage: zcompress <version> <level> <memLevel> <strategy> <windowBits>\n", .{});
        return 1;
    }

    const version_str = args[1];
    var version: ?deflate.Version = null;
    for (deflate.all_versions) |v| {
        if (std.mem.eql(u8, v.name(), version_str)) version = v;
    }
    if (std.mem.eql(u8, version_str, "1.3.0")) version = .v1_3_0;
    if (version == null) {
        std.debug.print("unknown version: {s}\n", .{version_str});
        return 1;
    }

    const level = std.fmt.parseInt(u32, args[2], 10) catch return 1;
    const mem_level = std.fmt.parseInt(u32, args[3], 10) catch return 1;
    const strategy = std.fmt.parseInt(u32, args[4], 10) catch return 1;
    const window_bits = std.fmt.parseInt(u32, args[5], 10) catch return 1;

    // Read all of stdin.
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const input = stdin_fr.interface.allocRemaining(gpa, .limited(1 << 31)) catch return 2;
    defer gpa.free(input);

    if (dbg) deflate.dbg_enabled.* = true;
    var c = deflate.Compressor.init(gpa) catch return 3;
    defer c.deinit();

    const out = gpa.alloc(u8, deflate.Compressor.requiredOutputLen(input.len)) catch return 3;
    defer gpa.free(out);

    const n = c.compress(version.?, level, mem_level, strategy, window_bits, input, out) catch |e| {
        std.debug.print("compress failed: {t}\n", .{e});
        return 4;
    };

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    stdout_fw.interface.writeAll(out[0..n]) catch return 5;
    stdout_fw.interface.flush() catch return 5;
    return 0;
}
