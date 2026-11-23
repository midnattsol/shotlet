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
    /// What of `a` lies outside `b`: at most four rects (the bands above
    /// and below `b`, then left and right of it), into `out`.
    pub fn subtract(a: Rect, b: Rect, out: *[4]Rect) []const Rect {
        if (a.isEmpty()) return out[0..0];
        const c = a.intersect(b) orelse {
            out[0] = a;
            return out[0..1];
        };
        var n: usize = 0;
        const parts = [4]Rect{
            fromEdges(a.x, a.y, a.right(), c.y),
            fromEdges(a.x, c.bottom(), a.right(), a.bottom()),
            fromEdges(a.x, c.y, c.x, c.bottom()),
            fromEdges(c.right(), c.y, a.right(), c.bottom()),
        };
        for (parts) |p| if (!p.isEmpty()) {
            out[n] = p;
            n += 1;
        };
        return out[0..n];
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
    /// the compositor's scale for it (its physical pixels per logical
    /// pixel), which the capture's image need not show it at (a mixed
    /// layout is stitched at the sharpest density); 0 when unknown (the
    /// portals, --from)
    scale: f64 = 0,

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

/// The rect (index into `rects`) that most of `r` lies on; null when it
/// meets none (a recorded area's monitor, a selection's).
pub fn bestMonitor(r: Rect, rects: []const Rect) ?usize {
    var best: ?usize = null;
    var best_area: i64 = 0;
    for (rects, 0..) |m, i| {
        const a = if (r.intersect(m)) |x| x.area() else 0;
        if (a > best_area) {
            best_area = a;
            best = i;
        }
    }
    return best;
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

/// The smallest logical length that is a whole number of physical
/// pixels at `scale`: 1 at whole scales, 2 at 1.5, 4 at 1.25 or 1.75,
/// 3 at 4/3 (mutter's fractional scales keep a logical size whole).
pub fn pixelStep(scale: f64) i32 {
    var n: i32 = 1;
    while (n <= 16) : (n += 1) {
        const v = @as(f64, @floatFromInt(n)) * scale;
        if (@abs(v - @round(v)) < 1e-3) return n;
    }
    return 1;
}

/// A logical region (on the monitor holding its centre) grown to whole
/// physical pixels of that monitor: its edges, from the monitor's
/// origin, on multiples of pixelStep. What the shell paints for a
/// region then starts and ends on its pixels, with no half-pixel
/// resampling (an odd logical edge at 1.5 is half a pixel in). The
/// region unchanged when the monitor's scale is unknown.
pub fn onWholePixels(mons: []const Monitor, r: Rect) Rect {
    const c = r.center();
    for (mons) |m| {
        const l = m.logical orelse continue;
        if (!l.contains(c.x, c.y) or m.scale <= 0) continue;
        const n = pixelStep(m.scale);
        if (n == 1) return r;
        const x0 = l.x + @divFloor(r.x - l.x, n) * n;
        const y0 = l.y + @divFloor(r.y - l.y, n) * n;
        const x1 = l.x + @min(l.w, ceilTo(r.right() - l.x, n));
        const y1 = l.y + @min(l.h, ceilTo(r.bottom() - l.y, n));
        return Rect.fromEdges(@max(x0, l.x), @max(y0, l.y), x1, y1);
    }
    return r;
}

fn ceilTo(v: i32, n: i32) i32 {
    return @divFloor(v + n - 1, n) * n;
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

test "a rect picks the monitor holding most of it" {
    const mons = [_]Rect{ .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, .{ .x = 1600, .y = 0, .w = 1280, .h = 720 } };
    try std.testing.expectEqual(@as(?usize, 1), bestMonitor(.{ .x = 1500, .y = 10, .w = 400, .h = 100 }, &mons));
    try std.testing.expectEqual(@as(?usize, null), bestMonitor(.{ .x = 0, .y = 1000, .w = 10, .h = 10 }, &mons));
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

// the scrolling capture's mixed layout: a built-in 3456x2160 at 2
// (1728x1080 logical) left of a 3840x2160 at 1.5 (2560x1440 logical);
// the stitched capture keeps the sharpest density, 2, so the 1.5
// monitor's part is 5120x2880 image pixels
const owner = [_]Monitor{
    .{ .x = 0, .y = 0, .w = 3456, .h = 2160, .logical = .{ .x = 0, .y = 0, .w = 1728, .h = 1080 }, .scale = 2 },
    .{ .x = 3456, .y = 0, .w = 5120, .h = 2880, .logical = .{ .x = 1728, .y = 0, .w = 2560, .h = 1440 }, .scale = 1.5 },
};

test "a region grows to whole physical pixels of its monitor" {
    try testing.expectEqual(@as(i32, 1), pixelStep(2));
    try testing.expectEqual(@as(i32, 2), pixelStep(1.5));
    try testing.expectEqual(@as(i32, 4), pixelStep(1.25));
    try testing.expectEqual(@as(i32, 4), pixelStep(1.75));
    try testing.expectEqual(@as(i32, 3), pixelStep(1.3333333730697632));
    // odd edges at 1.5 (683 is 1024.5 px in): out to even ones
    const r = onWholePixels(&owner, .{ .x = 1728 + 683, .y = 207, .w = 1841, .h = 921 });
    try testing.expectEqual(Rect{ .x = 1728 + 682, .y = 206, .w = 1842, .h = 922 }, r);
    try testing.expect(@mod(r.x - 1728, 2) == 0 and @mod(r.w, 2) == 0 and @mod(r.h, 2) == 0);
    // even ones stay; on the 2 monitor anything stays
    const even: Rect = .{ .x = 2410, .y = 206, .w = 1844, .h = 922 };
    try testing.expectEqual(even, onWholePixels(&owner, even));
    const two: Rect = .{ .x = 11, .y = 13, .w = 101, .h = 33 };
    try testing.expectEqual(two, onWholePixels(&owner, two));
    // never past the monitor's edge; unknown scale: unchanged
    try testing.expectEqual(@as(i32, 1728 + 2560), onWholePixels(&owner, .{ .x = 4000, .y = 0, .w = 287, .h = 11 }).right());
    const odd: Rect = .{ .x = 1, .y = 1, .w = 3, .h = 3 };
    try testing.expectEqual(odd, onWholePixels(&mixed, odd));
}

test "a selection on the 1.5 monitor beside a 2 one maps to its logical region" {
    // the picked region (image pixels, odd width: half a logical pixel)
    const l = imageToLogical(&owner, .{ .x = 4820, .y = 411, .w = 3685, .h = 1844 }).?;
    try testing.expectEqual(Rect{ .x = 2410, .y = 206, .w = 1843, .h = 922 }, l.rect);
    try testing.expectEqual(@as(f64, 2), l.scale);
    // and back: whole image pixels, one more where the half rounded up
    try testing.expectEqual(Rect{ .x = 4820, .y = 412, .w = 3686, .h = 1844 }, logicalToImage(&owner, l.rect).?);
    // on the 2 monitor, 1:1 with its own pixels
    const b = imageToLogical(&owner, .{ .x = 100, .y = 60, .w = 801, .h = 400 }).?;
    try testing.expectEqual(Rect{ .x = 50, .y = 30, .w = 401, .h = 200 }, b.rect);
    // across the seam: the monitor holding its centre, clipped to it
    const s = imageToLogical(&owner, .{ .x = 3000, .y = 0, .w = 2000, .h = 200 }).?;
    try testing.expectEqual(Rect{ .x = 1728, .y = 0, .w = 772, .h = 100 }, s.rect);
    try testing.expectEqual(@as(usize, 1), monitorAt(&owner, .{ 2410, 206 }));
    try testing.expectEqual(@as(usize, 0), monitorAt(&owner, .{ 1727, 1079 }));
}

test "a rect minus another: the bands around the overlap" {
    var out: [4]Rect = undefined;
    const a: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    // grown by 10 to the right and 5 down: only those strips are new
    const b: Rect = .{ .x = 0, .y = 0, .w = 110, .h = 55 };
    try testing.expectEqual(@as(usize, 0), a.subtract(b, &out).len);
    const d = b.subtract(a, &out);
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqual(Rect{ .x = 0, .y = 50, .w = 110, .h = 5 }, d[0]);
    try testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 10, .h = 50 }, d[1]);
    var area: i64 = 0;
    for (d) |r| area += r.area();
    try testing.expectEqual(b.area() - a.area(), area);
    // apart: all of it; inside: four bands
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 50 }, a.subtract(.{ .x = 500, .y = 0, .w = 5, .h = 5 }, &out)[0]);
    try testing.expectEqual(@as(usize, 4), a.subtract(.{ .x = 10, .y = 10, .w = 5, .h = 5 }, &out).len);
}
