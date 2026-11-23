//! Integer geometry for the whole program, core and backend alike: one
//! point, one rectangle, a captured monitor, and the conversions between
//! the compositor's logical layout and a capture's image pixels.
//!
//! Conventions:
//! - `Point` and `Rect` are i32. A Rect is size-based (x, y, w, h): its
//!   edges are `x`, `y`, `right()` and `bottom()` (exclusive); one built
//!   from edges goes through `Rect.fromEdges` (or `fromCorners`).
//! - Logical: the compositor's layout (window frames, the pointer, the
//!   recorded area). Image (physical): a capture's pixels, each monitor
//!   at its own scale (`Monitor`). Buffer and image sizes are u32
//!   width/height (`Rect.ofSize` turns one into a Rect).
//! - A surface's own logical-to-physical scale (scale120) is ui/scale.zig;
//!   `physicalToLogical` takes a backend's physical rect back.

const std = @import("std");

pub const Point = struct { x: i32, y: i32 };

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub const empty: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    /// The rect between edges `x0`..`x1` and `y0`..`y1`.
    pub fn fromEdges(x0: i32, y0: i32, x1: i32, y1: i32) Rect {
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    /// The rect with corners `a` and `b`, either way round.
    pub fn fromCorners(a: Point, b: Point) Rect {
        return fromEdges(a.x, a.y, b.x, b.y).normalized();
    }
    /// A `w` x `h` buffer or image at the origin.
    pub fn ofSize(w: u32, h: u32) Rect {
        return .{ .x = 0, .y = 0, .w = dim(w), .h = dim(h) };
    }
    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }
    pub fn center(self: Rect) Point {
        return .{ .x = self.x + @divTrunc(self.w, 2), .y = self.y + @divTrunc(self.h, 2) };
    }
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and py >= self.y and px < self.x + self.w and py < self.y + self.h;
    }
    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
    pub fn area(self: Rect) i64 {
        return @as(i64, self.w) * self.h;
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }
    pub fn array(self: Rect) [4]i32 {
        return .{ self.x, self.y, self.w, self.h };
    }
    /// Negative sizes flipped: the same area, growing right and down.
    pub fn normalized(self: Rect) Rect {
        var r = self;
        if (r.w < 0) {
            r.x += r.w;
            r.w = -r.w;
        }
        if (r.h < 0) {
            r.y += r.h;
            r.h = -r.h;
        }
        return r;
    }
    pub fn expand(self: Rect, d: i32) Rect {
        return .{ .x = self.x - d, .y = self.y - d, .w = self.w + 2 * d, .h = self.h + 2 * d };
    }
    /// The overlap, null when they do not meet.
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.right(), b.right());
        const y1 = @min(a.bottom(), b.bottom());
        if (x1 <= x0 or y1 <= y0) return null;
        return fromEdges(x0, y0, x1, y1);
    }
    /// Bounding box of both; an empty rect is ignored.
    pub fn unite(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return fromEdges(@min(a.x, b.x), @min(a.y, b.y), @max(a.right(), b.right()), @max(a.bottom(), b.bottom()));
    }
    /// Clipped to a `w` x `h` buffer (saturating, for any coordinates);
    /// null when nothing is left.
    pub fn clip(r: Rect, w: u32, h: u32) ?Rect {
        if (r.w <= 0 or r.h <= 0) return null;
        const x0 = @max(r.x, 0);
        const y0 = @max(r.y, 0);
        const x1 = @min(r.x +| r.w, dim(w));
        const y1 = @min(r.y +| r.h, dim(h));
        if (x1 <= x0 or y1 <= y0) return null;
        return fromEdges(x0, y0, x1, y1);
    }
};

/// A buffer dimension as i32, saturating.
pub fn dim(v: u32) i32 {
    return @intCast(@min(v, std.math.maxInt(i32)));
}

