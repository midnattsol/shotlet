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
//!   premultiply(px, w, h, r), fadeAlpha(px, f), blitOver(...), clipRect
//!   textCentered(canvas, r, size, color, style, s)
//!   Surface, Image                      a straight-alpha buffer; pixels to read
//!   place(gpa, dst, card, at, radius, shadow, k)   an opaque card with
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
const text = @import("../gfx/text.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const card = @import("floatui/card.zig");
const overlay = @import("floatui/overlay.zig");

pub const Canvas = render.Canvas;
pub const Rect = effects.Rect;

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
pub const roundButton = overlay.roundButton;
pub const PillLook = overlay.PillLook;
pub const pillButton = overlay.pillButton;
pub const scrimPill = overlay.scrimPill;
pub const scrimPillWidth = overlay.scrimPillWidth;
pub const scrim_pill_h = overlay.scrim_pill_h;

// TODO(wave 2): remove the palette below; use the theme's overlay tokens
// (scrim, round_btn, light_pill, on_scrim) and Theme.accent_fill.

/// Palette of the floating UI (dark glass, as on macOS)
pub const veil: u32 = 0x6B000000;
/// round buttons over a picture: dark discs, so their white icons read
/// on any capture (7:1 over white under the veil; 9.9:1 hovered)
pub const btn_round: u32 = 0x66000000;
pub const btn_round_hover: u32 = 0x8C000000;
pub const pill: u32 = 0xEBFFFFFF;
pub const pill_hover: u32 = 0xFFFFFFFF;
pub const pill_text: u32 = 0xFF1D1D1F;
pub const white: u32 = 0xFFFFFFFF;
pub const accent: u32 = 0xFF0A84FF;
pub const card_bg: u32 = 0xFF2A2E37;
pub const shadow: u32 = 0x48000000;

/// Panel colours for light and dark (history panel, pin frame)
/// TODO(wave 2): remove; use theme.Opaque.of(theme.Theme).
pub const Theme = struct {
    panel: u32,
    fg: u32,
    muted: u32,
    field: u32,
    line: u32,
    hover: u32,

    accent: u32 = accent,

    /// From the desktop's preferences (ui/theme.zig): the Glass panel
    /// made opaque (there is no backdrop blur for a client to use).
    pub fn fromPrefs(p: theme.Prefs) Theme {
        const o = theme.Opaque.of(theme.of(p));
        return .{ .panel = o.panel, .fg = o.fg, .muted = o.muted, .field = o.field, .line = o.line, .hover = o.hover, .accent = o.accent };
    }

    pub const dark: Theme = .{ .panel = 0xFF242426, .fg = 0xFFF5F5F7, .muted = 0xFF9E9EA6, .field = 0xFF323235, .line = 0xFF3A3A3D, .hover = 0xFF2F2F33 };
    pub const light: Theme = .{ .panel = 0xFFFAFAFC, .fg = 0xFF1D1D1F, .muted = 0xFF6E6E73, .field = 0xFFEDEDF0, .line = 0xFFDCDCE0, .hover = 0xFFF0F0F3 };
};

pub fn clipRect(r: Rect, w: u32, h: u32) ?Rect {
    return effects.clip(r, w, h);
}

/// Straight to premultiplied alpha, in place, over `r`.
pub fn premultiply(px: []u32, w: u32, h: u32, r: Rect) void {
    const c = effects.clip(r, w, h) orelse return;
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
    const c = effects.clip(.{ .x = x, .y = y, .w = @intCast(sw), .h = @intCast(sh) }, dw, dh) orelse return;
    var yy = c.y;
    while (yy < c.y + c.h) : (yy += 1) {
        const sy: usize = @intCast(yy - y);
        const sx: usize = @intCast(c.x - x);
        const drow = dst[@as(usize, @intCast(yy)) * dw + @as(usize, @intCast(c.x)) ..][0..@intCast(c.w)];
        const srow = src[sy * sw + sx ..][0..@intCast(c.w)];
        for (drow, srow) |*d, s| d.* = effects.over(d.*, s);
    }
}

/// An opaque card (content in `card`) with rounded corners and a soft
/// shadow, onto a straight-alpha buffer.
/// TODO(wave 2): remove; use place (theme shadows).
pub fn placeCard(dst: []u32, dw: u32, dh: u32, card_px: []const u32, cw: u32, ch: u32, x: i32, y: i32, radius: u32, shadow_px: u32) void {
    if (shadow_px > 0) {
        effects.dropShadow(dst, dw, dh, .{ .x = x, .y = y, .w = @intCast(cw), .h = @intCast(ch) }, shadow_px, @intCast(shadow_px / 3), shadow);
    }
    effects.blitRounded(dst, dw, dh, card_px, cw, ch, x, y, radius);
}

/// Draw `src` scaled to cover (or, for very different shapes, to fit in)
/// the whole of `dst`, over a dark backdrop.
/// TODO(wave 2): remove; use drawImage or FitCache with .auto.
pub fn drawImageFill(gpa: std.mem.Allocator, dst: []u32, dw: u32, dh: u32, src: []const u32, sw: u32, sh: u32) void {
    drawImage(gpa, .{ .px = dst, .w = dw, .h = dh }, .{ .px = src, .w = sw, .h = sh }, .auto, card_bg);
}

/// TODO(wave 2): remove; use icons.Icon with icons.drawAt (or roundButton).
pub const Icon = enum { close, pencil, pin, search, trash, copy, save, check };

/// A line icon (the editor's set, ui/icons.zig, a little heavier) in a
/// `size` box centred on cx, cy.
pub fn icon(c: *Canvas, kind: Icon, cx: f64, cy: f64, size: f64, color: u32) void {
    const ic: icons.Icon = switch (kind) {
        .close => .close,
        .pencil => .pen,
        .pin => .pin,
        .search => .search,
        .trash => .trash,
        .copy => .copy,
        .save => .save,
        .check => .check,
    };
    const stroke: f64 = if (kind == .close or kind == .check) 2.4 else 2;
    icons.drawAt(c, ic, cx, cy, size, .{ .stroke = stroke }, color);
}

/// Text centred in `r` (vertically by line height).
pub fn textCentered(c: *Canvas, r: @import("shapes.zig").Rect, size: f64, color: u32, style: text.Style, s: []const u8) void {
    const tw = text.widthStyled(size, style, s);
    const th = text.heightStyled(size, style);
    text.drawStyled(c, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - th, 2), size, color, style, s);
}

/// `s` cut with "..." to fit `max_w` pixels.
/// TODO(wave 2): remove; use text.ellipsize, measuring in the style drawn.
pub fn ellipsize(buf: []u8, size: f64, s: []const u8, max_w: i32) []const u8 {
    if (text.width(size, s) <= max_w) return s;
    var n = s.len;
    while (n > 0) {
        n -= 1;
        while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
        const out = std.fmt.bufPrint(buf, "{s}...", .{s[0..n]}) catch return s;
        if (text.width(size, out) <= max_w) return out;
    }
    return "...";
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

test {
    _ = card;
    _ = overlay;
    // the shared UI modules (no other test root reaches them yet)
    _ = @import("scale.zig");
    _ = @import("press.zig");
    _ = @import("focus.zig");
    _ = @import("floatwin.zig");
    _ = @import("badge.zig");
    _ = @import("menukit.zig");
    _ = @import("material.zig");
}
