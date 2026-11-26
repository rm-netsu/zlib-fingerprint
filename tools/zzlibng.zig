//! Development tool: compress stdin -> stdout exactly like the zlib-ng-2.2.1
//! wrapper binary (one-shot deflateInit2 + single Z_FINISH), for the
//! differential verification harness of the native zlib-ng port.
//!
//! Usage: zzlibng <level> <memLevel> <strategy> <windowBits>

const std = @import("std");
const zlibng = @import("zlibng");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len < 5) {
        std.debug.print("usage: zzlibng <level> <memLevel> <strategy> <windowBits>\n", .{});
        return 1;
    }
    const level = std.fmt.parseInt(i32, args[1], 10) catch return 1;
    const mem_level = std.fmt.parseInt(u8, args[2], 10) catch return 1;
    const strategy = std.fmt.parseInt(u8, args[3], 10) catch return 1;
    _ = std.fmt.parseInt(u8, args[4], 10) catch return 1;
    // The reference wrapper hardcodes windowBits = 15 (it accepts a fourth
    // argument but passes a literal 15 to deflateInit2); mirror it exactly.
    const window_bits: u8 = 15;

    // Read all of stdin.
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const input = stdin_fr.interface.allocRemaining(gpa, .limited(1 << 31)) catch return 2;
    defer gpa.free(input);

    var c = zlibng.Compressor.init(gpa);
    defer c.deinit();
    const out = c.compressZlib(input, level, mem_level, strategy, window_bits) catch {
        std.debug.print("compress failed\n", .{});
        return 4;
    };
    defer gpa.free(out);

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    stdout_fw.interface.writeAll(out) catch return 5;
    stdout_fw.interface.flush() catch return 5;
    return 0;
}
