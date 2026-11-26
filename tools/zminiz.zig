//! Development tool: compress stdin -> stdout exactly like the miniz-3.1.2
//! wrapper binary (mz_compress2 one-shot), for the differential
//! verification harness of the native tdefl port.
//!
//! Usage: zminiz <level>        (level 0..10; the wrapper's argv[1])

const std = @import("std");
const tdefl = @import("miniz");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len < 2) {
        std.debug.print("usage: zminiz <level>\n", .{});
        return 1;
    }
    const level = std.fmt.parseInt(u32, args[1], 10) catch return 1;

    // Read all of stdin.
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const input = stdin_fr.interface.allocRemaining(gpa, .limited(1 << 31)) catch return 2;
    defer gpa.free(input);

    var c = tdefl.Compressor.init(gpa);
    defer c.deinit();
    const out = c.compressZlib(input, level) catch {
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
