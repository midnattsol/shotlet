//! When each step of opening a capture happened, from the key press (a
//! capture the GNOME integration handed over says when it was pressed)
//! or else from the start of this run, to an editor that takes input.
//! Logged once, as one line, when the editor is ready:
//!
//!     open timeline (ms after the key): shotlet 9, session 10, setup 25,
//!     window 30, capture 228, surfaces 236, first frame 247, on screen 249,
//!     ready 390
//!
//! (tools/e2e: perf-open reads it and checks its bounds.)

const std = @import("std");
const log = std.log.scoped(.capture);
const sys = @import("../../platform/api.zig").sys;

pub const Step = enum {
    /// this run started (the shell spawned it)
    shotlet,
    /// the session bus is connected
    session,
    /// the settings and fonts are loaded
    setup,
    /// the display connection is up
    window,
    /// the capture is decoded and stitched
    capture,
    /// the editor's surfaces are configured
    surfaces,
    /// the capture went out as the first frame of every surface
    first_frame,
    /// the compositor has those frames (the shell's frozen frame goes)
    on_screen,
    /// the editor drew its full frame, toolbar included, on every surface
    ready,
};

pub const Timeline = struct {
    /// the key press, else the start of this run (monotonic ms)
    origin: i64,
    from_key: bool = false,
    at: std.EnumArray(Step, i64) = .initFill(0),

    /// From `key` (the key press, monotonic ms) when known.
    pub fn start(key: ?i64) Timeline {
        const now = sys.monoMs();
        var t: Timeline = .{ .origin = key orelse now, .from_key = key != null };
        t.at.set(.shotlet, now);
        return t;
    }

    /// `s` happened now (the first time only).
    pub fn mark(t: *Timeline, s: Step) void {
        if (t.at.get(s) == 0) t.at.set(s, sys.monoMs());
    }

    /// ms from the origin to `s`; null when it has not happened.
    pub fn since(t: *const Timeline, s: Step) ?i64 {
        const v = t.at.get(s);
        return if (v == 0) null else v - t.origin;
    }

    /// The log line's text into `buf`.
    pub fn format(t: *const Timeline, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print("open timeline (ms after the {s}):", .{if (t.from_key) "key" else "start"}) catch return buf[0..0];
        var first = true;
        for (std.enums.values(Step)) |s| {
            const ms = t.since(s) orelse continue;
            w.print("{s} {s} {d}", .{ if (first) "" else ",", label(s), ms }) catch break;
            first = false;
        }
        return w.buffered();
    }

    pub fn report(t: *const Timeline) void {
        var buf: [320]u8 = undefined;
        log.info("{s}", .{t.format(&buf)});
    }
};

fn label(s: Step) []const u8 {
    return switch (s) {
        .first_frame => "first frame",
        .on_screen => "on screen",
        else => @tagName(s),
    };
}

test "the timeline's line: the steps that happened, from the key" {
    var t: Timeline = .{ .origin = 1000, .from_key = true };
    t.at.set(.shotlet, 1009);
    t.at.set(.capture, 1228);
    t.at.set(.on_screen, 1249);
    var buf: [320]u8 = undefined;
    try std.testing.expectEqualStrings("open timeline (ms after the key): shotlet 9, capture 228, on screen 249", t.format(&buf));
    // a step marks once
    t.mark(.capture);
    try std.testing.expectEqual(@as(?i64, 228), t.since(.capture));
    try std.testing.expectEqual(@as(?i64, null), t.since(.ready));
}
