//! One area selection for every picker over the frozen desktop: the
//! editor (ui/editor/), the recording picker (ui/recui/picker.zig) and
//! the scrolling capture's (ui/region_pick.zig); the last two run on
//! ui/freeze_pick.zig. Pure geometry in the capture's image pixels: the
//! callers map the pointer into them, and hit-test the handles where they
//! are drawn (grabAt, in buffer pixels).
//!
//!   drag outside  a new area (Shift: a square, Alt: from its centre,
//!                 Space held: moves it)
//!   drag inside   moves it; a handle resizes it (the corners; an edge's
//!                 middle shows near the pointer, ui/selchrome.zig)
//!   click         the window under the pointer where windows are known
//!                 (the editor's area capture), else its whole monitor
//!   arrows        move it 1 px, Shift 10; after a handle was dragged,
//!                 that handle's edges; Alt: the bottom-right corner
//!   Enter         confirms; with nothing selected, what a click at the
//!                 pointer takes (confirm); Esc cancels (the callers)
//!
//! An area stays on what the mode can capture (Area.one_monitor): the
//! monitor it is mostly on for a recording or a scrolling capture, the
//! whole image in the editor.

const std = @import("std");
const geom = @import("../geom.zig");
const window = @import("../platform/api.zig").window;
const handles = @import("shapes/handles.zig");
const dragCorners = @import("drag.zig").dragCorners;
const selchrome = @import("selchrome.zig");

const Rect = geom.Rect;
const Point = geom.Point;

/// 0..7: corners and edges, clockwise from the top-left
/// (shapes/handles.zig handlePoints)
pub const Handle = u3;

/// Where areas can be: the same for a whole pick.
pub const Area = struct {
    /// everything that can be selected (the image)
    bounds: Rect,
    /// the monitors (image pixels): what a click takes
    monitors: []const Rect = &.{},
    /// the windows, topmost first: what a click takes before a monitor
    windows: []const Rect = &.{},
    /// an area stays on one monitor (what a recording or a scrolling
    /// capture reads)
    one_monitor: bool = false,
    /// a new area smaller than this either way is a click
    min: i32 = 4,

    /// Where an area mostly on `r` may lie.
    pub fn limitOf(self: Area, r: Rect) Rect {
        if (self.one_monitor) if (geom.bestMonitor(r.normalized(), self.monitors)) |i| return self.monitors[i];
        return self.bounds;
    }

    /// Where an area drawn from `p` may lie.
    pub fn limitAt(self: Area, p: Point) Rect {
        const q = inside(p, self.bounds);
        return self.limitOf(.{ .x = q.x, .y = q.y, .w = 1, .h = 1 });
    }

    /// What a click at `p` takes: the window under it, else its monitor,
    /// else everything (no monitor known); null off the image.
    pub fn clickAt(self: Area, p: Point) ?Rect {
        for (self.windows) |w| if (w.contains(p.x, p.y)) return w.intersect(self.limitOf(w));
        for (self.monitors) |m| if (m.contains(p.x, p.y)) return m.intersect(self.bounds);
        return if (self.bounds.contains(p.x, p.y)) self.bounds else null;
    }
};

/// What a press at a point would take hold of.
pub const Grab = union(enum) { handle: Handle, inside, outside };

/// The handle of `sel` (as shown, buffer pixels) within `radius` of `m`,
/// else whether `m` is in it.
pub fn grabAt(sel: ?Rect, m: Point, radius: i32) Grab {
    const s = (sel orelse return .outside).normalized();
    if (handles.handleAt(s, m, radius)) |h| return .{ .handle = h };
    return if (s.contains(m.x, m.y)) .inside else .outside;
}

/// The pointer's shape: what the drag does, else what a press would.
pub fn cursorFor(drag: Drag, g: Grab) window.Cursor {
    return switch (drag) {
        .moving => .grabbing,
        .resizing => |r| selchrome.handleCursor(r.handle),
        .drawing => .crosshair,
        .none => switch (g) {
            .handle => |h| selchrome.handleCursor(h),
            .inside => .grab,
            .outside => .crosshair,
        },
    };
}

