//! What a capture hands to the editor: one image covering every captured
//! monitor, and where each monitor lies inside it.

const std = @import("std");
const png = @import("../gfx/png.zig");
const geom = @import("../geom.zig");
const Frozen = @import("../ui/freeze_pick.zig").Frozen;
const bands = @import("../ui/bands.zig");

/// A monitor's place in the image and in the logical layout (geom.zig).
pub const Monitor = geom.Monitor;

pub const Capture = struct {
    image: png.Image,
    /// at least one entry; a single monitor spanning the image when the
    /// layout is unknown
    monitors: []Monitor,

    /// A capture whose layout is unknown: the whole image is one monitor.
    pub fn single(gpa: std.mem.Allocator, image: png.Image) !Capture {
        const mons = try gpa.alloc(Monitor, 1);
        mons[0] = .{ .x = 0, .y = 0, .w = image.width, .h = image.height };
        return .{ .image = image, .monitors = mons };
    }

    /// The capture as a picker shows it (ui/freeze_pick.zig).
    pub fn frozen(self: *const Capture) Frozen {
        return .{ .pixels = self.image.pixels, .width = self.image.width, .height = self.image.height, .monitors = self.monitors };
    }

    pub fn deinit(self: *Capture, gpa: std.mem.Allocator) void {
        self.image.deinit(gpa);
        gpa.free(self.monitors);
        self.* = undefined;
    }
};

/// One monitor's frame, before stitching.
pub const Part = struct {
    /// 0xAARRGGBB, width*height, tightly packed
    pixels: []const u32,
    width: u32,
    height: u32,
    /// logical rect from the portal; null when it did not say
    logical: ?geom.Rect = null,
};

/// Largest stitched image we build (about 1 GiB of pixels).
const max_pixels: u64 = 256 * 1024 * 1024;

/// Lay out several monitor frames as one image. With every logical rect
/// known, monitors go where the compositor has them, at one pixel scale:
/// the highest among them (a 1x monitor next to a 2x one is scaled up
/// rather than throwing away the 2x detail). Gaps are opaque black.
/// Without a full layout, frames are placed left to right at native size.
pub fn stitch(gpa: std.mem.Allocator, parts: []const Part) !Capture {
    const pl = try plan(gpa, parts);
    defer gpa.free(pl.native);
    errdefer gpa.free(pl.mons);
    const px = try gpa.alloc(u32, @as(usize, pl.width) * pl.height);
    errdefer gpa.free(px);
    fill(px, pl, parts, false);
    return .{ .image = .{ .width = pl.width, .height = pl.height, .pixels = px }, .monitors = pl.mons };
}

/// Where stitch puts each frame (from the frames' sizes and logical
/// rects only: their pixels may still be on their way).
pub const Plan = struct {
    /// owned, one per part
    mons: []Monitor,
    /// owned: the part is at the image's density (copied as it is)
    native: []bool,
    width: u32,
    height: u32,
};

pub fn plan(gpa: std.mem.Allocator, parts: []const Part) !Plan {
    if (parts.len == 0) return error.NoFrames;
    const mons = try gpa.alloc(Monitor, parts.len);
    errdefer gpa.free(mons);
    const native = try gpa.alloc(bool, parts.len);
    errdefer gpa.free(native);
    if (try hasLayout(parts)) placeByLayout(parts, mons, native) else placeInRow(parts, mons, native);
    const width, const height = try canvasSize(mons);
    return .{ .mons = mons, .native = native, .width = width, .height = height };
}

