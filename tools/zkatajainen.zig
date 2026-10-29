//! Differential harness for the native Katajainen port: reads a binary
//! frequency vector from stdin and writes the computed length-limited
//! Huffman code lengths, in the exact wire format consumed by
//! scripts/diff_katajainen.py (which compares against upstream C).
//!
//! Input  (stdin): u32 LE n, u32 LE maxbits, n * u64 LE frequencies.
//! Output (stdout): i32 LE rc, n * u32 LE bit lengths.

const std = @import("std");
const katajainen = @import("katajainen");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const input = stdin_fr.interface.allocRemaining(gpa, .limited(1 << 24)) catch return 2;
    defer gpa.free(input);
    if (input.len < 8) return 2;
    const n = std.mem.readInt(u32, input[0..4], .little);
    const maxbits: i32 = @intCast(std.mem.readInt(u32, input[4..8], .little));
    if (input.len < 8 + @as(usize, n) * 8) return 2;

    const freqs = gpa.alloc(usize, n) catch return 2;
    defer gpa.free(freqs);
    const lengths = gpa.alloc(c_uint, if (n == 0) 1 else n) catch return 2;
    defer gpa.free(lengths);
    for (0..n) |i| {
        freqs[i] = std.mem.readInt(u64, input[8 + i * 8 ..][0..8], .little);
    }

    const rc = katajainen.lengthLimitedCodeLengths(freqs.ptr, n, maxbits, lengths.ptr);

    var out: [4]u8 = undefined;
    std.mem.writeInt(i32, &out, rc, .little);
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    stdout_fw.interface.writeAll(&out) catch return 3;
    for (0..n) |i| {
        var rec: [4]u8 = undefined;
        std.mem.writeInt(u32, &rec, lengths[i], .little);
        stdout_fw.interface.writeAll(&rec) catch return 3;
    }
    stdout_fw.interface.flush() catch return 3;
    return 0;
}
