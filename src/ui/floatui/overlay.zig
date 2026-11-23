//! Controls drawn over a picture (thumbnails, the quick video card,
//! pins, history): a notice in the middle, round dark buttons, pill
//! buttons, and dark status pills. They sit on the capture, so their
//! colours are the theme's overlay tokens (the same in light and dark),
//! the accent excepted. Sizes are logical times the scale `k`.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const barkit = @import("../barkit.zig");
const scale = @import("../scale.zig");
const Rect = @import("../shapes.zig").Rect;

const Canvas = render.Canvas;
const Theme = theme.Theme;
const px = scale.px;
const ff = scale.ff;

/// A control's state.
pub const State = struct {
    /// under the pointer
    hot: bool = false,
    /// unavailable: drawn dimmed, never hot
    dim: bool = false,
    /// has the keyboard focus: the focus ring
    focused: bool = false,
};

/// Text centred in `r` (vertically by line height).
fn centred(cv: *Canvas, r: Rect, size: f64, color: u32, style: text.Style, s: []const u8) void {
    const tw = text.widthStyled(size, style, s);
    const th = text.heightStyled(size, style);
    text.drawStyled(cv, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - th, 2), size, color, style, s);
}

/// A notice's pill for `s` centred in `area` (`check`: room for the
/// check before it).
fn noticeRect(area: Rect, s: []const u8, check: bool, k: f64) Rect {
    const lead = if (check) px(14 + 6, k) else 0;
    const w = text.widthStyled(13 * k, .semibold, s) + lead + px(28, k);
    const h = px(30, k);
    return .{ .x = area.x + @divTrunc(area.w - w, 2), .y = area.y + @divTrunc(area.h - h, 2), .w = w, .h = h };
}

/// A short message ("Copied", "Failed") in a dark pill centred in `area`.
pub fn notice(cv: *Canvas, area: Rect, s: []const u8, k: f64, th: Theme) void {
    const r = noticeRect(area, s, false, k);
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, ff(r.h) / 2, th.scrim_notice);
    centred(cv, r, 13 * k, th.on_scrim, .semibold, s);
}

/// A notice that something is done ("Saved"): a check before the words.
pub fn noticeDone(cv: *Canvas, area: Rect, s: []const u8, k: f64, th: Theme) void {
    const r = noticeRect(area, s, true, k);
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, ff(r.h) / 2, th.scrim_notice);
    const is = 14 * k;
    const x = r.x + px(14, k);
    icons.drawAt(cv, .check, ff(x) + is / 2, ff(r.y) + ff(r.h) / 2, is, .{}, th.on_scrim);
    const fs = 13 * k;
    text.drawStyled(cv, x + px(14 + 6, k), r.y + @divTrunc(r.h - text.heightStyled(fs, .semibold), 2), fs, th.on_scrim, .semibold, s);
}

/// A round dark button of radius `r` (physical px) centred on cx, cy,
/// with a white `icon` at its own stroke (icons.defaultStroke).
pub fn roundButton(cv: *Canvas, cx: f64, cy: f64, r: f64, icon: icons.Icon, st: State, k: f64, th: Theme) void {
    cv.fillCircleAA(cx, cy, r, if (st.hot and !st.dim) th.round_btn_hover else th.round_btn);
    icons.drawAt(cv, icon, cx, cy, 14 * k, .{}, if (st.dim) th.on_scrim_dim else th.on_scrim);
    if (st.focused) barkit.focusRingRound(cv, cx, cy, r, k, th.accent);
}

/// A pill button's look: the accent (the card's main action) or light.
pub const PillLook = enum { primary, light };

/// A pill button in `r` labelled `label` (semibold, `size` logical px).
pub fn pillButton(cv: *Canvas, r: Rect, label: []const u8, look: PillLook, size: f64, st: State, k: f64, th: Theme) void {
    const rad = 8 * k;
    const hot = st.hot and !st.dim;
    const bg, const fg = switch (look) {
        .primary => .{ if (hot) th.accent_fill_hover else th.accent_fill, th.on_accent },
        .light => .{ if (hot) th.light_pill_hover else th.light_pill, th.light_pill_fg },
    };
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, bg);
    centred(cv, r, size * k, if (st.dim) theme.fade(fg, 0.5) else fg, .semibold, label);
    if (st.focused) barkit.focusRing(cv, r, rad, k, th.accent);
}

/// a status pill's height and font size, logical px
pub const scrim_pill_h = 24;
const scrim_font = 12;

/// The width of a status pill showing `label` after `lead`.
pub fn scrimPillWidth(label: []const u8, lead: ?icons.Icon, k: f64) i32 {
    const lead_w = if (lead != null) px(14 + 4, k) else 0;
    return px(10, k) + lead_w + text.widthStyled(scrim_font * k, .semibold, label) + px(10, k);
}

/// A dark status pill in `r` (scrimPillWidth wide, scrim_pill_h tall):
/// an optional `lead` icon and a white semibold `label`.
pub fn scrimPill(cv: *Canvas, r: Rect, label: []const u8, lead: ?icons.Icon, level: theme.Scrim, k: f64, th: Theme) void {
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, ff(r.h) / 2, th.scrim(level));
    var x = r.x + px(10, k);
    if (lead) |ic| {
        const is = 14 * k;
        icons.drawAt(cv, ic, ff(x) + is / 2, ff(r.y) + ff(r.h) / 2, is, .{}, th.on_scrim);
        x += px(14 + 4, k);
    }
    const fs = scrim_font * k;
    text.drawStyled(cv, x, r.y + @divTrunc(r.h - text.heightStyled(fs, .semibold), 2), fs, th.on_scrim, .semibold, label);
}

const testing = std.testing;

fn lit(buf: []const u32, bg: u32) usize {
    var n: usize = 0;
    for (buf) |p| n += @intFromBool(p != bg);
    return n;
}

test "overlay controls draw in place" {
    const th = Theme.get(true, null);
    var buf: [120 * 60]u32 = undefined;
    var cv = Canvas.init(&buf, 120, 60);
    const bg: u32 = 0xFF808080;
    @memset(&buf, bg);
    notice(&cv, .{ .x = 0, .y = 0, .w = 120, .h = 60 }, "Copied", 1, th);
    try testing.expectEqual(bg, buf[0]);
    try testing.expect(buf[30 * 120 + 60] != bg);
    @memset(&buf, bg);
    roundButton(&cv, 20, 20, 13, .close, .{}, 1, th);
    const plain = lit(&buf, bg);
    @memset(&buf, bg);
    roundButton(&cv, 20, 20, 13, .close, .{ .focused = true }, 1, th);
    try testing.expect(lit(&buf, bg) > plain); // the focus ring
    for ([_]PillLook{ .primary, .light }) |look| {
        @memset(&buf, bg);
        pillButton(&cv, .{ .x = 10, .y = 10, .w = 80, .h = 28 }, "Copy", look, 13, .{ .hot = true }, 1, th);
        try testing.expect(buf[12 * 120 + 50] != bg);
    }
    @memset(&buf, bg);
    const w = scrimPillWidth("Saved", .check, 1);
    try testing.expect(w > scrimPillWidth("Saved", null, 1));
    scrimPill(&cv, .{ .x = 4, .y = 4, .w = w, .h = scrim_pill_h }, "Saved", .check, .pill, 1, th);
    try testing.expect(buf[16 * 120 + 6] != bg);
}
