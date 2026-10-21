//! RFC 1950 header metadata extraction and "header prediction" helpers.
//!
//! The fingerprint search uses the zlib container header as a strong hint
//! source:
//!   - CINFO  (CMF >> 4)   -> windowBits used by the producer (wBits = CINFO+8)
//!   - FLEVEL (FLG >> 6)   -> which (level, strategy) classes can reproduce it
//!   - FDICT  (FLG bit 5)  -> preset dictionary (not reproducible without it)
//!   - FCHECK validity    -> canonical header vs custom writer
//!
//! Because every zlib-family implementation writes CMF/FLG deterministically
//! from (windowBits, level, strategy), we can *predict* the two header bytes
//! a candidate would emit and skip every candidate that provably cannot
//! match the observed stream. This removes the majority of futile spawns
//! compared to the naive full-matrix search.

const std = @import("std");

pub const Flevel = u2;

pub const FLEVEL_DESCRIPTIONS = [4][]const u8{
    "fastest algorithm",
    "fast algorithm",
    "default algorithm",
    "maximum compression",
};

/// Parsed RFC 1950 container header.
pub const Header = struct {
    cmf: u8,
    flg: u8,
    cm: u8,
    cinfo: u8,
    fdict: bool,
    dict_id: ?u32,
    flevel: Flevel,
    fcheck_ok: bool,
    /// windowBits implied by CINFO (cinfo + 8). For cinfo == 0 this is 8,
    /// which no stock zlib actually emits (8 is upgraded to 9 internally).
    window_bits: u8,

    /// Full 16-bit header word (CMF << 8 | FLG).
    pub fn word(h: Header) u16 {
        return (@as(u16, h.cmf) << 8) | h.flg;
    }

    /// A header is *canonical* when it is exactly what a stock zlib-family
    /// implementation would emit: deflate method, sane CINFO, valid FCHECK
    /// and no preset dictionary.
    pub fn canonical(h: Header) bool {
        return h.cm == 8 and h.cinfo >= 1 and h.cinfo <= 7 and h.fcheck_ok and !h.fdict;
    }

    /// Human-readable level class name.
    pub fn flevelName(h: Header) []const u8 {
        return FLEVEL_DESCRIPTIONS[h.flevel];
    }
};

pub const HeaderError = error{ TooShort, NotDeflate };

/// Parse the 2-byte (plus optional DICTID) zlib header.
pub fn parseHeader(data: []const u8) HeaderError!Header {
    if (data.len < 2) return error.TooShort;
    const cmf = data[0];
    const flg = data[1];
    const cm: u8 = cmf & 0x0F;
    const cinfo: u8 = (cmf >> 4) & 0x0F;
    const fdict = (flg & 0x20) != 0;
    const flevel: Flevel = @intCast((flg >> 6) & 0x03);
    const fcheck_ok = (@as(u32, cmf) * 256 + @as(u32, flg)) % 31 == 0;
    var dict_id: ?u32 = null;
    if (fdict) {
        if (data.len >= 6) {
            dict_id = std.mem.readInt(u32, data[2..6], .big);
        }
    }
    return .{
        .cmf = cmf,
        .flg = flg,
        .cm = cm,
        .cinfo = cinfo,
        .fdict = fdict,
        .dict_id = dict_id,
        .flevel = flevel,
        .fcheck_ok = fcheck_ok,
        .window_bits = cinfo + 8,
    };
}

pub const BlockInfo = struct {
    bfinal: u1,
    btype: u2,
};

/// Inspect the first DEFLATE block header (BFINAL/BTYPE).
/// Returns null when the payload does not start where expected.
pub fn firstBlockInfo(data: []const u8) ?BlockInfo {
    if (data.len < 3) return null;
    const h = parseHeader(data) catch return null;
    var off: usize = 2;
    if (h.fdict) off += 4;
    if (data.len <= off) return null;
    const b0 = data[off];
    return .{
        .bfinal = @intCast(b0 & 1),
        .btype = @intCast((b0 >> 1) & 0x03),
    };
}