/// Paint the stitched image `px` as `pl` lays it out: the gaps opaque
/// black, the native parts copied (unless `natives_placed`: they were
/// decoded straight into place), the others resampled. In bands of
/// rows, a thread each (two 4K monitors: tens of millions of pixels).
pub fn fill(px: []u32, pl: Plan, parts: []const Part, natives_placed: bool) void {
    const Ctx = struct {
        parts: []const Part,
        pl: Plan,
        px: []u32,
        placed: bool,
        fn band(c: @This(), b: geom.Rect) void {
            const y0: u32 = @intCast(b.y);
            const y1: u32 = @intCast(b.bottom());
            var y = y0;
            while (y < y1) : (y += 1) blackGaps(c.px[@as(usize, y) * c.pl.width ..][0..c.pl.width], c.pl.mons, y);
            for (c.parts, c.pl.mons, c.pl.native) |p, m, nat| {
                if (!nat) resampleBilinear(p.pixels, p.width, p.height, c.px, c.pl.width, m, y0, y1) else if (!c.placed) copyNative(p, m, c.px, c.pl.width, y0, y1);
            }
        }
    };
    bands.run(.ofSize(pl.width, pl.height), Ctx{ .parts = parts, .pl = pl, .px = px, .placed = natives_placed }, Ctx.band);
}

/// Image row `y`: opaque black where no monitor is.
fn blackGaps(row: []u32, mons: []const Monitor, y: u32) void {
    var x: u32 = 0;
    while (x < row.len) {
        // the monitor on this row starting at x or covering it, else the
        // next one to the right
        var next: u32 = @intCast(row.len);
        var covered_to: ?u32 = null;
        for (mons) |m| {
            if (y < m.y or y >= m.y + m.h) continue;
            if (m.x <= x and x < m.x + m.w) covered_to = @max(covered_to orelse 0, m.x + m.w);
            if (m.x > x) next = @min(next, m.x);
        }
        if (covered_to) |to| {
            x = @min(to, @as(u32, @intCast(row.len)));
            continue;
        }
        @memset(row[x..next], 0xFF000000);
        x = next;
    }
}

/// True when every part has a usable logical rect; fails on empty frames.
fn hasLayout(parts: []const Part) !bool {
    var have_layout = true;
    for (parts) |p| {
        if (p.width == 0 or p.height == 0) return error.EmptyFrame;
        const l = p.logical orelse {
            have_layout = false;
            continue;
        };
        if (l.w == 0 or l.h == 0) have_layout = false;
    }
    return have_layout;
}

/// Monitors where the compositor has them, at the highest pixel scale
/// among them; `native` marks those already at that scale.
fn placeByLayout(parts: []const Part, mons: []Monitor, native: []bool) void {
    var scale: f64 = 0;
    var min_x: i64 = std.math.maxInt(i64);
    var min_y: i64 = std.math.maxInt(i64);
    for (parts) |p| {
        const l = p.logical.?;
        scale = @max(scale, @as(f64, @floatFromInt(p.width)) / @as(f64, @floatFromInt(l.w)));
        min_x = @min(min_x, l.x);
        min_y = @min(min_y, l.y);
    }
    for (parts, mons, native) |p, *m, *nat| {
        const l = p.logical.?;
        const own = @as(f64, @floatFromInt(p.width)) / @as(f64, @floatFromInt(l.w));
        nat.* = @abs(own - scale) / scale < 0.005;
        m.* = .{
            .x = toPx(@as(f64, @floatFromInt(l.x - min_x)) * scale),
            .y = toPx(@as(f64, @floatFromInt(l.y - min_y)) * scale),
            .w = if (nat.*) p.width else @max(1, toPx(@as(f64, @floatFromInt(l.w)) * scale)),
            .h = if (nat.*) p.height else @max(1, toPx(@as(f64, @floatFromInt(l.h)) * scale)),
            .logical = l,
        };
    }
}

/// Without a full layout: left to right at native size.
fn placeInRow(parts: []const Part, mons: []Monitor, native: []bool) void {
    var x: u32 = 0;
    for (parts, mons, native) |p, *m, *nat| {
        nat.* = true;
        m.* = .{ .x = x, .y = 0, .w = p.width, .h = p.height };
        x +|= p.width;
    }
}

/// The stitched image's size: the monitors' bounding box, within limits.
fn canvasSize(mons: []const Monitor) ![2]u32 {
    var cw: u64 = 0;
    var ch: u64 = 0;
    for (mons) |m| {
        cw = @max(cw, @as(u64, m.x) + m.w);
        ch = @max(ch, @as(u64, m.y) + m.h);
    }
    if (cw == 0 or ch == 0 or cw * ch > max_pixels or cw > 65535 or ch > 65535) return error.CaptureTooLarge;
    return .{ @intCast(cw), @intCast(ch) };
}

