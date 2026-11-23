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
//!   TextLook, Face, Mark            the one labelled button and its looks:
//!   button(canvas, r, f, th, look, hover, face)   bars, dialogs and HUDs
//!                                    (primary, secondary, destructive) and
//!                                    windows (Settings: list, tab)
//!   faceWidth(f, look, face), labelFont(f, look, face)   its content's size
//!   textButtonWidth(f, label), textButton(canvas, r, f, th, look, hover,
//!                                    label)   a centred label alone
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
    /// an action in a window's boxed list (Settings: the folder, Reset
    /// permissions, After Save…, a stepper's − and +): the window's chip
    /// fill and text colour, regular weight unless `Face.strong`
    list,
    /// a view switcher's tab (Settings' header): no fill until hovered,
    /// the selection's fill when `Face.on`; semibold
    tab,
};

/// What a button shows. Sizes are logical px.
pub const Face = struct {
    label: []const u8 = "",
    /// before the label, or alone
    mark: ?Mark = null,
    /// a semibold label (bars and dialogs always are; `list` is not)
    strong: bool = false,
    /// the content starts this far in from the left edge; null: centred
    inset: ?f64 = null,
    /// a disc as wide as the rect instead of a rounded rectangle
    round: bool = false,
    /// a tab that is chosen
    on: bool = false,
};

/// A glyph before a button's label, or alone on it.
pub const Mark = struct {
    glyph: Glyph,
    size: f64 = 16,
    /// the icon's stroke, in 24-unit icon space
    stroke: f64 = 2,

    pub const Glyph = union(enum) {
        icon: icons.Icon,
        /// a stepper's minus: the plus icon's horizontal stroke
        minus,
    };
};

const text_pad = 14;
/// the window looks (list, tab): corner radius and type size, and the
/// gap between a mark and the label
pub const window_radius = 8;
const window_font = 14;
const mark_gap = 8;

/// The size and weight a look draws `face`'s label in (physical px).
pub fn labelFont(f: f64, look: TextLook, face: Face) struct { size: f64, style: text.Style } {
    return switch (look) {
        .list => .{ .size = window_font * f, .style = if (face.strong) .semibold else .regular },
        .tab => .{ .size = window_font * f, .style = .semibold },
        .primary, .secondary, .destructive => .{ .size = theme.font_label * f, .style = .semibold },
    };
}

/// The width of a face's content: its mark, the gap and its label.
pub fn faceWidth(f: f64, look: TextLook, face: Face) i32 {
    const lf = labelFont(f, look, face);
    const tw = if (face.label.len > 0) text.widthStyled(lf.size, lf.style, face.label) else 0;
    const ms = if (face.mark) |m| sc(m.size, f) else 0;
    const gap = if (face.mark != null and face.label.len > 0) sc(mark_gap, f) else 0;
    return ms + gap + tw;
}

/// The width of a text button with `label`.
pub fn textButtonWidth(f: f64, label: []const u8) i32 {
    return text.widthStyled(theme.font_label * f, .semibold, label) + 2 * sc(text_pad, f);
}

/// A button with a centred semibold `label`, `hover` (0..1) over it, on
/// any surface (the secondary tint is translucent).
pub fn textButton(cv: *Canvas, r: Rect, f: f64, th: Theme, look: TextLook, hover: f64, label: []const u8) void {
    button(cv, r, f, th, look, hover, .{ .label = label });
}

/// A button in `look` showing `face`, `hover` (0..1) over it.
pub fn button(cv: *Canvas, r: Rect, f: f64, th: Theme, look: TextLook, hover: f64, face: Face) void {
    const h = std.math.clamp(hover, 0, 1);
    const p = paintOf(th, look, face, h);
    const rad = (if (look == .list or look == .tab) window_radius else theme.button_radius) * f;
    if (p.bg) |bg| shape(cv, r, rad, face.round, bg);
    if (p.tint) |t| shape(cv, r, rad, face.round, t);
    drawFace(cv, r, f, look, face, p.ink);
}

const Paint = struct { bg: ?u32 = null, tint: ?u32 = null, ink: u32 };

fn paintOf(th: Theme, look: TextLook, face: Face, h: f64) Paint {
    return switch (look) {
        .primary => .{ .bg = theme.mix(th.accent_fill, th.accent_fill_hover, h), .ink = th.on_accent },
        .destructive => .{ .bg = theme.mix(theme.destructive_fill, theme.destructive_fill_hover, h), .ink = 0xFFFFFFFF },
        .secondary => .{ .bg = th.pressed, .tint = if (h > 0) theme.fade(th.hover, h) else null, .ink = th.fg },
        .list => .{ .bg = if (h > 0) theme.mix(th.chip, th.switch_off, 0.8 * h) else th.chip, .ink = th.text },
        .tab => .{ .bg = if (face.on) th.view_sel else if (h > 0) theme.fade(th.view_sel, 0.6 * h) else null, .ink = th.text },
    };
}

