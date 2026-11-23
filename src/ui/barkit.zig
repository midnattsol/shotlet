//! The controls of every floating bar (the editor's toolbar, its beautify
//! and crop bars, the record picker's bar), drawn one way: square or
//! text buttons on the bar's material, a separator between groups, and
//! one prominent button that does the bar's job (Copy, Crop, Record).
//! Sizes are the theme's metrics (ui/theme.zig) times the scale `f`.
//!
//! Stable API:
//!   Look                             how a button shows its state
//!   fill(canvas, r, f, th, look, hover)   its background
//!   ink(th, look, disabled)               its icon or label colour
//!   Lead, primaryWidth(f, label), primary(canvas, r, f, colours, lead, label)
//!   separator(canvas, x, y, h, th)
//!   TextLook, textButtonWidth(f, label), textButton(canvas, r, f, th, look,
//!                                    hover, label)   a labelled button
//!                                    (dialogs, HUDs, confirmations)
//!   focusRing(canvas, r, radius, f, accent)   the keyboard focus ring
//!                                    around a control with corner `radius`
//!   focusRingRound(canvas, cx, cy, radius, f, accent)   around a disc

const std = @import("std");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const shapes = @import("shapes.zig");
const Rect = shapes.Rect;

const Canvas = render.Canvas;
const Theme = theme.Theme;

pub const Look = enum {
    /// nothing to show but hover
    plain,
    /// held down: its popover or menu is open, or its segment is chosen
    pressed,
    /// an option that is on (Shadow, Microphone, 16:9): pressed, accent ink
    toggled,
    /// the active tool: the accent itself
    selected,
};

/// The background of a button in `look`, `hover` (0..1) over it.
pub fn fill(cv: *Canvas, r: Rect, f: f64, th: Theme, look: Look, hover: f64) void {
    const rad = theme.button_radius * f;
    switch (look) {
        .selected => cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.accent_fill),
        .pressed, .toggled => cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.pressed),
        .plain => {},
    }
    if (hover > 0 and look != .selected) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hover));
}

/// The colour of a button's icon or label.
pub fn ink(th: Theme, look: Look, disabled: bool) u32 {
    if (disabled) return th.muted;
    return switch (look) {
        .selected => th.on_accent,
        .toggled => th.accent_text,
        .plain, .pressed => th.fg,
    };
}

/// What leads a prominent button's label.
pub const Lead = union(enum) {
    icon: icons.Icon,
    /// a filled dot (Record)
    dot,
};

const lead_px = 16;

/// The width of a prominent button with `label`.
pub fn primaryWidth(f: f64, label: []const u8) i32 {
    return sc(10 + lead_px + 6, f) + text.widthStyled(theme.font_label * f, .semibold, label) + sc(14, f);
}

/// The prominent button: `bg` filled, `lead` and a bold `label` in `fg`.
pub fn primary(cv: *Canvas, r: Rect, f: f64, bg: u32, fg: u32, lead: Lead, label: []const u8) void {
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, theme.button_radius * f, bg);
    const is = sc(lead_px, f);
    const lx = r.x + sc(10, f);
    switch (lead) {
        .icon => |ic| icons.draw(cv, ic, lx, r.y + @divTrunc(r.h - is, 2), is, fg),
        .dot => {
            const rr = 5 * f;
            cv.fillCircleAA(@as(f64, @floatFromInt(lx)) + @as(f64, @floatFromInt(is)) / 2, @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h)) / 2, rr, fg);
        },
    }
    const fs = theme.font_label * f;
    text.drawStyled(cv, lx + is + sc(6, f), r.y + @divTrunc(r.h - text.heightStyled(fs, .semibold), 2), fs, fg, .semibold, label);
}

/// A group separator 1 px wide at x, from y, `h` tall.
pub fn separator(cv: *Canvas, x: i32, y: i32, h: i32, th: Theme) void {
    cv.fillRect(x, y, 1, h, th.hairline);
}

/// How a text button shows what it does.
pub const TextLook = enum {
    /// the window's job (Save, Done): the accent
    primary,
    /// anything else (Cancel): a quiet tint of the surface
    secondary,
    /// it destroys something (Delete): red
    destructive,
};

