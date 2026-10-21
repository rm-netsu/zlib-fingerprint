//! Colored terminal output helpers.
//!
//! Uses `std.Io.Terminal.Mode.detect` for capability detection (NO_COLOR /
//! CLICOLOR_FORCE conventions, enabling ANSI escape codes on Windows 10+
//! consoles, legacy Windows console API fallback).
//!
//! Note: `std.Io.Terminal.setColor` only emits a bare ESC byte in escape-code
//! mode in Zig 0.16.0, so ANSI SGR sequences are produced here directly; the
//! Windows API branch is still delegated to `Terminal.setColor`.

const std = @import("std");

pub const Color = std.Io.Terminal.Color;

/// SGR parameter string for a color, used when ANSI escape codes are active.
fn sgr(color: Color) []const u8 {
    return switch (color) {
        .black => "\x1b[30m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
        .bright_black => "\x1b[90m",
        .bright_red => "\x1b[91m",
        .bright_green => "\x1b[92m",
        .bright_yellow => "\x1b[93m",
        .bright_blue => "\x1b[94m",
        .bright_magenta => "\x1b[95m",
        .bright_cyan => "\x1b[96m",
        .bright_white => "\x1b[97m",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .reset => "\x1b[0m",
    };
}

pub const Ui = struct {
    io: std.Io,
    fw: *std.Io.File.Writer,
    w: *std.Io.Writer,
    mode: std.Io.Terminal.Mode,
    tty: bool,
    progress_active: bool = false,
    last_progress_len: usize = 0,

    pub fn init(io: std.Io, fw: *std.Io.File.Writer, mode: std.Io.Terminal.Mode, tty: bool) Ui {
        return .{ .io = io, .fw = fw, .w = &fw.interface, .mode = mode, .tty = tty };
    }

    pub fn setColor(self: *Ui, color: Color) void {
        switch (self.mode) {
            .no_color => {},
            .escape_codes => self.w.writeAll(sgr(color)) catch {},
            .windows_api => self.term().setColor(color) catch {},
        }
    }

    pub fn print(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        self.w.print(fmt, args) catch {};
        self.w.flush() catch {};
    }

    /// Prints a chunk with one color applied to it, then resets.
    pub fn cprint(self: *Ui, color: Color, comptime fmt: []const u8, args: anytype) void {
        self.setColor(color);
        self.print(fmt, args);
        self.setColor(.reset);
    }

    /// Overwrites the current line in-place; used for the non-verbose
    /// progress indicator. No-op when stdout is not a terminal.
    pub fn progress(self: *Ui, comptime fmt: []const u8, args: anytype) void {
        if (!self.tty) return;
        self.clearLineEscape();
        self.w.writeAll("\r") catch {};
        const before = self.w.buffered().len;
        self.w.print(fmt, args) catch {};
        self.last_progress_len = self.w.buffered().len - before;
        self.w.flush() catch {};
        self.progress_active = true;
    }

    /// Erases the progress line, if one is currently displayed.
    pub fn clearProgress(self: *Ui) void {
        if (!self.progress_active) return;
        self.clearLineEscape();
        if (self.mode != .escape_codes and self.last_progress_len > 0) {
            self.w.splatByteAll(' ', self.last_progress_len) catch {};
            self.w.writeAll("\r") catch {};
        }
        self.w.flush() catch {};
        self.progress_active = false;
        self.last_progress_len = 0;
    }

    fn clearLineEscape(self: *Ui) void {
        if (self.mode == .escape_codes) {
            self.w.writeAll("\x1b[2K") catch {};
        }
    }

    fn term(self: *Ui) std.Io.Terminal {
        return .{ .writer = self.w, .mode = self.mode };
    }
};

fn envFlag(map: *std.process.Environ.Map, key: []const u8) bool {
    const value = map.get(key) orelse return false;
    if (value.len == 0) return false;
    // Follow the CLICOLOR convention: "0" explicitly disables the flag.
    return !std.mem.eql(u8, value, "0");
}

fn envNoColor(map: *std.process.Environ.Map, key: []const u8) bool {
    // NO_COLOR: any non-empty value disables color.
    const value = map.get(key) orelse return false;
    return value.len > 0;
}

/// Creates the stdout writer + UI, detecting terminal color capabilities.
pub fn setupStdout(io: std.Io, buf: []u8, fw_storage: *std.Io.File.Writer, map: *std.process.Environ.Map) !struct { ui: Ui, file: std.Io.File } {
    const file = std.Io.File.stdout();
    fw_storage.* = file.writerStreaming(io, buf);

    const tty = file.isTty(io) catch false;
    const no_color = envNoColor(map, "NO_COLOR");
    const force_color = envFlag(map, "CLICOLOR_FORCE");
    const mode: std.Io.Terminal.Mode = std.Io.Terminal.Mode.detect(io, file, no_color, force_color) catch .no_color;

    return .{ .ui = Ui.init(io, fw_storage, mode, tty), .file = file };
}
