//! Raster helpers shared by shapes and chrome: rounded-rect rings, filled
//! ellipses, aligned pixelation and a contrasting label colour.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const sdf = @import("../../gfx/render/sdf.zig");
const color_mod = @import("../../gfx/color.zig");
const Rect = @import("geometry.zig").Rect;

const Canvas = render.Canvas;

/// Anti-aliased rounded rectangle outline drawn inside `r`; touches only
/// the border band, so big rectangles stay cheap.
pub fn roundRectRing(canvas: *Canvas, r: Rect, radius: f64, width: f64, color: u32) void {
    if (r.w <= 0 or r.h <= 0) return;
    const fx0: f64 = @floatFromInt(r.x);
    const fy0: f64 = @floatFromInt(r.y);
    const fx1: f64 = @floatFromInt(r.right());
    const fy1: f64 = @floatFromInt(r.bottom());
    const ro = @min(radius, @min(@as(f64, @floatFromInt(r.w)), @as(f64, @floatFromInt(r.h))) / 2.0);
    const ri = @max(0.0, ro - width);
    // the inside edge, when the ring does not fill the rect
    const hole = fx1 - fx0 > 2 * width and fy1 - fy0 > 2 * width;
    const band: i32 = @as(i32, @intFromFloat(@ceil(@max(ro, width)))) + 2;
    var y: i32 = @max(r.y - 1, 0);
    const y_end = @min(r.bottom() + 1, canvas.h);
    while (y < y_end) : (y += 1) {
        const near_edge = y < r.y + band or y >= r.bottom() - band;
        var x: i32 = @max(r.x - 1, 0);
        const x_end = @min(r.right() + 1, canvas.w);
        while (x < x_end) : (x += 1) {
            if (!near_edge and x >= r.x + band and x < r.right() - band) {
                x = r.right() - band - 1;
                continue;
            }
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const py = @as(f64, @floatFromInt(y)) + 0.5;
            const cov = sdf.cov(sdf.roundRectDist(px, py, fx0, fy0, fx1, fy1, ro)) -
                if (hole) sdf.cov(sdf.roundRectDist(px, py, fx0 + width, fy0 + width, fx1 - width, fy1 - width, ri)) else 0;
            canvas.blendCov(x, y, color, cov);
        }
    }
}

pub fn fillEllipseAA(canvas: *Canvas, r: Rect, color: u32) void {
    if (r.w < 1 or r.h < 1) return;
    const rx = @as(f64, @floatFromInt(r.w)) / 2.0;
    const ry = @as(f64, @floatFromInt(r.h)) / 2.0;
    const cx = @as(f64, @floatFromInt(r.x)) + rx;
    const cy = @as(f64, @floatFromInt(r.y)) + ry;
    var y: i32 = @max(r.y - 1, 0);
    while (y < @min(r.bottom() + 1, canvas.h)) : (y += 1) {
        var x: i32 = @max(r.x - 1, 0);
        while (x < @min(r.right() + 1, canvas.w)) : (x += 1) {
            const dx = @as(f64, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f64, @floatFromInt(y)) + 0.5 - cy;
            const f = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) - 1.0;
            const gx = 2.0 * dx / (rx * rx);
            const gy = 2.0 * dy / (ry * ry);
            const g = @max(1e-9, @sqrt(gx * gx + gy * gy));
            canvas.blendCov(x, y, color, sdf.cov(f / g));
        }
    }
}

