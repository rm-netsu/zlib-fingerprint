//! Terminal output: colored analysis blocks and a live progress line.
//!
//! Colors are emitted as raw SGR sequences (Zig 0.16.0's Terminal.setColor
//! escape-mode emits a bare ESC, so we bypass it entirely). Color detection
//! still respects NO_COLOR / CLICOLOR_FORCE conventions.

const std = @import("std");

pub const ANSI = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const clear_line = "\r\x1b[2K";
};

/// Progress sink used by the search engine.
pub const Reporter = struct {
    w: *std.Io.Writer,
    color: bool,
    tty: bool,
    verbose: bool,

    stage_label: []const u8 = "",
    attempts: usize = 0,
    last_paint_attempt: usize = 0,
    last_desc_buf: [96]u8 = undefined,
    last_desc: []const u8 = "",
    painted: bool = false,

    pub fn init(w: *std.Io.Writer, color: bool, tty: bool, verbose: bool) Reporter {
        return .{ .w = w, .color = color, .tty = tty, .verbose = verbose };
    }

    fn paintBegin(self: *Reporter, code: []const u8) void {
        if (self.color) self.w.writeAll(code) catch {};
    }

    fn paintEnd(self: *Reporter) void {
        if (self.color) self.w.writeAll(ANSI.reset) catch {};
    }

    pub fn line(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        self.clearProgress();
        self.w.print(fmt ++ "\n", args) catch {};
        self.w.flush() catch {};
    }

    pub fn note(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        self.clearProgress();
        self.paintBegin(ANSI.yellow);
        self.w.print("note: " ++ fmt ++ "\n", args) catch {};
        self.paintEnd();
        self.w.flush() catch {};
    }

    /// Called when a stage begins executing its candidate list.
    pub fn stageStart(self: *Reporter, label: []const u8, count: usize) void {
        self.stage_label = label;
        self.attempts = 0;
        self.painted = false;
        self.clearProgress();
        self.paintBegin(ANSI.cyan ++ ANSI.bold);
        self.w.print("==> {s}", .{label}) catch {};
        self.paintEnd();
        self.w.print(" ({d} candidate{s})\n", .{ count, if (count == 1) "" else "s" }) catch {};
        self.w.flush() catch {};
    }

    /// Called for every candidate that is actually executed.
    pub fn attempt(self: *Reporter, desc: []const u8, matched: bool) void {
        self.attempts += 1;
        const n = @min(desc.len, self.last_desc_buf.len);
        @memcpy(self.last_desc_buf[0..n], desc[0..n]);
        self.last_desc = self.last_desc_buf[0..n];

        if (self.verbose) {
            self.paintBegin(ANSI.dim);
            self.w.print("  [attempt {d: >5}] ", .{self.attempts}) catch {};
            self.paintEnd();
            self.w.writeAll(desc) catch {};
            self.w.writeAll(" -> ") catch {};
            if (matched) {
                self.paintBegin(ANSI.green ++ ANSI.bold);
                self.w.writeAll("MATCH") catch {};
                self.paintEnd();
            } else {
                self.paintBegin(ANSI.dim);
                self.w.writeAll("mismatch") catch {};
                self.paintEnd();
            }
            self.w.writeAll("\n") catch {};
            self.w.flush() catch {};
            return;
        }

        if (self.tty) {
            const repaint_due = self.attempts - self.last_paint_attempt >= 10;
            if (repaint_due or matched) {
                self.last_paint_attempt = self.attempts;
                self.repaint();
            }
        }
    }

    fn repaint(self: *Reporter) void {
        self.w.writeAll(ANSI.clear_line) catch {};
        self.paintBegin(ANSI.dim);
        self.w.print("    running | {d} attempt{s} | {s}", .{
            self.attempts,
            if (self.attempts == 1) "" else "s",
            self.last_desc,
        }) catch {};
        self.paintEnd();
        self.w.flush() catch {};
        self.painted = true;
    }

    /// Clears the live progress line, if any.
    pub fn clearProgress(self: *Reporter) void {
        if (self.painted) {
            self.w.writeAll(ANSI.clear_line) catch {};
            self.painted = false;
        }
    }

    /// Called when a stage finished without a match.
    pub fn stageDone(self: *Reporter, label: []const u8) void {
        self.clearProgress();
        self.paintBegin(ANSI.dim);
        self.w.print("    {s}: {d} attempt{s}, no match\n", .{
            label,
            self.attempts,
            if (self.attempts == 1) "" else "s",
        }) catch {};
        self.paintEnd();
        self.w.flush() catch {};
    }
};