/// FLEVEL field a stock zlib-family implementation writes for the given
/// (level, strategy). Mirrors deflate.c:
///
///   if (s->strategy >= Z_HUFFMAN_ONLY || s->level < 2) level_flags = 0;
///   else if (s->level < 6) level_flags = 1;
///   else if (s->level == 6) level_flags = 2;
///   else level_flags = 3;
///
/// Z_HUFFMAN_ONLY == 2, so Z_FILTERED (1) still follows the level mapping.
/// zlib-ng keeps the same logic in its compat API.
pub fn zlibFlevel(level: i32, strategy: u32) Flevel {
    if (strategy >= 2) return 0;
    if (level < 2) return 0;
    if (level < 6) return 1;
    if (level == 6) return 2;
    return 3;
}

/// Compute FCHECK so that (CMF * 256 + FLG) % 31 == 0.
fn withFcheck(cmf: u8, flg_base: u8) u16 {
    const rem = (@as(u32, cmf) * 256 + @as(u32, flg_base)) % 31;
    const fcheck: u8 = @intCast((31 - rem) % 31);
    return (@as(u16, cmf) << 8) | flg_base | fcheck;
}

/// Predict the 16-bit container header a stock zlib-family implementation
/// emits for the given parameters (no preset dictionary).
///
/// Note: zlib silently upgrades windowBits == 8 to 9, so CINFO is computed
/// from the *effective* window.
pub fn zlibContainerHeader(window_bits_in: u8, level: i32, strategy: u32) u16 {
    const wb: u8 = if (window_bits_in == 8) 9 else window_bits_in;
    const cmf: u8 = @intCast(8 | ((wb - 8) << 4));
    const flg_base: u8 = @intCast(@as(u32, zlibFlevel(level, strategy)) << 6);
    return withFcheck(cmf, flg_base);
}

/// Zopfli's own zlib container writer (--zlib) always emits CMF=0x78 with
/// FLEVEL=3 ("maximum compression"), i.e. the byte pair 0x78 0xDA —
/// verified empirically against zopfli-1.0.3 and its vendored source
/// (vendor/zopfli-zopfli-1.0.3/src/zopfli/zlib_container.c).
/// Note: `--deflate` produces RAW deflate without a zlib container, so it
/// can never match a zlib stream.
pub const zopfli_header: u16 = 0x78DA;

/// libdeflate writes a fixed CINFO=7 header and maps its 1..12 level onto
/// FLEVEL as: 1 -> 0, 2-5 -> 1, 6-7 -> 2, 8-12 -> 3.
/// Verified empirically against libdeflate-1.20 (header bytes captured for
/// every level).
pub fn libdeflateHeader(level: u32) u16 {
    const flevel: u2 = switch (level) {
        1 => 0,
        2...5 => 1,
        6...7 => 2,
        8...12 => 3,
        else => 2,
    };
    const flg_base: u8 = @intCast(@as(u32, flevel) << 6);
    return withFcheck(0x78, flg_base);
}

/// miniz (mz_compress2) writes a fixed CINFO=7 header with the zlib
/// level->FLEVEL pattern applied to its 1..10 scale:
/// 1 -> 0, 2-5 -> 1, 6 -> 2, 7-10 -> 3.
/// Verified empirically against miniz-3.1.2 (header bytes captured for
/// every level).
pub fn minizHeader(level: u32) u16 {
    const flevel: u2 = switch (level) {
        1 => 0,
        2...5 => 1,
        6 => 2,
        7...10 => 3,
        else => 2,
    };
    const flg_base: u8 = @intCast(@as(u32, flevel) << 6);
    return withFcheck(0x78, flg_base);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseHeader: default level 6 stream (0x78 0x9C)" {
    const h = try parseHeader(&[_]u8{ 0x78, 0x9C, 0x4B, 0xCD });
    try testing.expectEqual(@as(u8, 8), h.cm);
    try testing.expectEqual(@as(u8, 7), h.cinfo);
    try testing.expectEqual(@as(u8, 15), h.window_bits);
    try testing.expectEqual(@as(Flevel, 2), h.flevel);
    try testing.expect(!h.fdict);
    try testing.expect(h.fcheck_ok);
    try testing.expect(h.canonical());
    try testing.expectEqual(@as(u16, 0x789C), h.word());
}

