//! In-process adapters to four vendor-preserved historical zlib generations.
//! Each one calls separately compiled original C code with renamed symbols.
//! No child process, system libz, or runtime DLL is needed.
const std = @import("std");

pub const Class = enum { a, b, c, d };

extern fn zf_legacy_a([*]const u8, usize, [*]u8, usize, *usize, c_int, c_int, c_int, c_int) callconv(.c) c_int;
extern fn zf_legacy_b([*]const u8, usize, [*]u8, usize, *usize, c_int, c_int, c_int, c_int) callconv(.c) c_int;
extern fn zf_legacy_c([*]const u8, usize, [*]u8, usize, *usize, c_int, c_int, c_int, c_int) callconv(.c) c_int;
extern fn zf_legacy_d([*]const u8, usize, [*]u8, usize, *usize, c_int, c_int, c_int, c_int) callconv(.c) c_int;

pub fn compress(class: Class, input: []const u8, output: []u8, level: i8, mem_level: u8, strategy: u8, window_bits: u8) ?usize {
    var written: usize = 0;
    const args = .{ input.ptr, input.len, output.ptr, output.len, &written,
        @as(c_int, level), @as(c_int, mem_level), @as(c_int, strategy), @as(c_int, window_bits) };
    const rc = switch (class) {
        .a => @call(.auto, zf_legacy_a, args),
        .b => @call(.auto, zf_legacy_b, args),
        .c => @call(.auto, zf_legacy_c, args),
        .d => @call(.auto, zf_legacy_d, args),
    };
    return if (rc == 0) written else null;
}

test "legacy class adapters can compress an empty payload" {
    var output: [1024]u8 = undefined;
    for ([_]Class{ .a, .b, .c, .d }) |class| {
        const size = compress(class, "", &output, 6, 8, 0, 15) orelse return error.CompressionFailed;
        try std.testing.expect(size >= 8);
        try std.testing.expectEqual(@as(u8, 0x78), output[0]);
    }
}