/// One captured monitor: where its pixels lie in the capture's image,
/// and where it is in the compositor's logical layout.
pub const Monitor = struct {
    /// pixel rectangle of this monitor inside the capture's image
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// the monitor in the compositor's logical layout, as the ScreenCast
    /// portal reports it (stream `position` and `size`); null when unknown,
    /// as with --from or the Screenshot portal
    logical: ?Rect = null,

    /// The monitor's pixels in the capture's image.
    pub fn pixelRect(m: Monitor) Rect {
        return .{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) };
    }
};

/// The monitor holding the logical point; with an unknown layout, the
/// first monitor.
pub fn monitorAt(mons: []const Monitor, p: ?[2]i32) usize {
    const pt = p orelse return 0;
    for (mons, 0..) |m, i| if (m.logical) |l| if (l.contains(pt[0], pt[1])) return i;
    return 0;
}

/// The bounding box of the monitors' logical rects (1x1 at the origin
/// when none is known).
pub fn layoutBounds(mons: []const Monitor) Rect {
    var box: ?Rect = null;
    for (mons) |m| if (m.logical) |l| {
        box = if (box) |b| Rect.fromEdges(@min(b.x, l.x), @min(b.y, l.y), @max(b.right(), l.right()), @max(b.bottom(), l.bottom())) else l;
    };
    const b = box orelse return .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    return if (b.w <= 0) .{ .x = 0, .y = 0, .w = 1, .h = 1 } else b;
}

fn scaleOf(m: Monitor, l: Rect) f64 {
    return @as(f64, @floatFromInt(m.w)) / @as(f64, @floatFromInt(@max(1, l.w)));
}

fn round(v: f64) i32 {
    return @intFromFloat(@round(v));
}

/// A logical rectangle (a window's frame) in image pixels, through the
/// monitor holding its centre, clipped to that monitor.
pub fn logicalToImage(mons: []const Monitor, r: Rect) ?Rect {
    const c = r.center();
    for (mons) |m| {
        const l = m.logical orelse continue;
        if (!l.contains(c.x, c.y)) continue;
        const s = scaleOf(m, l);
        const x0 = round(@as(f64, @floatFromInt(r.x - l.x)) * s);
        const y0 = round(@as(f64, @floatFromInt(r.y - l.y)) * s);
        const x1 = round(@as(f64, @floatFromInt(r.right() - l.x)) * s);
        const y1 = round(@as(f64, @floatFromInt(r.bottom() - l.y)) * s);
        const ox: i32 = @intCast(m.x);
        const oy: i32 = @intCast(m.y);
        return Rect.intersect(Rect.fromEdges(ox + x0, oy + y0, ox + x1, oy + y1), m.pixelRect());
    }
    return null;
}

/// A logical rectangle's part on each monitor it shows on, in image
/// pixels, united (a window across two monitors is one rectangle).
pub fn spanToImage(mons: []const Monitor, r: Rect) ?Rect {
    var acc: ?Rect = null;
    for (mons) |m| {
        const l = m.logical orelse continue;
        const part = Rect.intersect(r, l) orelse continue;
        const px = logicalToImage(&.{m}, part) orelse continue;
        acc = if (acc) |a| Rect.unite(a, px) else px;
    }
    return acc;
}

/// An image rectangle (a selection) in logical coordinates, through the
/// monitor holding its centre, and that monitor's scale.
pub fn imageToLogical(mons: []const Monitor, r: Rect) ?struct { rect: Rect, scale: f64 } {
    const c = r.center();
    for (mons) |m| {
        const l = m.logical orelse continue;
        const px = m.pixelRect();
        if (!px.contains(c.x, c.y)) continue;
        const clipped = Rect.intersect(r, px) orelse return null;
        const s = scaleOf(m, l);
        const x0 = round(@as(f64, @floatFromInt(clipped.x - px.x)) / s);
        const y0 = round(@as(f64, @floatFromInt(clipped.y - px.y)) / s);
        const x1 = round(@as(f64, @floatFromInt(clipped.right() - px.x)) / s);
        const y1 = round(@as(f64, @floatFromInt(clipped.bottom() - px.y)) / s);
        return .{ .rect = Rect.fromEdges(l.x + x0, l.y + y0, l.x + x1, l.y + y1), .scale = s };
    }
    return null;
}

