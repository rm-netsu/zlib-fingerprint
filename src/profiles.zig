//! Compression tool profile definitions.
//!
//! One-to-one port of the original TypeScript `profiles.ts`: each profile
//! describes one external compressor binary (where to find it and how to turn
//! search parameters into its command line arguments).
//!
//! Since the integrated zlib deflate engine landed (see `deflate/`), stock
//! zlib candidates no longer need external binaries: profiles with
//! `stock = true` are served by the internal engine by default (pass
//! `--external-zlib` to fall back to spawning the historical binaries).
//! zlib-ng keeps `stock = false` — its compressed output diverges from stock
//! zlib, so it must stay an external binary in both modes.

const std = @import("std");
const builtin = @import("builtin");

/// Kind of external compressor a profile wraps.
///
/// Mirrors the `BinaryProfile.type` union of the original tool.
pub const Kind = enum {
    zlib,
    zopfli,
    libdeflate,
    miniz,
    advdef,
};

/// Search parameters for one candidate compression attempt.
pub const Params = struct {
    level: i32 = 0,
    mem_level: i32 = 0,
    strategy: i32 = 0,
    window_bits: i32 = 15,
    iteration: i32 = 0,
};

/// Upper bound for the number of command line arguments any profile needs
/// (argv[0] included).
pub const max_args = 8;

/// Upper bound for the length of one formatted argument.
pub const max_arg_len = 32;

/// Stack scratch space used to format command line arguments for one spawn.
///
/// Keeps the hot search loop allocation-free: buffers live on the caller's
/// stack and are reused for every attempt.
pub const ArgScratch = struct {
    bufs: [max_args][max_arg_len]u8 = undefined,
    argv: [max_args][]const u8 = undefined,
    count: usize = 0,

    fn push(self: *ArgScratch, text: []const u8) void {
        std.debug.assert(self.count < max_args);
        self.argv[self.count] = text;
        self.count += 1;
    }

    fn pushFmt(self: *ArgScratch, comptime fmt: []const u8, args: anytype) void {
        std.debug.assert(self.count < max_args);
        const s = std.fmt.bufPrint(&self.bufs[self.count], fmt, args) catch unreachable;
        self.argv[self.count] = s;
        self.count += 1;
    }

    pub fn slice(self: *const ArgScratch) []const []const u8 {
        return self.argv[0..self.count];
    }
};

pub const Profile = struct {
    name: []const u8,
    binary_path: []const u8,
    kind: Kind,
    /// True for stock zlib profiles — these are served by the integrated
    /// deflate engine in the default (internal) mode.
    stock: bool = false,
    /// True for the single collapsed integrated-zlib profile (internal mode).
    /// Such profiles never spawn a binary; the search engine compresses with
    /// the built-in `deflate` module instead.
    integrated: bool = false,

    /// Fills `scratch` with the full argv (argv[0] = binary path) for the
    /// given parameters. Mirrors the `getArgs` closures of the original.
    pub fn getArgs(self: *const Profile, params: Params, scratch: *ArgScratch) []const []const u8 {
        scratch.* = .{};
        scratch.push(self.binary_path);
        switch (self.kind) {
            // Wrapper C binaries take: level, memLevel, strategy, windowBits.
            .zlib => {
                scratch.pushFmt("{d}", .{params.level});
                scratch.pushFmt("{d}", .{params.mem_level});
                scratch.pushFmt("{d}", .{params.strategy});
                scratch.pushFmt("{d}", .{params.window_bits});
            },
            .zopfli => {
                scratch.push("--deflate");
                scratch.pushFmt("--iterations={d}", .{params.iteration});
            },
            .libdeflate, .miniz => {
                scratch.pushFmt("{d}", .{params.level});
            },
            // Defined for parity with the original profile list; note that the
            // original search engine never dispatches `advdef` profiles.
            .advdef => {
                scratch.pushFmt("-{d}", .{params.level});
                scratch.push("-z");
                scratch.push("-k");
            },
        }
        return scratch.slice();
    }
};

const Entry = struct {
    name: []const u8,
    file: []const u8,
    kind: Kind,
    /// Stock zlib (integrated engine candidate) vs third-party zlib API
    /// compatible implementation (zlib-ng — always an external binary).
    stock: bool,
};

/// Same ordered profile list as the original `getProfiles`.
const entries = [_]Entry{
    .{ .name = "zlib 1.2.8", .file = "zlib-1.2.8", .kind = .zlib, .stock = true },
    .{ .name = "zlib-ng 2.2.1", .file = "zlib-ng-2.2.1", .kind = .zlib, .stock = false },
    .{ .name = "Zopfli 1.0.3", .file = "zopfli-1.0.3", .kind = .zopfli, .stock = false },
    .{ .name = "libdeflate 1.20", .file = "libdeflate-1.20", .kind = .libdeflate, .stock = false },
    .{ .name = "miniz 3.1.2", .file = "miniz-3.1.2", .kind = .miniz, .stock = false },
    .{ .name = "AdvanceCOMP 2.6 advdef", .file = "advdef-2.6", .kind = .advdef, .stock = false },
    .{ .name = "zlib 1.3.1", .file = "zlib-1.3.1", .kind = .zlib, .stock = true },
    .{ .name = "zlib 1.2.5", .file = "zlib-1.2.5", .kind = .zlib, .stock = true },
    .{ .name = "zlib 1.2.3", .file = "zlib-1.2.3", .kind = .zlib, .stock = true },
    .{ .name = "zlib 1.2.7", .file = "zlib-1.2.7", .kind = .zlib, .stock = true },
    .{ .name = "zlib 1.2.11", .file = "zlib-1.2.11", .kind = .zlib, .stock = true },
};

