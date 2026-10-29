//! Differential helper: zzopfli <iterations> [release] < input > output.zlib
//! `release` selects the historical behaviour: 1.0.0, 1.0.1, 1.0.2 or the
//! default 1.0.3.
const std = @import("std");
const zopfli = @import("zopfli/native.zig");
comptime {
    _ = @import("zopfli/hash.zig");
    _ = @import("zopfli/cache.zig");
    _ = @import("zopfli/lz77_store.zig");
    _ = @import("zopfli/lz77_greedy.zig");
    _ = @import("zopfli/lz77_match.zig");
    _ = @import("zopfli/squeeze_path.zig");
    _ = @import("zopfli/squeeze_stats.zig");
    _ = @import("zopfli/squeeze_forward.zig");
    _ = @import("zopfli/squeeze_optimal.zig");
    _ = @import("zopfli/blocksplitter.zig");
    _ = @import("zopfli/deflate_rle.zig");
    _ = @import("zopfli/deflate_cost.zig");
    _ = @import("zopfli/deflate_tree_encode.zig");
    _ = @import("zopfli/deflate_lz77_output.zig");
    _ = @import("zopfli/deflate_dynamic.zig");
    _ = @import("zopfli/deflate_block_size.zig");
    _ = @import("zopfli/deflate_driver.zig");
    _ = @import("zopfli/tree.zig");
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    const release_mod = @import("zopfli/release.zig");
    var variant: release_mod.ZopfliRelease = .v1_0_3;
    if (args.len == 3) {
        variant = release_mod.ZopfliRelease.parse(args[2]) orelse return 1;
    } else if (args.len != 2) {
        return 1;
    }
    const iterations = std.fmt.parseInt(u32, args[1], 10) catch return 1;
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const input = stdin_fr.interface.allocRemaining(gpa, .limited(1 << 30)) catch return 2;
    defer gpa.free(input);
    const result = zopfli.compress(gpa, input, iterations, variant) catch return 3;
    defer gpa.free(result);
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    stdout_fw.interface.writeAll(result) catch return 4;
    stdout_fw.interface.flush() catch return 4;
    return 0;
}