/// The pixels of a `fw` x `fh` frame showing logical `mon` (a recorded
/// stream) that hold logical `region` (clipped to the monitor), or null
/// when they do not meet.
pub fn toFramePixels(region: Rect, mon: Rect, fw: u32, fh: u32) ?Rect {
    const r = region.intersect(mon) orelse return null;
    const sx = @as(f64, @floatFromInt(fw)) / @as(f64, @floatFromInt(mon.w));
    const sy = @as(f64, @floatFromInt(fh)) / @as(f64, @floatFromInt(mon.h));
    const x0 = round(@as(f64, @floatFromInt(r.x - mon.x)) * sx);
    const y0 = round(@as(f64, @floatFromInt(r.y - mon.y)) * sy);
    const x1 = round(@as(f64, @floatFromInt(r.right() - mon.x)) * sx);
    const y1 = round(@as(f64, @floatFromInt(r.bottom() - mon.y)) * sy);
    return Rect.fromEdges(x0, y0, x1, y1).clip(fw, fh);
}

/// A surface's physical rect `r` (scale `k`, ui/scale.zig) in its logical
/// pixels, covering it: the origin floored, the size rounded up, at
/// least 1 (the backend's text-input caret).
pub fn physicalToLogical(r: Rect, k: f64) Rect {
    const d = if (k > 0) k else 1.0;
    return .{
        .x = @intFromFloat(@floor(@as(f64, @floatFromInt(r.x)) / d)),
        .y = @intFromFloat(@floor(@as(f64, @floatFromInt(r.y)) / d)),
        .w = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(r.w)) / d)))),
        .h = @max(1, @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(r.h)) / d)))),
    };
}

const testing = std.testing;

test "a physical rect in logical pixels covers it" {
    try testing.expectEqual(Rect{ .x = 150, .y = 25, .w = 2, .h = 21 }, physicalToLogical(.{ .x = 301, .y = 50, .w = 3, .h = 41 }, 2.0));
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 1, .h = 1 }, physicalToLogical(.{ .x = 1, .y = 2, .w = 0, .h = 0 }, 0));
}

test "rect normalization" {
    const r = (Rect{ .x = 100, .y = 50, .w = -30, .h = -20 }).normalized();
    try testing.expectEqual(Rect{ .x = 70, .y = 30, .w = 30, .h = 20 }, r);
    try testing.expect(r.contains(70, 30));
    try testing.expect(!r.contains(100, 50));
    try testing.expectEqual(r, Rect.fromCorners(.{ .x = 100, .y = 50 }, .{ .x = 70, .y = 30 }));
}

test "rect intersect, unite and clip" {
    const a = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b = Rect{ .x = 5, .y = -5, .w = 10, .h = 10 };
    const i = Rect.intersect(a, b).?;
    try testing.expect(i.eql(.{ .x = 5, .y = 0, .w = 5, .h = 5 }));
    try testing.expect(Rect.unite(a, b).eql(.{ .x = 0, .y = -5, .w = 15, .h = 15 }));
    try testing.expect(Rect.unite(Rect.empty, b).eql(b));
    try testing.expectEqual(@as(?Rect, null), Rect.intersect(a, .{ .x = 10, .y = 0, .w = 5, .h = 5 }));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 3, .h = 3 }, (Rect{ .x = -2, .y = -1, .w = 5, .h = 9 }).clip(4, 3).?);
    try testing.expectEqual(@as(?Rect, null), (Rect{ .x = 4, .y = 0, .w = 5, .h = 5 }).clip(4, 3));
    try testing.expectEqual(@as(?Rect, null), (Rect{ .x = 0, .y = 0, .w = std.math.maxInt(i32), .h = 0 }).clip(4, 3));
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, Rect.fromEdges(1, 2, 4, 6));
}

