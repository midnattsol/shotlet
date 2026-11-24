//! How many wheel notches a scrolling capture turns per step, from how
//! far one notch has been seen to move the content.
//!
//! The aim is about half the region per step: enough overlap to line the
//! next frame up, few frames. One notch moves a GTK page 123 logical px,
//! a terminal a few lines (Ghostty: 6 lines, 166 px of a 1.5 monitor),
//! so the count is measured, not assumed. A step that moved less than
//! the notches promised (the end of the page came first) says nothing
//! about a notch: it neither raises the count nor lowers the estimate,
//! else the next step would turn ten notches and jump past what lines
//! up (as it did on Ghostty after the short last step).
//!
//! Stable API:
//!   Pace.clicks            the notches of the next step
//!   Pace.moved(d, h)       a step of `clicks` notches moved d of h rows
//!   Pace.tooFar()          that step lined up nowhere: half as many
//!   Pace.restart()         after Continue past a "didn't move": anew

const std = @import("std");

pub const first_clicks: i32 = 3;
pub const max_clicks: i32 = 10;

pub const Pace = struct {
    clicks: i32 = first_clicks,
    /// rows one notch moved, as last measured on a full step
    per_click: ?u32 = null,

    /// A step of `self.clicks` notches moved the content `d` rows of a
    /// region `h` rows tall: the notches for the next step.
    pub fn moved(self: *Pace, d: u32, h: u32) void {
        const n: u32 = @intCast(@max(1, self.clicks));
        const measured = @max(1, d / n);
        if (self.per_click) |pc| {
            // short of what the notches promised (a quarter off): the end
            // of the content, or a slow repaint; not a notch's size
            if (measured * 4 < pc * 3) return;
        }
        self.per_click = measured;
        const want: i32 = @intCast(h / 2 / measured);
        self.clicks = std.math.clamp(want, 1, max_clicks);
    }

    /// The last step jumped past what lines up: half the notches, and the
    /// estimate no longer trusted that far.
    pub fn tooFar(self: *Pace) void {
        self.clicks = @max(1, @divTrunc(self.clicks, 2));
    }

    pub fn restart(self: *Pace) void {
        self.clicks = first_clicks;
    }
};

const testing = std.testing;

test "the notches aim at half the region from what one notch moved" {
    // Ghostty on a 1.5 monitor: 3 notches moved 499 of 1500 rows
    var p: Pace = .{};
    p.moved(499, 1500);
    try testing.expectEqual(@as(i32, 4), p.clicks);
    // a GTK page: 3 notches of 184.5 px
    var g: Pace = .{};
    g.moved(553, 1383);
    try testing.expectEqual(@as(i32, 3), g.clicks);
    // a page that moves little per notch: at most ten
    var s: Pace = .{};
    s.moved(30, 1500);
    try testing.expectEqual(max_clicks, s.clicks);
}

test "a short last step at the end of the content does not raise the notches" {
    var p: Pace = .{};
    p.moved(499, 1500);
    p.moved(666, 1500);
    try testing.expectEqual(@as(i32, 4), p.clicks);
    // the end came after a third of a step
    p.moved(111, 1500);
    try testing.expectEqual(@as(i32, 4), p.clicks);
    try testing.expectEqual(@as(?u32, 166), p.per_click);
    // never a step longer than the region
    try testing.expect(@as(u32, @intCast(p.clicks)) * p.per_click.? < 1500);
}

test "too far halves; the next full step measures again" {
    var p: Pace = .{ .clicks = 8 };
    p.tooFar();
    try testing.expectEqual(@as(i32, 4), p.clicks);
    p.tooFar();
    p.tooFar();
    p.tooFar();
    try testing.expectEqual(@as(i32, 1), p.clicks);
    p.moved(200, 1000);
    try testing.expectEqual(@as(i32, 2), p.clicks);
    p.restart();
    try testing.expectEqual(first_clicks, p.clicks);
}