/// The modifiers held while drawing an area out.
pub const Mods = struct {
    /// Shift
    square: bool = false,
    /// Alt
    center: bool = false,
    /// Space: the pointer moves the area being drawn
    space: bool = false,

    /// Follow a key event; true when a modifier changed.
    pub fn track(self: *Mods, k: window.Key) bool {
        const was = self.*;
        switch (k.code) {
            .shift_left, .shift_right => self.square = k.pressed,
            .alt_left, .alt_right => self.center = k.pressed,
            .space => self.space = k.pressed,
            else => return false,
        }
        return !std.meta.eql(was, self.*);
    }
};

/// A new area being drawn out from `anchor`, on `limit`.
pub const Drawing = struct {
    anchor: Point,
    limit: Rect,
    /// the pointer while Space is held
    last: ?Point = null,

    /// The area with its corner at `p`.
    pub fn to(self: *Drawing, p: Point, mods: Mods) Rect {
        const q = inside(p, self.limit);
        if (mods.space) {
            if (self.last) |l| {
                self.anchor.x += q.x - l.x;
                self.anchor.y += q.y - l.y;
            }
            self.last = q;
        } else self.last = null;
        const cs = dragCorners(self.anchor, q, mods.square, mods.center);
        return Rect.fromCorners(cs[0], cs[1]).intersect(self.limit) orelse Rect.fromCorners(q, q);
    }
};

/// The area `orig` moved with the pointer from `start`.
pub const Moving = struct {
    orig: Rect,
    start: Point,

    /// Kept on the monitor it is mostly on (or the image).
    pub fn to(self: Moving, p: Point, a: Area) Rect {
        const r: Rect = .{ .x = self.orig.x + p.x - self.start.x, .y = self.orig.y + p.y - self.start.y, .w = self.orig.w, .h = self.orig.h };
        return keepIn(r, a.limitOf(r));
    }
};

/// The area `orig` resized by its handle.
pub const Resizing = struct {
    handle: Handle,
    orig: Rect,

    /// As dragged: past the opposite edge it is flipped (negative size)
    /// until released.
    pub fn to(self: Resizing, p: Point, a: Area) Rect {
        return handles.resizeWithHandle(self.orig, self.handle, inside(p, a.limitOf(self.orig)));
    }
};

pub const Drag = union(enum) {
    none,
    drawing: Drawing,
    moving: Moving,
    resizing: Resizing,
};

/// `p` within `r`, its far edges included.
fn inside(p: Point, r: Rect) Point {
    return .{ .x = std.math.clamp(p.x, r.x, r.right()), .y = std.math.clamp(p.y, r.y, r.bottom()) };
}

/// `r` moved (not resized) to lie on `lim` as far as it fits.
fn keepIn(r: Rect, lim: Rect) Rect {
    return .{
        .x = std.math.clamp(r.x, lim.x, @max(lim.x, lim.right() - r.w)),
        .y = std.math.clamp(r.y, lim.y, @max(lim.y, lim.bottom() - r.h)),
        .w = r.w,
        .h = r.h,
    };
}

/// `s` moved by (`dx`, `dy`), or with `edge` that handle's edges, kept
/// on where it may lie and at least 1x1.
pub fn nudged(s: Rect, edge: ?Handle, dx: i32, dy: i32, a: Area) Rect {
    const n = s.normalized();
    const lim = a.limitOf(n);
    if (edge) |h| return handles.nudgeHandle(n, h, dx, dy, lim);
    return keepIn(.{ .x = n.x + dx, .y = n.y + dy, .w = n.w, .h = n.h }, lim);
}

