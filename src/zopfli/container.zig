//! RFC 1950 wrapper for Zopfli. The header and Adler-32 checksum are
//! assembled in Zig, sharing the zlib implementation's checksum routine.
//! The FLEVEL header bits differ per release: 1.0.0/1.0.1 write 0
//! (`78 01`), 1.0.2+ write 3 (`78 da`).
const std = @import("std");
const replicant = @import("zlib-replicant");
const release = @import("release.zig");

/// Header of the modern releases (1.0.2+): CINFO=7, FLEVEL=3, FCHECK=26.
pub const header = [2]u8{ 0x78, 0xda };

/// Owns the returned zlib stream; the raw DEFLATE payload stays byte-exact.
pub fn wrap(alloc: std.mem.Allocator, original: []const u8, raw_deflate: []const u8) ![]u8 {
    return wrapRelease(alloc, original, raw_deflate, .v1_0_3);
}

pub fn wrapRelease(alloc: std.mem.Allocator, original: []const u8, raw_deflate: []const u8, variant: release.ZopfliRelease) ![]u8 {
    const length = std.math.add(usize, raw_deflate.len, 6) catch return error.OutOfMemory;
    const result = try alloc.alloc(u8, length);
    @memcpy(result[0..2], &variant.containerHeader());
    @memcpy(result[2 .. 2 + raw_deflate.len], raw_deflate);
    const checksum = replicant.adler32(1, original);
    const tail = result[length - 4 ..];
    tail[0] = @truncate(checksum >> 24);
    tail[1] = @truncate(checksum >> 16);
    tail[2] = @truncate(checksum >> 8);
    tail[3] = @truncate(checksum);
    return result;
}

test "Zopfli header is RFC 1950 canonical, checksum matches shared zlib core" {
    const wrapped = try wrap(std.testing.allocator, "123456789", &.{ 0x03, 0x00 });
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda, 0x03, 0x00, 0x09, 0x1e, 0x01, 0xde }, wrapped);
}

test "legacy releases write FLEVEL=0 header bytes" {
    const wrapped = try wrapRelease(std.testing.allocator, "123456789", &.{ 0x03, 0x00 }, .v1_0_1);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x01, 0x03, 0x00, 0x09, 0x1e, 0x01, 0xde }, wrapped);
}