/// Copies a part at its own scale into `m` of the image, clipped.
fn copyNative(p: Part, m: Monitor, px: []u32, width: u32, y0: u32, y1: u32) void {
    const height: u32 = @intCast(px.len / width);
    const w = @min(p.width, width - m.x);
    const h = @min(p.height, height - m.y);
    // its rows within [y0, y1)
    const from = @max(m.y, y0);
    const to = @min(m.y + h, y1);
    var y = from;
    while (y < to) : (y += 1) {
        const row = y - m.y;
        @memcpy(px[y * width + m.x ..][0..w], p.pixels[row * p.width ..][0..w]);
    }
}

fn toPx(v: f64) u32 {
    if (!(v > 0)) return 0;
    return @intFromFloat(@min(@round(v), 1e9));
}

/// Scale `src` into the rect `r` of `dst` with a bilinear filter
/// (pixel-centre aligned, edges clamped), the rows of `dst` in
/// [band_y0, band_y1) only. Fixed point, 8 fractional bits.
fn resampleBilinear(src: []const u32, sw: u32, sh: u32, dst: []u32, dst_w: u32, r: Monitor, band_y0: u32, band_y1: u32) void {
    const dst_h: u32 = @intCast(dst.len / dst_w);
    const w = @min(r.w, dst_w -| r.x);
    const h = @min(r.h, dst_h -| r.y);
    if (w == 0 or h == 0) return;
    const sx_step = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(r.w));
    const sy_step = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(r.h));
    const from = @max(r.y, band_y0) -| r.y;
    const to = @min(r.y + h, band_y1) -| r.y;
    for (from..@max(from, to)) |dy| {
        const fy = @max(0, (@as(f64, @floatFromInt(dy)) + 0.5) * sy_step - 0.5);
        const y0: u32 = @min(sh - 1, @as(u32, @intFromFloat(fy)));
        const y1: u32 = @min(sh - 1, y0 + 1);
        const wy: u32 = @intFromFloat((fy - @as(f64, @floatFromInt(y0))) * 256);
        const row0 = src[@as(usize, y0) * sw ..][0..sw];
        const row1 = src[@as(usize, y1) * sw ..][0..sw];
        const out = dst[(r.y + dy) * dst_w + r.x ..][0..w];
        for (out, 0..) |*o, dx| {
            const fx = @max(0, (@as(f64, @floatFromInt(dx)) + 0.5) * sx_step - 0.5);
            const x0: u32 = @min(sw - 1, @as(u32, @intFromFloat(fx)));
            const x1: u32 = @min(sw - 1, x0 + 1);
            const wx: u32 = @intFromFloat((fx - @as(f64, @floatFromInt(x0))) * 256);
            o.* = blend4(row0[x0], row0[x1], row1[x0], row1[x1], @min(wx, 256), @min(wy, 256));
        }
    }
}

fn blend4(a: u32, b: u32, c: u32, d: u32, wx: u32, wy: u32) u32 {
    var out: u32 = 0;
    inline for (0..4) |i| {
        const sh: u5 = @intCast(i * 8);
        const ca = (a >> sh) & 0xFF;
        const cb = (b >> sh) & 0xFF;
        const cc = (c >> sh) & 0xFF;
        const cd = (d >> sh) & 0xFF;
        const top = ca * (256 - wx) + cb * wx;
        const bot = cc * (256 - wx) + cd * wx;
        const v = (top * (256 - wy) + bot * wy + (1 << 15)) >> 16;
        out |= @as(u32, @min(v, 255)) << sh;
    }
    return out;
}

test "single capture spans the image" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u32, 6);
    @memset(px, 0);
    var cap = try Capture.single(gpa, .{ .width = 3, .height = 2, .pixels = px });
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), cap.monitors.len);
    try std.testing.expectEqual(@as(u32, 3), cap.monitors[0].w);
}