// 1280x720 logical at 2 (2560x1440 px) left of 1280x720 at 1
const mixed = [_]Monitor{
    .{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1280, .h = 720 } },
    .{ .x = 2560, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 1280, .y = 0, .w = 1280, .h = 720 } },
};

test "window frames map to image pixels at each monitor's scale" {
    // on the 2x monitor
    try testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 800, .h = 600 }, logicalToImage(&mixed, .{ .x = 100, .y = 50, .w = 400, .h = 300 }).?);
    // on the 1x monitor, upscaled to the capture's 2x
    try testing.expectEqual(Rect{ .x = 2760, .y = 100, .w = 800, .h = 600 }, logicalToImage(&mixed, .{ .x = 1380, .y = 50, .w = 400, .h = 300 }).?);
    // hanging off the left edge: clipped to the monitor
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, logicalToImage(&mixed, .{ .x = -50, .y = -10, .w = 100, .h = 60 }).?);
    try testing.expectEqual(@as(?Rect, null), logicalToImage(&mixed, .{ .x = 5000, .y = 0, .w = 10, .h = 10 }));
    // across both: one rectangle
    try testing.expectEqual(Rect{ .x = 2360, .y = 0, .w = 400, .h = 200 }, spanToImage(&mixed, .{ .x = 1180, .y = 0, .w = 200, .h = 100 }).?);
}

test "fractional scale rounds to whole pixels" {
    const frac = [_]Monitor{.{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1707, .h = 960 } }};
    const r = logicalToImage(&frac, .{ .x = 10, .y = 10, .w = 300, .h = 200 }).?;
    try testing.expectEqual(@as(i32, 15), r.x);
    try testing.expectEqual(@as(i32, 450), r.w);
    const back = imageToLogical(&frac, r).?;
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 300, .h = 200 }, back.rect);
    try testing.expectApproxEqAbs(@as(f64, 1.4997), back.scale, 1e-3);
}

test "selections map back to logical coordinates" {
    const l = imageToLogical(&mixed, .{ .x = 2760, .y = 100, .w = 800, .h = 600 }).?;
    try testing.expectEqual(Rect{ .x = 1380, .y = 50, .w = 400, .h = 300 }, l.rect);
    try testing.expectEqual(@as(f64, 2), l.scale);
    try testing.expectEqual(@as(usize, 1), monitorAt(&mixed, .{ 1300, 10 }));
    try testing.expectEqual(@as(usize, 0), monitorAt(&mixed, null));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 2560, .h = 720 }, layoutBounds(&mixed));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1, .h = 1 }, layoutBounds(&.{.{ .x = 0, .y = 0, .w = 9, .h = 9 }}));
}

test "a region maps onto a scaled monitor's frame pixels" {
    const mon: Rect = .{ .x = 1600, .y = 0, .w = 1280, .h = 720 };
    // scale 2: twice the pixels
    const px = toFramePixels(.{ .x = 1700, .y = 50, .w = 200, .h = 100 }, mon, 2560, 1440).?;
    try testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 400, .h = 200 }, px);
    // clipped at the monitor's edge
    const c = toFramePixels(.{ .x = 1500, .y = 600, .w = 200, .h = 400 }, mon, 1280, 720).?;
    try testing.expectEqual(Rect{ .x = 0, .y = 600, .w = 100, .h = 120 }, c);
    try testing.expect(toFramePixels(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, mon, 1280, 720) == null);
    // fractional 1.5
    const f = toFramePixels(.{ .x = 1601, .y = 1, .w = 3, .h = 3 }, mon, 1920, 1080).?;
    try testing.expectEqual(Rect{ .x = 2, .y = 2, .w = 4, .h = 4 }, f);
}
