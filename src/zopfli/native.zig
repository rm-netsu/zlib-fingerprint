//! In-process Zopfli adapter — fully native Zig, all historical releases.
//! RFC 1950 container and Adler-32 via shared Zig state; the DEFLATE
//! optimizer (LZ77, block splitting, package-merge, block encoder) runs
//! entirely in Zig. Options replicate upstream util.c's ZopfliInitOptions;
//! the release variant selects the historical behaviour.
const std = @import("std");
const container = @import("container.zig");
const driver = @import("deflate_driver.zig");
const blocks = @import("deflate_blocks.zig");
const release = @import("release.zig");

extern "c" fn free(ptr: ?*anyopaque) callconv(.c) void;

pub const ZopfliRelease = release.ZopfliRelease;
pub const Error = error{ InvalidIterations, CompressionFailed, OutOfMemory, EmptyInputRejected };

/// Default variant used by callers that are not release-aware.
pub const default_release: ZopfliRelease = .v1_0_3;

/// Returns an owned Zopfli zlib stream produced exactly like the requested
/// historical release. No external process is started and no C translation
/// unit participates: this calls the native Zig DEFLATE driver directly with
/// the upstream default options (ZopfliInitOptions) and the requested
/// iteration count.
///
/// For 1.0.0/1.0.1 an empty input reproduces the official CLI behaviour of
/// refusing the file ("Invalid filename") and yields error.EmptyInputRejected.
pub fn compress(allocator: std.mem.Allocator, input: []const u8, iterations: u32, variant: ZopfliRelease) Error![]u8 {
    if (iterations == 0 or iterations > 500) return error.InvalidIterations;
    if (input.len == 0 and variant.rejectsEmptyInput()) return error.EmptyInputRejected;
    var options = release.initOptions(@intCast(iterations), variant);
    var raw: ?[*]u8 = null;
    var raw_size: usize = 0;
    var bitpointer: u8 = 0;
    driver.ZopfliDeflate(&options, 2, 1, input.ptr, input.len, &bitpointer, &raw, &raw_size);
    if (raw == null) return error.CompressionFailed;
    defer free(@ptrCast(raw));
    return container.wrapRelease(allocator, input, raw.?[0..raw_size], variant) catch return error.OutOfMemory;
}

/// Backwards-compatible entry point: compresses like Zopfli 1.0.3.
pub fn compressDefault(allocator: std.mem.Allocator, input: []const u8, iterations: u32) Error![]u8 {
    return compress(allocator, input, iterations, default_release);
}

test "Zopfli in-process compressor produces canonical header and checksum" {
    const result = try compress(std.testing.allocator, "hello Zopfli", 1, .v1_0_3);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &container.header, result[0..2]);
    try std.testing.expectEqual(@as(u32, 0x1e1904a9), std.mem.readInt(u32, result[result.len - 4 ..][0..4], .big));
}

test "Zopfli in-process compressor supports repeated invocations" {
    // Repeated calls exercise allocator and node-pool reuse across
    // compressions; the testing allocator flags leaks and double frees.
    const inputs = [_][]const u8{ "", "a", "hello Zopfli", "abcabcabcabcabcabc" };
    for (inputs, 0..) |input, i| {
        const result = try compress(std.testing.allocator, input, @intCast(1 + i), .v1_0_3);
        defer std.testing.allocator.free(result);
        try std.testing.expect(result.len >= 6);
        try std.testing.expectEqualSlices(u8, &container.header, result[0..2]);
    }
}

test "legacy releases reject empty input like the official CLI" {
    try std.testing.expectError(error.EmptyInputRejected, compress(std.testing.allocator, "", 1, .v1_0_0));
    try std.testing.expectError(error.EmptyInputRejected, compress(std.testing.allocator, "", 1, .v1_0_1));
    const modern = try compress(std.testing.allocator, "", 1, .v1_0_3);
    defer std.testing.allocator.free(modern);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 }, modern);
}

test "legacy releases emit FLEVEL=0 container for non-empty input" {
    const result = try compress(std.testing.allocator, "hello Zopfli", 1, .v1_0_0);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x01 }, result[0..2]);
}
