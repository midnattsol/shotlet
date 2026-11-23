//! Drawing helpers for the floating windows (quick-access thumbnails,
//! pins, the history panel): see-through surfaces, cards with soft
//! shadows, small line icons and buttons.
//!
//! Transparent surfaces are drawn in straight alpha (effects.over handles
//! a see-through destination) and converted with premultiply() just
//! before presenting, as wl_shm's argb8888 wants. Canvas drawing assumes
//! an opaque destination, so content goes into opaque card buffers first
//! and the card is then placed with its rounded corners.
//!
//! Stable API:
//!   premultiply(px, w, h, r), fadeAlpha(px, f), blitOver(...)
//!   textCentered(canvas, r, size, color, style, s)
//!   Surface, Image                      a straight-alpha buffer; pixels to read
//!   place(dst, card, at, radius, shadow, k)   an opaque card with
//!                                       rounded corners and a theme.Shadow
//!   compositeFaded(gpa, dst, card, at, radius, shadow, alpha, k)   the same,
//!                                       faded as a whole
//!   FitMode, fitPlan, drawImage(gpa, dst, src, mode, bg), FitCache
//!                                       a picture fitted to a card, cached
//!   DragOut, dragIcon(gpa, src, w, h, k)   dragging a file out of a card
//!   State, notice, roundButton, PillLook, pillButton, scrimPill,
//!   scrimPillWidth, scrim_pill_h        controls over a picture (overlay.zig)

const std = @import("std");
const render = @import("../gfx/render.zig");
const effects = @import("../gfx/effects.zig");
const Rect = @import("../geom.zig").Rect;
const text = @import("../gfx/text.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const card = @import("floatui/card.zig");
const overlay = @import("floatui/overlay.zig");

pub const Canvas = render.Canvas;

pub const Surface = card.Surface;
pub const Image = card.Image;
pub const place = card.place;
pub const compositeFaded = card.compositeFaded;
pub const FitMode = card.FitMode;
pub const fitPlan = card.fitPlan;
pub const drawImage = card.drawImage;
pub const FitCache = card.FitCache;
pub const DragOut = card.DragOut;
pub const dragIcon = card.dragIcon;

pub const State = overlay.State;
pub const notice = overlay.notice;
pub const noticeLink = overlay.noticeLink;
pub const noticeRect = overlay.noticeRect;
pub const roundButton = overlay.roundButton;
pub const PillLook = overlay.PillLook;
pub const pillButton = overlay.pillButton;
pub const scrimPill = overlay.scrimPill;
pub const scrimPillWidth = overlay.scrimPillWidth;
pub const scrim_pill_h = overlay.scrim_pill_h;

/// Straight to premultiplied alpha, in place, over `r`.
pub fn premultiply(px: []u32, w: u32, h: u32, r: Rect) void {
    const c = r.clip(w, h) orelse return;
    var y = c.y;
    while (y < c.y + c.h) : (y += 1) {
        const row = px[@as(usize, @intCast(y)) * w + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        for (row) |*p| {
            const a = p.* >> 24;
            if (a == 255) continue;
            if (a == 0) {
                p.* = 0;
                continue;
            }
            p.* = scaleRgb(p.*, a) | (a << 24);
        }
    }
}

fn scaleRgb(p: u32, a: u32) u32 {
    const r = ((p >> 16) & 0xFF) * a / 255;
    const g = ((p >> 8) & 0xFF) * a / 255;
    const b = (p & 0xFF) * a / 255;
    return (r << 16) | (g << 8) | b;
}

/// Multiply straight-alpha pixels' alpha by `f` (0..1): fading.
pub fn fadeAlpha(px: []u32, f: f64) void {
    if (f >= 1.0) return;
    const k: u32 = @intFromFloat(std.math.clamp(f, 0, 1) * 256);
    for (px) |*p| p.* = (((p.* >> 24) * k >> 8) << 24) | (p.* & 0xFFFFFF);
}

/// `src` (straight alpha, sw x sh) over `dst` at x, y.
pub fn blitOver(dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32, x: i32, y: i32) void {
    const c = Rect.clip(.{ .x = x, .y = y, .w = @intCast(sw), .h = @intCast(sh) }, dw, dh) orelse return;
    var yy = c.y;
    while (yy < c.y + c.h) : (yy += 1) {
        const sy: usize = @intCast(yy - y);
        const sx: usize = @intCast(c.x - x);
        const drow = dst[@as(usize, @intCast(yy)) * dw + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        const srow = src[sy * sw + sx ..][0..@intCast(c.w)];
        for (drow, srow) |*d, s| d.* = effects.over(d.*, s);
    }
}

/// Text centred in `r` (vertically by line height).
pub fn textCentered(c: *Canvas, r: Rect, size: f64, color: u32, style: text.Style, s: []const u8) void {
    const tw = text.widthStyled(size, style, s);
    const th = text.heightStyled(size, style);
    text.drawStyled(c, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - th, 2), size, color, style, s);
}

test "premultiply and fades keep opaque pixels and clear transparent ones" {
    var px = [_]u32{ 0xFF102030, 0x80FF0000, 0x00FFFFFF, 0x40000000 };
    premultiply(&px, 4, 1, .{ .x = 0, .y = 0, .w = 4, .h = 1 });
    try std.testing.expectEqual(@as(u32, 0xFF102030), px[0]);
    try std.testing.expectEqual(@as(u32, 0x80800000), px[1]);
    try std.testing.expectEqual(@as(u32, 0), px[2]);
    try std.testing.expectEqual(@as(u32, 0x40000000), px[3]);
    var f = [_]u32{ 0xFF123456, 0x80FFFFFF };
    fadeAlpha(&f, 0.5);
    try std.testing.expectEqual(@as(u32, 0x7F), f[0] >> 24);
    try std.testing.expectEqual(@as(u32, 0x123456), f[0] & 0xFFFFFF);
    try std.testing.expectEqual(@as(u32, 0x40), f[1] >> 24);
}

comptime {
    _ = card;
    _ = overlay;
}
