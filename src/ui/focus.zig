//! Keyboard focus, one way for every window: the keys that move focus,
//! press the focused control and close, and cycling through the
//! focusable controls with wrap-around.
//!
//! Stable API:
//!   Dir, cycle(n, cur, dir) ?usize    the next (or previous) of n focusable
//!                                     controls after `cur`, wrapping; null
//!                                     when there are none
//!   Action, Arrows, action(key, arrows) ?Action
//!                                     what a key press does to focus:
//!                                     Tab / Shift+Tab, the arrows the
//!                                     window lets move focus, Enter /
//!                                     Space, Escape

const std = @import("std");
const window = @import("../platform/api.zig").window;

pub const Dir = enum { next, prev };

/// The control after (`.next`) or before (`.prev`) `cur` among `n`,
/// wrapping around; with nothing focused, the first (or the last).
pub fn cycle(n: usize, cur: ?usize, dir: Dir) ?usize {
    if (n == 0) return null;
    const c = cur orelse return if (dir == .next) 0 else n - 1;
    if (c >= n) return if (dir == .next) 0 else n - 1;
    return if (dir == .next) (c + 1) % n else (c + n - 1) % n;
}

pub const Action = enum { next, prev, activate, close };

/// Which arrow keys move focus: none where arrows do something else (the
/// editor moves shapes), left/right in a row of controls, all four in a
/// form.
pub const Arrows = enum { none, horizontal, all };

/// What the key press `k` does to focus; null for keys focus ignores
/// (releases, and keys with Ctrl or Alt held).
pub fn action(k: window.Key, arrows: Arrows) ?Action {
    if (!k.pressed or k.ctrl or k.alt) return null;
    return switch (k.code) {
        .tab => if (k.shift) .prev else .next,
        .enter, .kp_enter, .space => .activate,
        .escape => .close,
        .right => if (arrows != .none) .next else null,
        .left => if (arrows != .none) .prev else null,
        .down => if (arrows == .all) .next else null,
        .up => if (arrows == .all) .prev else null,
        else => null,
    };
}

const testing = std.testing;

test "focus cycles and wraps both ways" {
    try testing.expectEqual(@as(?usize, null), cycle(0, null, .next));
    try testing.expectEqual(@as(?usize, 0), cycle(3, null, .next));
    try testing.expectEqual(@as(?usize, 2), cycle(3, null, .prev));
    try testing.expectEqual(@as(?usize, 1), cycle(3, 0, .next));
    try testing.expectEqual(@as(?usize, 0), cycle(3, 2, .next));
    try testing.expectEqual(@as(?usize, 2), cycle(3, 0, .prev));
    // a focus that no longer exists starts over
    try testing.expectEqual(@as(?usize, 0), cycle(3, 9, .next));
    try testing.expectEqual(@as(?usize, 0), cycle(1, 0, .next));
}

fn key(code: window.KeyCode, shift: bool) window.Key {
    return .{ .code = code, .pressed = true, .ctrl = false, .shift = shift };
}

test "one key map: tab, arrows as the window allows, enter, escape" {
    try testing.expectEqual(@as(?Action, .next), action(key(.tab, false), .none));
    try testing.expectEqual(@as(?Action, .prev), action(key(.tab, true), .none));
    try testing.expectEqual(@as(?Action, null), action(key(.right, false), .none));
    try testing.expectEqual(@as(?Action, .next), action(key(.right, false), .horizontal));
    try testing.expectEqual(@as(?Action, .prev), action(key(.left, false), .horizontal));
    try testing.expectEqual(@as(?Action, null), action(key(.down, false), .horizontal));
    try testing.expectEqual(@as(?Action, .next), action(key(.down, false), .all));
    try testing.expectEqual(@as(?Action, .prev), action(key(.up, false), .all));
    try testing.expectEqual(@as(?Action, .activate), action(key(.enter, false), .none));
    try testing.expectEqual(@as(?Action, .activate), action(key(.space, false), .none));
    try testing.expectEqual(@as(?Action, .close), action(key(.escape, false), .none));
    var released = key(.tab, false);
    released.pressed = false;
    try testing.expectEqual(@as(?Action, null), action(released, .all));
    var ctrl = key(.tab, false);
    ctrl.ctrl = true;
    try testing.expectEqual(@as(?Action, null), action(ctrl, .all));
}