/// Builds the profile list, appending the platform executable extension
/// (`.exe`) when compiled for Windows — same rule as the original tool.
///
/// In the default internal mode all stock-zlib entries are collapsed into a
/// single integrated profile placed at the position of the first stock-zlib
/// entry (which is also the first entry of the list, keeping the original
/// search order). Pass `external_zlib = true` to keep the historical
/// behavior of spawning every zlib binary.
pub fn getProfiles(
    alloc: std.mem.Allocator,
    binaries_dir: []const u8,
    external_zlib: bool,
) ![]Profile {
    const ext: []const u8 = if (builtin.os.tag == .windows) ".exe" else "";

    var list: std.ArrayList(Profile) = .empty;
    var integrated_added = false;
    for (entries) |e| {
        if (!external_zlib and e.stock) {
            if (integrated_added) continue;
            integrated_added = true;
            try list.append(alloc, .{
                .name = "zlib (integrated)",
                .binary_path = "(integrated deflate engine)",
                .kind = .zlib,
                .stock = true,
                .integrated = true,
            });
            continue;
        }
        const file = try std.fmt.allocPrint(alloc, "{s}{s}", .{ e.file, ext });
        const path = try std.fs.path.join(alloc, &.{ binaries_dir, file });
        try list.append(alloc, .{
            .name = e.name,
            .binary_path = path,
            .kind = e.kind,
            .stock = e.stock,
        });
    }
    return list.toOwnedSlice(alloc);
}

test "getArgs formats zlib wrapper arguments" {
    const p: Profile = .{ .name = "zlib 1.3.1", .binary_path = "/bin/zlib-1.3.1", .kind = .zlib, .stock = true };
    var scratch: ArgScratch = .{};
    const argv = p.getArgs(.{ .level = 6, .mem_level = 8, .strategy = 0, .window_bits = 15 }, &scratch);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("/bin/zlib-1.3.1", argv[0]);
    try std.testing.expectEqualStrings("6", argv[1]);
    try std.testing.expectEqualStrings("8", argv[2]);
    try std.testing.expectEqualStrings("0", argv[3]);
    try std.testing.expectEqualStrings("15", argv[4]);
}

test "getArgs formats zopfli and libdeflate arguments" {
    const z: Profile = .{ .name = "Zopfli 1.0.3", .binary_path = "/bin/zopfli", .kind = .zopfli };
    var scratch: ArgScratch = .{};
    const zargv = z.getArgs(.{ .iteration = 250 }, &scratch);
    try std.testing.expectEqual(@as(usize, 3), zargv.len);
    try std.testing.expectEqualStrings("--deflate", zargv[1]);
    try std.testing.expectEqualStrings("--iterations=250", zargv[2]);

    const l: Profile = .{ .name = "libdeflate 1.20", .binary_path = "/bin/libdeflate", .kind = .libdeflate };
    const largv = l.getArgs(.{ .level = 12 }, &scratch);
    try std.testing.expectEqual(@as(usize, 2), largv.len);
    try std.testing.expectEqualStrings("12", largv[1]);
}

test "getProfiles builds full list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // External mode: every entry becomes a binary profile.
    const list = try getProfiles(alloc, "/binaries", true);
    try std.testing.expectEqual(@as(usize, entries.len), list.len);
    try std.testing.expectEqualStrings("zlib 1.2.8", list[0].name);
    try std.testing.expectEqual(Kind.zopfli, list[2].kind);
    try std.testing.expect(!list[1].stock); // zlib-ng stays external

    // Internal mode: stock-zlib entries collapse into one integrated profile.
    const internal = try getProfiles(alloc, "/binaries", false);
    const stock_count = comptime blk: {
        var n = 0;
        for (entries) |e| {
            if (e.stock) n += 1;
        }
        break :blk n;
    };
    try std.testing.expectEqual(@as(usize, entries.len - stock_count + 1), internal.len);
    try std.testing.expectEqualStrings("zlib (integrated)", internal[0].name);
    try std.testing.expect(internal[0].stock);
    try std.testing.expectEqualStrings("zlib-ng 2.2.1", internal[1].name);
    var external_count: usize = 0;
    for (internal) |p| {
        if (!p.stock) external_count += 1;
        if (p.stock) try std.testing.expectEqualStrings("zlib (integrated)", p.name);
    }
    try std.testing.expectEqual(@as(usize, 5), external_count); // ng/zopfli/libdeflate/miniz/advdef
}
