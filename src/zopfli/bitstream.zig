//! Native translation of Zopfli 1.0.3 deflate.c's AddBit, AddBits and
//! AddHuffmanBits. Isolated until the optimal block encoder is migrated.
const std = @import("std");

pub const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,
    bitpointer: u3 = 0,

    pub fn deinit(self: *Writer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    pub fn addBit(self: *Writer, allocator: std.mem.Allocator, bit: u1) !void {
        if (self.bitpointer == 0) try self.bytes.append(allocator, 0);
        self.bytes.items[self.bytes.items.len - 1] |= @as(u8, bit) << self.bitpointer;
        self.bitpointer +%= 1;
    }

    /// Stored extra bits and block fields use LSB-first DEFLATE ordering.
    pub fn addBits(self: *Writer, allocator: std.mem.Allocator, symbol: u32, length: u6) !void {
        for (0..length) |i| {
            try self.addBit(allocator, @truncate(symbol >> @intCast(i)));
        }
    }

    /// Canonical Huffman codes are emitted MSB-first into the bit stream.
    pub fn addHuffmanBits(self: *Writer, allocator: std.mem.Allocator, symbol: u32, length: u6) !void {
        for (0..length) |i| {
            try self.addBit(allocator, @truncate(symbol >> @intCast(@as(usize, length) - i - 1)));
        }
    }
};

test "native Zopfli bit writer preserves mixed Huffman and DEFLATE bit orders" {
    var writer: Writer = .{};
    defer writer.deinit(std.testing.allocator);
    try writer.addBits(std.testing.allocator, 0b101, 3);
    try writer.addHuffmanBits(std.testing.allocator, 0b110, 3);
    try writer.addBits(std.testing.allocator, 0b10, 2);
    try std.testing.expectEqualSlices(u8, &.{0x9d}, writer.bytes.items);
    try std.testing.expectEqual(@as(u3, 0), writer.bitpointer);
}