const text_pad = 14;

/// The width of a text button with `label`.
pub fn textButtonWidth(f: f64, label: []const u8) i32 {
    return text.widthStyled(theme.font_label * f, .semibold, label) + 2 * sc(text_pad, f);
}

/// A button with a centred semibold `label`, `hover` (0..1) over it, on
/// any surface (the secondary tint is translucent).
pub fn textButton(cv: *Canvas, r: Rect, f: f64, th: Theme, look: TextLook, hover: f64, label: []const u8) void {
    const rad = theme.button_radius * f;
    const h = std.math.clamp(hover, 0, 1);
    const bg, const fg = switch (look) {
        .primary => .{ theme.mix(th.accent_fill, th.accent_fill_hover, h), th.on_accent },
        .destructive => .{ theme.mix(theme.destructive_fill, theme.destructive_fill_hover, h), 0xFFFFFFFF },
        .secondary => .{ th.pressed, th.fg },
    };
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, bg);
    if (look == .secondary and h > 0) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, h));
    const fs = theme.font_label * f;
    const tw = text.widthStyled(fs, .semibold, label);
    text.drawStyled(cv, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - text.heightStyled(fs, .semibold), 2), fs, fg, .semibold, label);
}

/// The keyboard focus ring: theme.focus_w wide, theme.focus_gap outside
/// the control `r` whose corners are rounded to `radius`.
pub fn focusRing(cv: *Canvas, r: Rect, radius: f64, f: f64, accent: u32) void {
    const g = sc(theme.focus_gap, f);
    const fw = theme.focus_w * f;
    const rr = r.expand(g + @as(i32, @intFromFloat(@ceil(fw / 2))));
    shapes.roundRectRing(cv, rr, radius + @as(f64, @floatFromInt(g)) + fw / 2, fw, accent);
}

/// The focus ring around a disc of `radius` centred on cx, cy.
pub fn focusRingRound(cv: *Canvas, cx: f64, cy: f64, radius: f64, f: f64, accent: u32) void {
    const fw = theme.focus_w * f;
    cv.ringAA(cx, cy, radius + theme.focus_gap * f + fw / 2, fw, accent);
}

fn sc(v: f64, f: f64) i32 {
    return @intFromFloat(@round(v * f));
}

test "a prominent button fits its label and the inks read on their fills" {
    const th = Theme.get(false, null);
    try std.testing.expect(primaryWidth(1, "Record") > primaryWidth(1, "Crop"));
    try std.testing.expectEqual(th.on_accent, ink(th, .selected, false));
    try std.testing.expectEqual(th.accent_text, ink(th, .toggled, false));
    try std.testing.expectEqual(th.muted, ink(th, .toggled, true));
}

test "text buttons and focus rings draw where they should" {
    const th = Theme.get(true, null);
    var px: [60 * 40]u32 = @splat(th.window_bg);
    var cv = Canvas.init(&px, 60, 40);
    const r: Rect = .{ .x = 10, .y = 10, .w = 40, .h = 20 };
    for ([_]TextLook{ .primary, .secondary, .destructive }) |look| {
        @memset(&px, th.window_bg);
        textButton(&cv, r, 1, th, look, 1, "Ok");
        try std.testing.expect(px[11 * 60 + 30] != th.window_bg);
        try std.testing.expectEqual(th.window_bg, px[0]);
    }
    try std.testing.expect(textButtonWidth(1, "Cancel") > textButtonWidth(1, "Ok"));
    @memset(&px, 0xFF000000);
    focusRing(&cv, r, 6, 1, 0xFFFFFFFF);
    // the ring sits outside the control, not on it
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[20 * 60 + 30]);
    try std.testing.expect(px[(r.y - 3) * 60 + 30] != 0xFF000000);
    @memset(&px, 0xFF000000);
    focusRingRound(&cv, 30, 20, 8, 1, 0xFFFFFFFF);
    try std.testing.expectEqual(@as(u32, 0xFF000000), px[20 * 60 + 30]);
    try std.testing.expect(px[20 * 60 + 41] != 0xFF000000);
}