/// Mosaic `r` with `blk`-sized cells aligned to the rectangle's own
/// corner, so a clipped redraw produces the same cells as a full one.
pub fn pixelateAligned(canvas: *Canvas, r: Rect, blk: i32) void {
    const clip = Rect.intersect(r, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return;
    var by = r.y + @divFloor(clip.y - r.y, blk) * blk;
    while (by < clip.bottom()) : (by += blk) {
        var bx = r.x + @divFloor(clip.x - r.x, blk) * blk;
        while (bx < clip.right()) : (bx += blk) {
            const cell = Rect.intersect(.{ .x = bx, .y = by, .w = blk, .h = blk }, clip) orelse continue;
            var acc: [3]u64 = .{ 0, 0, 0 };
            var y = cell.y;
            while (y < cell.bottom()) : (y += 1) {
                for (canvas.px[@intCast(y * canvas.w + cell.x)..][0..@intCast(cell.w)]) |p| {
                    acc[0] += (p >> 16) & 0xFF;
                    acc[1] += (p >> 8) & 0xFF;
                    acc[2] += p & 0xFF;
                }
            }
            const n: u64 = @intCast(cell.w * cell.h);
            const avg: u32 = 0xFF000000 | @as(u32, @intCast(acc[0] / n)) << 16 | @as(u32, @intCast(acc[1] / n)) << 8 | @as(u32, @intCast(acc[2] / n));
            y = cell.y;
            while (y < cell.bottom()) : (y += 1) {
                @memset(canvas.px[@intCast(y * canvas.w + cell.x)..][0..@intCast(cell.w)], avg);
            }
        }
    }
}

/// Whether `c` reads as a light colour: dark text goes on it. Mid grey
/// (0x8C) and the palette's red, blue, purple and pink are dark.
pub fn isLight(c: u32) bool {
    return color_mod.luminance(c) > 0.265;
}

/// A label colour that reads on `c`: near-black on light colours, white
/// on dark ones.
pub fn contrastColor(c: u32) u32 {
    return if (isLight(c)) 0xFF1A1A1A else 0xFFFFFFFF;
}

test "pixelate cells stay aligned when clipped" {
    // a full render and a render through an offset canvas give the same cells
    var full: [32 * 8]u32 = undefined;
    for (&full, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast((i * 2654435761) % 0xFFFFFF));
    var part: [16 * 8]u32 = undefined;
    for (0..8) |y| @memcpy(part[y * 16 ..][0..16], full[y * 32 + 16 ..][0..16]);
    var cf = Canvas.init(&full, 32, 8);
    pixelateAligned(&cf, .{ .x = 2, .y = 0, .w = 28, .h = 8 }, 4);
    var cp = Canvas.init(&part, 16, 8);
    pixelateAligned(&cp, .{ .x = 2 - 16, .y = 0, .w = 28, .h = 8 }, 4);
    // cells fully inside the partial canvas match
    for (0..8) |y| {
        for (2..14) |x| try std.testing.expectEqual(full[y * 32 + 16 + x], part[y * 16 + x]);
    }
}

test "the label colour flips at mid grey, as the palette needs" {
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), contrastColor(0xFF8C8C8C));
    try std.testing.expectEqual(@as(u32, 0xFF1A1A1A), contrastColor(0xFF8D8D8D));
    const white = [_]u32{ 0xFFFF453A, 0xFF0A84FF, 0xFFBF5AF2, 0xFF1C1C1E, 0xFFFF375F };
    for (white) |c| try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), contrastColor(c));
    const dark = [_]u32{ 0xFFFF9F0A, 0xFFFFD60A, 0xFF30D158, 0xFFFFFFFF, 0xFF64D2FF, 0xFF8E8E93 };
    for (dark) |c| try std.testing.expectEqual(@as(u32, 0xFF1A1A1A), contrastColor(c));
}

test "a ring is the band between its outer and inner edges" {
    var px: [20 * 20]u32 = @splat(0xFF000000);
    var cv = Canvas.init(&px, 20, 20);
    roundRectRing(&cv, .{ .x = 2, .y = 2, .w = 16, .h = 16 }, 4, 2, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 20 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 20 + 3]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[10 * 20 + 4]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[10 * 20 + 1]);
    // thicker than half the rect: filled
    roundRectRing(&cv, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, 0, 3, 0xFFFF0000);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), px[1 * 20 + 1]);
}
