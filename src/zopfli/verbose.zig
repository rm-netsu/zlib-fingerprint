//! Verbose diagnostics for the Zopfli core.
//!
//! The upstream code prints progress through `fprintf(stderr, ...)`. The C
//! runtime's `stderr` global is not exported as a data symbol by mingw-w64
//! (it is a macro over `__iob_func`), which breaks Windows cross-builds of
//! the otherwise portable core. This helper formats in Zig and writes
//! directly to file descriptor 2, which is stderr on every platform the
//! project targets; output is unbuffered like C stderr.
const std = @import("std");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(text);
}

pub fn writeAll(text: []const u8) void {
    switch (comptime @import("builtin").os.tag) {
        .windows => {
            const w = std.os.windows;
            const handle = w.peb().ProcessParameters.hStdError;
            var io_status: w.IO_STATUS_BLOCK = undefined;
            _ = w.ntdll.NtWriteFile(handle, null, null, null, &io_status, text.ptr,
                @intCast(text.len), null, null);
        },
        else => _ = std.c.write(2, text.ptr, text.len),
    }
}