test "parseHeader: FDICT stream exposes dictionary id" {
    var data = [_]u8{ 0x78, 0xF9, 0xDE, 0xAD, 0xBE, 0xEF, 0x00 };
    const h = try parseHeader(&data);
    try testing.expect(h.fdict);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), h.dict_id.?);
    try testing.expect(!h.canonical());
    data[6] = 0; // silence unused warning on some targets
}

test "parseHeader: corrupt FCHECK is detected" {
    const h = try parseHeader(&[_]u8{ 0x78, 0x9D });
    try testing.expect(!h.fcheck_ok);
    try testing.expect(!h.canonical());
}

test "zlibFlevel mirrors deflate.c mapping" {
    try testing.expectEqual(@as(Flevel, 0), zlibFlevel(0, 0));
    try testing.expectEqual(@as(Flevel, 0), zlibFlevel(1, 0));
    try testing.expectEqual(@as(Flevel, 1), zlibFlevel(2, 0));
    try testing.expectEqual(@as(Flevel, 1), zlibFlevel(5, 0));
    try testing.expectEqual(@as(Flevel, 2), zlibFlevel(6, 0));
    try testing.expectEqual(@as(Flevel, 3), zlibFlevel(7, 0));
    try testing.expectEqual(@as(Flevel, 3), zlibFlevel(9, 0));
    // FILTERED keeps level-based FLEVEL; HUFFMAN_ONLY/RLE/FIXED force 0.
    try testing.expectEqual(@as(Flevel, 1), zlibFlevel(5, 1));
    try testing.expectEqual(@as(Flevel, 2), zlibFlevel(6, 1));
    try testing.expectEqual(@as(Flevel, 0), zlibFlevel(9, 2));
    try testing.expectEqual(@as(Flevel, 0), zlibFlevel(9, 3));
    try testing.expectEqual(@as(Flevel, 0), zlibFlevel(9, 4));
}

test "zlibContainerHeader reproduces well-known header bytes" {
    try testing.expectEqual(@as(u16, 0x7801), zlibContainerHeader(15, 1, 0));
    try testing.expectEqual(@as(u16, 0x785E), zlibContainerHeader(15, 2, 0));
    try testing.expectEqual(@as(u16, 0x789C), zlibContainerHeader(15, 6, 0));
    try testing.expectEqual(@as(u16, 0x78DA), zlibContainerHeader(15, 9, 0));
    try testing.expectEqual(@as(u16, 0x7801), zlibContainerHeader(15, 6, 2));
    // windowBits 12 -> CINFO 4; windowBits 8 is upgraded to 9 internally.
    try testing.expectEqual(@as(u16, 0x4889), zlibContainerHeader(12, 6, 0));
    try testing.expectEqual(@as(u16, 0x1819), zlibContainerHeader(8, 1, 0));
}

test "libdeflateHeader and minizHeader match empirical captures" {
    try testing.expectEqual(@as(u16, 0x7801), libdeflateHeader(1));
    try testing.expectEqual(@as(u16, 0x785E), libdeflateHeader(3));
    try testing.expectEqual(@as(u16, 0x789C), libdeflateHeader(6));
    try testing.expectEqual(@as(u16, 0x78DA), libdeflateHeader(8));
    try testing.expectEqual(@as(u16, 0x78DA), libdeflateHeader(12));
    try testing.expectEqual(@as(u16, 0x7801), minizHeader(1));
    try testing.expectEqual(@as(u16, 0x785E), minizHeader(4));
    try testing.expectEqual(@as(u16, 0x789C), minizHeader(6));
    try testing.expectEqual(@as(u16, 0x78DA), minizHeader(7));
    try testing.expectEqual(@as(u16, 0x78DA), minizHeader(10));
    try testing.expectEqual(@as(u16, 0x78DA), zopfli_header);
}

test "firstBlockInfo reads BTYPE after optional DICTID" {
    // 0x78 0x9C then first deflate byte: stored block (btype=0), bfinal=1
    const blk = firstBlockInfo(&[_]u8{ 0x78, 0x9C, 0x01 }).?;
    try testing.expectEqual(@as(u2, 0), blk.btype);
    try testing.expectEqual(@as(u1, 1), blk.bfinal);
    // dynamic huffman block
    const blk2 = firstBlockInfo(&[_]u8{ 0x78, 0x9C, 0x04 }).?;
    try testing.expectEqual(@as(u2, 2), blk2.btype);
}