/// An area and the gesture on it.
pub const Selection = struct {
    /// as dragged: a resize may flip it until released (rect() is
    /// normalized)
    sel: ?Rect = null,
    drag: Drag = .none,
    /// the handle last dragged: arrows move its edges
    edge: ?Handle = null,
    area: Area,
    mods: Mods = .{},
    /// the pointer, last seen (to apply a modifier at once)
    at: Point = .{ .x = 0, .y = 0 },

    pub fn rect(self: *const Selection) ?Rect {
        return if (self.sel) |s| s.normalized() else null;
    }

    /// A press at `p`, on what `g` says lies there.
    pub fn press(self: *Selection, p: Point, g: Grab) void {
        self.at = p;
        if (self.rect()) |r| switch (g) {
            .handle => |h| {
                self.drag = .{ .resizing = .{ .handle = h, .orig = r } };
                self.edge = h;
                return;
            },
            .inside => {
                self.drag = .{ .moving = .{ .orig = r, .start = p } };
                self.edge = null;
                return;
            },
            .outside => {},
        };
        self.edge = null;
        const lim = self.area.limitAt(p);
        const a = inside(p, lim);
        self.drag = .{ .drawing = .{ .anchor = a, .limit = lim } };
        self.sel = .{ .x = a.x, .y = a.y, .w = 0, .h = 0 };
    }

    pub fn motion(self: *Selection, p: Point) void {
        self.at = p;
        switch (self.drag) {
            .none => {},
            .drawing => |*d| self.sel = d.to(p, self.mods),
            .moving => |m| self.sel = m.to(p, self.area),
            .resizing => |r| self.sel = r.to(p, self.area),
        }
    }

    /// A press that has not moved enough to draw an area (yet).
    pub fn clickPending(self: *const Selection) bool {
        if (self.drag != .drawing) return false;
        const s = self.rect() orelse return true;
        return s.w < self.area.min or s.h < self.area.min;
    }

    /// The drag ends: a click takes what clickAt says, a drawn or changed
    /// area is normalized onto where it may lie.
    pub fn release(self: *Selection) void {
        const d = self.drag;
        const click = self.clickPending();
        self.drag = .none;
        switch (d) {
            .none => {},
            .drawing => |dr| self.sel = if (click) self.area.clickAt(dr.anchor) else self.rect(),
            .moving, .resizing => {
                const s = self.sel orelse return;
                if (self.edge) |h| self.edge = handles.normalizedHandle(s, h);
                self.sel = s.normalized().intersect(self.area.limitOf(s));
            },
        }
    }

    /// Abandon the drag: a moved or resized area goes back, a new one
    /// goes.
    pub fn cancel(self: *Selection) void {
        switch (self.drag) {
            .none => return,
            .drawing => self.sel = null,
            .moving => |m| self.sel = m.orig,
            .resizing => |r| self.sel = r.orig,
        }
        self.drag = .none;
    }

    /// An arrow key (no drag): the area nudged. True when it took the key.
    pub fn arrow(self: *Selection, k: window.Key) bool {
        const step: i32 = if (k.shift) 10 else 1;
        const d: [2]i32 = switch (k.code) {
            .left => .{ -step, 0 },
            .right => .{ step, 0 },
            .up => .{ 0, -step },
            .down => .{ 0, step },
            else => return false,
        };
        if (self.drag != .none) return true;
        const s = self.sel orelse return true;
        self.sel = nudged(s, self.nudgeEdge(k), d[0], d[1], self.area);
        return true;
    }

    /// The edge an arrow `k` moves: Alt the bottom-right corner, else
    /// the handle last dragged; null for the whole area.
    pub fn nudgeEdge(self: *const Selection, k: window.Key) ?Handle {
        return if (k.alt) 4 else self.edge;
    }

    /// A key press or release for the area (modifiers, arrows). True when
    /// the area may have changed.
    pub fn key(self: *Selection, k: window.Key) bool {
        if (self.mods.track(k)) {
            if (self.drag == .drawing) self.motion(self.at);
            return true;
        }
        return k.pressed and self.arrow(k);
    }

    /// Enter: the area, or with none what a click at `p` takes.
    pub fn confirm(self: *const Selection, p: Point) ?Rect {
        return self.rect() orelse self.area.clickAt(p);
    }
};

// --- tests: every gesture, monitor edges, several monitors

const testing = std.testing;
/// two monitors side by side, the second smaller and lower
const two = [_]Rect{ .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, .{ .x = 1600, .y = 100, .w = 1280, .h = 720 } };
const image: Rect = .{ .x = 0, .y = 0, .w = 2880, .h = 900 };

fn key(code: window.KeyCode, pressed: bool, shift: bool, alt: bool) window.Key {
    return .{ .code = code, .pressed = pressed, .ctrl = false, .shift = shift, .alt = alt };
}

