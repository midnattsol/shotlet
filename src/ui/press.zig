//! Clicks, one rule for every window: a click activates on release over
//! the same target it was pressed on; releasing anywhere else cancels it.
//! Plus hit-testing a list of targets and the drag threshold that turns a
//! press into a drag.
//!
//! Stable API:
//!   Press(T)                    the pressed target (any T std.meta.eql
//!                               compares: enum, union, struct)
//!     .down(hit, x, y)          a press over `hit` (null: over nothing)
//!     .up(hit) ?T               the release: the target to activate when
//!                               `hit` is the pressed one, else null
//!     .held() ?T, .cancel()     the target held down; forget it (a drag)
//!     .dragged(x, y, k) bool    moved past drag_threshold since the press
//!   drag_threshold              logical px a press moves before it drags
//!   Target(T), hitTest(T, targets, x, y) ?T   the first target containing
//!                               the point (list the top-most first)

const std = @import("std");
const Rect = @import("shapes.zig").Rect;

/// How far (logical px) a pressed pointer moves before it is a drag.
pub const drag_threshold: f64 = 6;

pub fn Press(comptime T: type) type {
    return struct {
        const Self = @This();

        target: ?T = null,
        /// where the press was, in the caller's (physical) coordinates
        x: f64 = 0,
        y: f64 = 0,

        /// A press over `hit` at x, y.
        pub fn down(self: *Self, hit: ?T, x: f64, y: f64) void {
            self.* = .{ .target = hit, .x = x, .y = y };
        }

        /// The release over `hit`: the pressed target when it is the same
        /// one (a click), else null (cancelled). Forgets the press.
        pub fn up(self: *Self, hit: ?T) ?T {
            const t = self.target orelse return null;
            self.target = null;
            const h = hit orelse return null;
            return if (std.meta.eql(t, h)) t else null;
        }

        /// The target held down, if any.
        pub fn held(self: Self) ?T {
            return self.target;
        }

        /// Forget the press (it became a drag, or the window lost the
        /// pointer): its release activates nothing.
        pub fn cancel(self: *Self) void {
            self.target = null;
        }

        /// Whether the pointer, now at x, y (same coordinates as the
        /// press, `k` physical px per logical px), moved past the drag
        /// threshold while a target is held.
        pub fn dragged(self: Self, x: f64, y: f64, k: f64) bool {
            if (self.target == null) return false;
            const dx = (x - self.x) / k;
            const dy = (y - self.y) / k;
            return dx * dx + dy * dy > drag_threshold * drag_threshold;
        }
    };
}

/// A hit-test target: what a rect stands for.
pub fn Target(comptime T: type) type {
    return struct { r: Rect, t: T };
}

/// The first of `targets` whose rect contains (x, y): list the top-most
/// first.
pub fn hitTest(comptime T: type, targets: []const Target(T), x: i32, y: i32) ?T {
    for (targets) |tg| if (tg.r.contains(x, y)) return tg.t;
    return null;
}

const testing = std.testing;
const Btn = enum { close, copy, body };

test "a click is a press and a release on the same target" {
    var p: Press(Btn) = .{};
    p.down(.copy, 10, 10);
    try testing.expectEqual(@as(?Btn, .copy), p.held());
    try testing.expectEqual(@as(?Btn, .copy), p.up(.copy));
    // the press is spent
    try testing.expectEqual(@as(?Btn, null), p.up(.copy));
}

test "releasing elsewhere cancels" {
    var p: Press(Btn) = .{};
    p.down(.copy, 10, 10);
    try testing.expectEqual(@as(?Btn, null), p.up(.close));
    p.down(.copy, 10, 10);
    try testing.expectEqual(@as(?Btn, null), p.up(null));
    // a press over nothing activates nothing
    p.down(null, 0, 0);
    try testing.expectEqual(@as(?Btn, null), p.up(.copy));
    // a cancelled press (a drag) neither
    p.down(.body, 0, 0);
    p.cancel();
    try testing.expectEqual(@as(?Btn, null), p.up(.body));
}

test "targets with payloads compare by value" {
    const Hit = union(enum) { row: usize, close };
    var p: Press(Hit) = .{};
    p.down(.{ .row = 2 }, 0, 0);
    try testing.expectEqual(@as(?Hit, null), p.up(.{ .row = 3 }));
    p.down(.{ .row = 2 }, 0, 0);
    try testing.expect(std.meta.eql(p.up(.{ .row = 2 }).?, Hit{ .row = 2 }));
}

test "a press drags once it moves past the threshold, in logical px" {
    var p: Press(Btn) = .{};
    try testing.expect(!p.dragged(100, 100, 1));
    p.down(.body, 100, 100);
    try testing.expect(!p.dragged(106, 100, 1)); // exactly 6: not yet
    try testing.expect(p.dragged(105, 105, 1));
    // at 2x, 10 physical px is 5 logical
    try testing.expect(!p.dragged(110, 100, 2));
    try testing.expect(p.dragged(113, 100, 2));
}

test "hitTest finds the first target containing the point" {
    const ts = [_]Target(Btn){
        .{ .r = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .t = .close },
        .{ .r = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .t = .body },
    };
    try testing.expectEqual(@as(?Btn, .close), hitTest(Btn, &ts, 5, 5));
    try testing.expectEqual(@as(?Btn, .body), hitTest(Btn, &ts, 50, 5));
    try testing.expectEqual(@as(?Btn, null), hitTest(Btn, &ts, 100, 5));
}
