//! Differential-verification CLI for the four in-process historical classes.
//! Usage: zlegacy <a|b|c|d> <level> <memLevel> <strategy> <windowBits>
const std = @import("std");
const legacy = @import("legacy");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len != 6) return 1;
    const class: legacy.Class = if (std.mem.eql(u8, args[1], "a")) .a
        else if (std.mem.eql(u8, args[1], "b")) .b
        else if (std.mem.eql(u8, args[1], "c")) .c
        else if (std.mem.eql(u8, args[1], "d")) .d else return 1;
    const level = std.fmt.parseInt(i8, args[2], 10) catch return 1;
    const mem = std.fmt.parseInt(u8, args[3], 10) catch return 1;
    const strategy = std.fmt.parseInt(u8, args[4], 10) catch return 1;
    const window = std.fmt.parseInt(u8, args[5], 10) catch return 1;

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const input = stdin_fr.interface.allocRemaining(gpa, .limited(1 << 30)) catch return 2;
    defer gpa.free(input);
    const out = gpa.alloc(u8, input.len * 2 + 65536) catch return 3;
    defer gpa.free(out);
    const n = legacy.compress(class, input, out, level, mem, strategy, window) orelse return 4;
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    stdout_fw.interface.writeAll(out[0..n]) catch return 5;
    stdout_fw.interface.flush() catch return 5;
    return 0;
}