test "stitch lays monitors out by logical position at the highest scale" {
    const gpa = std.testing.allocator;
    // left: 1x monitor, 4x2 logical, 4x2 pixels, all red
    // right: 2x monitor, 2x2 logical at x=4, 4x4 pixels, all blue
    var left: [8]u32 = @splat(0xFFFF0000);
    var right: [16]u32 = @splat(0xFF0000FF);
    var cap = try stitch(gpa, &.{
        .{ .pixels = &left, .width = 4, .height = 2, .logical = .{ .x = 0, .y = 0, .w = 4, .h = 2 } },
        .{ .pixels = &right, .width = 4, .height = 4, .logical = .{ .x = 4, .y = 0, .w = 2, .h = 2 } },
    });
    defer cap.deinit(gpa);
    // scale 2: left becomes 8x4, right stays 4x4 at x=8
    try std.testing.expectEqual(@as(u32, 12), cap.image.width);
    try std.testing.expectEqual(@as(u32, 4), cap.image.height);
    try std.testing.expectEqual(Monitor{ .x = 0, .y = 0, .w = 8, .h = 4, .logical = .{ .x = 0, .y = 0, .w = 4, .h = 2 } }, cap.monitors[0]);
    try std.testing.expectEqual(@as(u32, 8), cap.monitors[1].x);
    try std.testing.expectEqual(@as(u32, 4), cap.monitors[1].w);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), cap.image.pixels[3 * 12 + 7]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cap.image.pixels[3 * 12 + 8]);
}

test "the gaps of a row are black, the monitors' pixels left alone" {
    var row: [10]u32 = @splat(0xFF777777);
    const mons = [_]Monitor{
        .{ .x = 2, .y = 0, .w = 3, .h = 1 },
        .{ .x = 4, .y = 0, .w = 2, .h = 1 },
        .{ .x = 8, .y = 1, .w = 2, .h = 1 },
    };
    blackGaps(&row, &mons, 0);
    const k: u32 = 0xFF000000;
    const g: u32 = 0xFF777777;
    try std.testing.expectEqualSlices(u32, &.{ k, k, g, g, g, g, k, k, k, k }, &row);
}

test "stitch handles negative positions, gaps and unknown layouts" {
    const gpa = std.testing.allocator;
    var a: [4]u32 = @splat(0xFF111111);
    var b: [4]u32 = @splat(0xFF222222);
    // b sits above-left of a, diagonally: the gap is black
    var cap = try stitch(gpa, &.{
        .{ .pixels = &a, .width = 2, .height = 2, .logical = .{ .x = 0, .y = 0, .w = 2, .h = 2 } },
        .{ .pixels = &b, .width = 2, .height = 2, .logical = .{ .x = -2, .y = -2, .w = 2, .h = 2 } },
    });
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4), cap.image.width);
    try std.testing.expectEqual(@as(u32, 2), cap.monitors[0].x);
    try std.testing.expectEqual(@as(u32, 0xFF222222), cap.image.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), cap.image.pixels[3]);
    try std.testing.expectEqual(@as(u32, 0xFF111111), cap.image.pixels[15]);

    var row = try stitch(gpa, &.{
        .{ .pixels = &a, .width = 2, .height = 2 },
        .{ .pixels = &b, .width = 1, .height = 4, .logical = .{ .x = 0, .y = 0, .w = 1, .h = 4 } },
    });
    defer row.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), row.image.width);
    try std.testing.expectEqual(@as(u32, 4), row.image.height);
    try std.testing.expect(row.monitors[1].logical == null);
}

test "bilinear upscale keeps flat colors and blends edges" {
    var src = [_]u32{ 0xFF000000, 0xFFFFFFFF };
    var dst: [4]u32 = @splat(0);
    resampleBilinear(&src, 2, 1, &dst, 4, .{ .x = 0, .y = 0, .w = 4, .h = 1 }, 0, 1);
    try std.testing.expectEqual(@as(u32, 0xFF000000), dst[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), dst[3]);
    try std.testing.expect(dst[1] & 0xFF > 0 and dst[1] & 0xFF < 0xFF);
}