fn shape(cv: *Canvas, r: Rect, radius: f64, round: bool, color: u32) void {
    if (!round) return cv.fillRoundRectAA(r.x, r.y, r.w, r.h, radius, color);
    const rr = @as(f64, @floatFromInt(r.w)) / 2;
    cv.fillCircleAA(@as(f64, @floatFromInt(r.x)) + rr, @as(f64, @floatFromInt(r.y)) + rr, rr, color);
}

/// The mark and the label, from `face.inset` or centred in `r`.
fn drawFace(cv: *Canvas, r: Rect, f: f64, look: TextLook, face: Face, fg: u32) void {
    const lf = labelFont(f, look, face);
    var x = if (face.inset) |i| r.x + sc(i, f) else r.x + @divTrunc(r.w - faceWidth(f, look, face), 2);
    if (face.mark) |m| {
        const ms = sc(m.size, f);
        switch (m.glyph) {
            .icon => |ic| icons.drawStroke(cv, ic, x, r.y + @divTrunc(r.h - ms, 2), ms, m.stroke, fg),
            .minus => cv.fillRoundRectAA(x + sc(2, f), r.y + @divTrunc(r.h, 2) - sc(1, f), ms - sc(4, f), @max(2, sc(2, f)), 1, fg),
        }
        x += ms + sc(mark_gap, f);
    }
    if (face.label.len == 0) return;
    text.drawStyled(cv, x, r.y + @divTrunc(r.h - text.heightStyled(lf.size, lf.style), 2), lf.size, fg, lf.style, face.label);
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

test "the window looks: chip fill, lighter when hovered; marks alone are centred" {
    const th = Theme.get(false, null);
    var px: [40 * 40]u32 = @splat(0xFFFFFFFF);
    var cv = Canvas.init(&px, 40, 40);
    const r: Rect = .{ .x = 3, .y = 3, .w = 34, .h = 34 };
    button(&cv, r, 1, th, .list, 0, .{ .mark = .{ .glyph = .minus } });
    try std.testing.expectEqual(Canvas.blendPixel(0xFFFFFFFF, th.chip), px[6 * 40 + 6]);
    // the minus: a bar across the middle, nothing above it
    try std.testing.expect(px[20 * 40 + 20] != px[6 * 40 + 6]);
    try std.testing.expectEqual(px[6 * 40 + 6], px[14 * 40 + 20]);
    @memset(&px, 0xFFFFFFFF);
    button(&cv, r, 1, th, .list, 1, .{ .mark = .{ .glyph = .{ .icon = .plus } } });
    try std.testing.expectEqual(Canvas.blendPixel(0xFFFFFFFF, theme.mix(th.chip, th.switch_off, 0.8)), px[6 * 40 + 6]);
    try std.testing.expect(px[17 * 40 + 20] != px[6 * 40 + 6]);
    // a tab shows no fill until hovered or chosen
    @memset(&px, 0xFFFFFFFF);
    button(&cv, r, 1, th, .tab, 0, .{});
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), px[6 * 40 + 6]);
    button(&cv, r, 1, th, .tab, 0, .{ .on = true });
    try std.testing.expectEqual(Canvas.blendPixel(0xFFFFFFFF, th.view_sel), px[6 * 40 + 6]);
    // a mark and a label: the mark, the gap, the label
    const face: Face = .{ .label = "Ok", .mark = .{ .glyph = .{ .icon = .folder } } };
    try std.testing.expectEqual(16 + 8 + faceWidth(1, .list, .{ .label = "Ok" }), faceWidth(1, .list, face));
    try std.testing.expect(std.meta.eql(labelFont(1, .list, .{ .strong = true }).style, text.Style.semibold));
    try std.testing.expect(std.meta.eql(labelFont(1, .list, .{}).style, text.Style.regular));
}

test "a bar icon centred by icons.drawAt sits where integer centring put it, at 100, 125, 150 and 200 %" {
    // (editor_ui/draw_toolbar.zig drawIconIn: a square button of
    // theme.button, an icon of theme.icon)
    defer icons.deinit();
    for ([_]f64{ 1, 1.25, 1.5, 2 }) |f| {
        const btn = sc(theme.button, f);
        const r: Rect = .{ .x = 7, .y = 5, .w = btn, .h = btn };
        var a: [80 * 80]u32 = @splat(0xFF000000);
        var b: [80 * 80]u32 = @splat(0xFF000000);
        var ca = Canvas.init(&a, 80, 80);
        var cb = Canvas.init(&b, 80, 80);
        const s = sc(theme.icon, f);
        icons.draw(&ca, .pen, r.x + @divTrunc(r.w - s, 2), r.y + @divTrunc(r.h - s, 2), s, 0xFFFFFFFF);
        const ff = @import("scale.zig").ff;
        icons.drawAt(&cb, .pen, ff(r.x) + ff(r.w) / 2, ff(r.y) + ff(r.h) / 2, theme.icon * f, .{}, 0xFFFFFFFF);
        try std.testing.expectEqualSlices(u32, &a, &b);
    }
}