fn dragFrom(s: *Selection, a: Point, b: Point, g: Grab) void {
    s.press(a, g);
    s.motion(.{ .x = @divTrunc(a.x + b.x, 2), .y = @divTrunc(a.y + b.y, 2) });
    s.motion(b);
    s.release();
}

test "drag out, either way; a click takes the monitor" {
    var s: Selection = .{ .area = .{ .bounds = image, .monitors = &two } };
    dragFrom(&s, .{ .x = 500, .y = 400 }, .{ .x = 100, .y = 100 }, .outside);
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    try testing.expect(s.drag == .none);
    // a press elsewhere starts anew; not moving is a click
    s.press(.{ .x = 2000, .y = 300 }, .outside);
    try testing.expect(s.clickPending());
    s.motion(.{ .x = 2002, .y = 301 });
    s.release();
    try testing.expectEqual(two[1], s.sel.?);
    // below the second monitor (outside every one): everything
    s.press(.{ .x = 2000, .y = 850 }, .outside);
    s.release();
    try testing.expectEqual(image, s.sel.?);
    try testing.expectEqual(@as(?Rect, null), s.area.clickAt(.{ .x = -5, .y = 10 }));
}

test "a click takes the window under it first" {
    const wins = [_]Rect{ .{ .x = 100, .y = 100, .w = 300, .h = 200 }, .{ .x = 0, .y = 0, .w = 1000, .h = 800 } };
    var s: Selection = .{ .area = .{ .bounds = image, .monitors = &two, .windows = &wins } };
    s.press(.{ .x = 150, .y = 150 }, .outside);
    s.release();
    try testing.expectEqual(wins[0], s.sel.?);
    s.sel = null;
    try testing.expectEqual(wins[1], s.confirm(.{ .x = 900, .y = 700 }).?);
    // a drag still draws an area
    dragFrom(&s, .{ .x = 150, .y = 150 }, .{ .x = 450, .y = 350 }, .outside);
    try testing.expectEqual(Rect{ .x = 150, .y = 150, .w = 300, .h = 200 }, s.sel.?);
}

test "modifiers: Shift a square, Alt from the centre, Space moves it" {
    var s: Selection = .{ .area = .{ .bounds = image } };
    _ = s.key(key(.shift_left, true, true, false));
    dragFrom(&s, .{ .x = 100, .y = 100 }, .{ .x = 300, .y = 150 }, .outside);
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 200, .h = 200 }, s.sel.?);
    _ = s.key(key(.shift_left, false, false, false));
    s.mods.center = true;
    dragFrom(&s, .{ .x = 500, .y = 500 }, .{ .x = 600, .y = 550 }, .outside);
    try testing.expectEqual(Rect{ .x = 400, .y = 450, .w = 200, .h = 100 }, s.sel.?);
    s.mods.center = false;
    // Space held halfway: the area moves with the pointer
    s.press(.{ .x = 100, .y = 100 }, .outside);
    s.motion(.{ .x = 200, .y = 200 });
    _ = s.key(key(.space, true, false, false));
    s.motion(.{ .x = 250, .y = 220 });
    _ = s.key(key(.space, false, false, false));
    s.motion(.{ .x = 300, .y = 220 });
    s.release();
    try testing.expectEqual(Rect{ .x = 150, .y = 120, .w = 150, .h = 100 }, s.sel.?);
    // a modifier pressed mid-drag applies at once
    s.press(.{ .x = 100, .y = 100 }, .outside);
    s.motion(.{ .x = 300, .y = 150 });
    try testing.expect(s.key(key(.shift_right, true, true, false)));
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 200, .h = 200 }, s.sel.?);
}

test "move inside, kept on its monitor; past half it goes to the next" {
    var s: Selection = .{ .sel = .{ .x = 100, .y = 100, .w = 400, .h = 300 }, .area = .{ .bounds = image, .monitors = &two, .one_monitor = true } };
    dragFrom(&s, .{ .x = 200, .y = 200 }, .{ .x = 0, .y = 200 }, .inside);
    try testing.expectEqual(Rect{ .x = 0, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    // to the right edge of the first monitor: stops there
    dragFrom(&s, .{ .x = 200, .y = 200 }, .{ .x = 1500, .y = 200 }, .inside);
    try testing.expectEqual(Rect{ .x = 1200, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    // mostly over the second: onto it, below its top edge
    dragFrom(&s, .{ .x = 1300, .y = 200 }, .{ .x = 1700, .y = 150 }, .inside);
    try testing.expectEqual(Rect{ .x = 1600, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    // the editor's area spans monitors: only the image stops it
    s.area.one_monitor = false;
    s.sel = .{ .x = 1200, .y = 100, .w = 400, .h = 300 };
    dragFrom(&s, .{ .x = 1300, .y = 200 }, .{ .x = 1500, .y = -100 }, .inside);
    try testing.expectEqual(Rect{ .x = 1400, .y = 0, .w = 400, .h = 300 }, s.sel.?);
}

test "resize by every handle, flipping over, kept on the monitor" {
    const r0: Rect = .{ .x = 100, .y = 100, .w = 400, .h = 300 };
    const want = [8]Rect{
        .{ .x = 90, .y = 80, .w = 410, .h = 320 }, // nw
        .{ .x = 100, .y = 80, .w = 400, .h = 320 }, // n
        .{ .x = 100, .y = 80, .w = 410, .h = 320 }, // ne
        .{ .x = 100, .y = 100, .w = 410, .h = 300 }, // e
        .{ .x = 100, .y = 100, .w = 410, .h = 320 }, // se
        .{ .x = 100, .y = 100, .w = 400, .h = 320 }, // s
        .{ .x = 90, .y = 100, .w = 410, .h = 320 }, // sw
        .{ .x = 90, .y = 100, .w = 410, .h = 300 }, // w
    };
    for (want, 0..) |w, i| {
        var s: Selection = .{ .sel = r0, .area = .{ .bounds = image } };
        const h: Handle = @intCast(i);
        const p = handles.handlePoints(r0)[h];
        const out: Point = .{ .x = p.x + @as(i32, if (p.x == r0.x) -10 else if (p.x == r0.right()) 10 else 0), .y = p.y + @as(i32, if (p.y == r0.y) -20 else if (p.y == r0.bottom()) 20 else 0) };
        dragFrom(&s, p, out, .{ .handle = h });
        try testing.expectEqual(w, s.sel.?);
        try testing.expectEqual(@as(?Handle, h), s.edge);
    }
    // the east handle past the west edge: flipped, then normalized, and
    // the edge it moves is the west one now
    var s: Selection = .{ .sel = r0, .area = .{ .bounds = image } };
    s.press(.{ .x = 500, .y = 250 }, .{ .handle = 3 });
    s.motion(.{ .x = 50, .y = 250 });
    try testing.expect(s.sel.?.w < 0);
    s.release();
    try testing.expectEqual(Rect{ .x = 50, .y = 100, .w = 50, .h = 300 }, s.sel.?);
    try testing.expectEqual(@as(?Handle, 7), s.edge);
    // on one monitor the handle stops at its edge
    s = .{ .sel = r0, .area = .{ .bounds = image, .monitors = &two, .one_monitor = true } };
    dragFrom(&s, .{ .x = 500, .y = 400 }, .{ .x = 2000, .y = 2000 }, .{ .handle = 4 });
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 1500, .h = 800 }, s.sel.?);
}

test "a new area stays on the monitor it starts on, up to its edges" {
    var s: Selection = .{ .area = .{ .bounds = image, .monitors = &two, .one_monitor = true } };
    dragFrom(&s, .{ .x = 1400, .y = 700 }, .{ .x = 2200, .y = 1000 }, .outside);
    try testing.expectEqual(Rect{ .x = 1400, .y = 700, .w = 200, .h = 200 }, s.sel.?);
    // from the second monitor up past its top: its top edge
    dragFrom(&s, .{ .x = 2000, .y = 300 }, .{ .x = 2100, .y = 0 }, .outside);
    try testing.expectEqual(Rect{ .x = 2000, .y = 100, .w = 100, .h = 200 }, s.sel.?);
    // the editor's spans the seam, inside the image
    s.area.one_monitor = false;
    dragFrom(&s, .{ .x = 1400, .y = 700 }, .{ .x = 2200, .y = 1000 }, .outside);
    try testing.expectEqual(Rect{ .x = 1400, .y = 700, .w = 800, .h = 200 }, s.sel.?);
    // a press beyond the image starts on its edge
    dragFrom(&s, .{ .x = -50, .y = -50 }, .{ .x = 100, .y = 80 }, .outside);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 80 }, s.sel.?);
}

test "arrows nudge it, Shift by 10, Alt resizes, after a handle its edge" {
    var s: Selection = .{ .sel = .{ .x = 100, .y = 100, .w = 400, .h = 300 }, .area = .{ .bounds = image, .monitors = &two, .one_monitor = true } };
    try testing.expect(s.key(key(.right, true, false, false)));
    try testing.expectEqual(Rect{ .x = 101, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    _ = s.key(key(.up, true, true, false));
    try testing.expectEqual(Rect{ .x = 101, .y = 90, .w = 400, .h = 300 }, s.sel.?);
    _ = s.key(key(.right, true, false, true));
    _ = s.key(key(.down, true, true, true));
    try testing.expectEqual(Rect{ .x = 101, .y = 90, .w = 401, .h = 310 }, s.sel.?);
    // never off its monitor
    for (0..30) |_| _ = s.key(key(.up, true, true, false));
    try testing.expectEqual(@as(i32, 0), s.sel.?.y);
    // after dragging the west handle, arrows move the west edge
    dragFrom(&s, .{ .x = 101, .y = 150 }, .{ .x = 120, .y = 150 }, .{ .handle = 7 });
    _ = s.key(key(.left, true, false, false));
    try testing.expectEqual(Rect{ .x = 119, .y = 0, .w = 383, .h = 310 }, s.sel.?);
    // a move clears it; other keys are not the area's
    dragFrom(&s, .{ .x = 300, .y = 150 }, .{ .x = 301, .y = 150 }, .inside);
    try testing.expectEqual(@as(?Handle, null), s.edge);
    try testing.expect(!s.key(key(.enter, true, false, false)));
    var none: Selection = .{ .area = .{ .bounds = image } };
    try testing.expect(none.key(key(.left, true, false, false)) and none.sel == null);
}

test "cancel puts the area back; Enter takes the area or the monitor" {
    var s: Selection = .{ .sel = .{ .x = 100, .y = 100, .w = 400, .h = 300 }, .area = .{ .bounds = image, .monitors = &two } };
    s.press(.{ .x = 200, .y = 200 }, .inside);
    s.motion(.{ .x = 600, .y = 200 });
    s.cancel();
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 400, .h = 300 }, s.sel.?);
    try testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 400, .h = 300 }, s.confirm(.{ .x = 2000, .y = 300 }).?);
    s.press(.{ .x = 900, .y = 800 }, .outside);
    s.cancel();
    try testing.expectEqual(@as(?Rect, null), s.sel);
    try testing.expectEqual(two[1], s.confirm(.{ .x = 2000, .y = 300 }).?);
}

test "grabbing: handles, inside, outside, and their cursors" {
    const r: Rect = .{ .x = 100, .y = 100, .w = 400, .h = 300 };
    try testing.expectEqual(Grab{ .handle = 4 }, grabAt(r, .{ .x = 505, .y = 398 }, 10));
    try testing.expectEqual(Grab.inside, grabAt(r, .{ .x = 300, .y = 250 }, 10));
    try testing.expectEqual(Grab.outside, grabAt(r, .{ .x = 50, .y = 50 }, 10));
    try testing.expectEqual(Grab.outside, grabAt(null, .{ .x = 300, .y = 250 }, 10));
    try testing.expectEqual(window.Cursor.resize_nwse, cursorFor(.none, .{ .handle = 4 }));
    try testing.expectEqual(window.Cursor.grab, cursorFor(.none, .inside));
    try testing.expectEqual(window.Cursor.grabbing, cursorFor(.{ .moving = .{ .orig = r, .start = .{ .x = 0, .y = 0 } } }, .outside));
    try testing.expectEqual(window.Cursor.crosshair, cursorFor(.none, .outside));
}
