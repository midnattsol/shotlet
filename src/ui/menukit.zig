//! The small controls of menus, popovers and forms, drawn one way (the
//! editor's popovers and menus, the pin's menu, Settings): menu rows,
//! segmented controls, colour swatches, slider knobs and key caps. Sizes
//! are logical times the scale `f`; colours come from the theme.
//!
//! Stable API:
//!   Row, RowState, menuRow(canvas, r, f, th, row, state)
//!                                    icon, label and shortcut; the accent
//!                                    under the hot row
//!   segTrough(canvas, r, f, th)      a segmented control's trough
//!   segment(canvas, r, f, th, label, on, hover)   one segment in it
//!   swatch(canvas, cx, cy, radius, color, f, th, selected, hover)
//!   knob(canvas, cx, cy, radius, f)  a slider's white knob with its shadow
//!   CapLook, keycapWidth(fs, label, f), keycap(canvas, r, label, fs, look, f, th)

const std = @import("std");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const scale = @import("scale.zig");
const Rect = @import("shapes.zig").Rect;

const Canvas = render.Canvas;
const Theme = theme.Theme;
const px = scale.px;

/// What a menu row shows.
pub const Row = struct {
    icon: icons.Icon,
    label: []const u8,
    /// its shortcut, right-aligned; empty: none
    key: []const u8 = "",
    /// an option that is on: a check in place of the icon
    checked: bool = false,
};

pub const RowState = struct {
    /// under the pointer, or focused
    hot: bool = false,
    /// has the keyboard focus (a disabled row shows it, quietly)
    focused: bool = false,
    enabled: bool = true,
};

/// A menu row in `r`: the accent under it when hot (and enabled).
pub fn menuRow(cv: *Canvas, r: Rect, f: f64, th: Theme, row: Row, st: RowState) void {
    const rad = 7.0 * f;
    const hot = st.hot and st.enabled;
    if (hot) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.accent_fill);
    if (!st.enabled and st.focused) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.hover);
    const ink: f64 = if (st.enabled) 1 else theme.disabled_alpha;
    const fg = theme.fade(if (hot) th.on_accent else th.fg, ink);
    const sub = theme.fade(if (hot) theme.withAlpha(th.on_accent, 0xBF) else th.muted, ink);
    const is = px(16, f);
    const icon: icons.Icon = if (row.checked) .check else row.icon;
    icons.draw(cv, icon, r.x + px(10, f), r.y + @divTrunc(r.h - is, 2), is, if (row.checked and !hot) th.accent else fg);
    const fs = theme.font_label * f;
    text.draw(cv, r.x + px(36, f), r.y + @divTrunc(r.h - text.height(fs), 2), fs, fg, row.label);
    if (row.key.len == 0) return;
    const ks = theme.font_small * f;
    text.draw(cv, r.right() - px(10, f) - text.width(ks, row.key), r.y + @divTrunc(r.h - text.height(ks), 2), ks, sub, row.key);
}

/// The trough of a segmented control, behind its segments.
pub fn segTrough(cv: *Canvas, r: Rect, f: f64, th: Theme) void {
    cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 9.0 * f, th.track);
}

/// One segment: raised when `on`, tinted by `hover` (0..1), its label
/// centred.
pub fn segment(cv: *Canvas, r: Rect, f: f64, th: Theme, label: []const u8, on: bool, hover: f64) void {
    const rad = 7.0 * f;
    if (on) {
        cv.fillRoundRectAA(r.x, r.y + px(1, f), r.w, r.h, rad, 0x26000000);
        cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.seg_on);
    }
    if (hover > 0) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, theme.fade(th.hover, hover));
    const fs = theme.font_small * f;
    const tw = text.width(fs, label);
    text.draw(cv, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - text.height(fs), 2), fs, if (on or hover > 0) th.fg else th.muted, label);
}

/// A colour swatch: a disc with an edge ring (so white and black show),
/// ringed in the accent when `selected`, faintly when hovered.
pub fn swatch(cv: *Canvas, cx: f64, cy: f64, radius: f64, col: u32, f: f64, th: Theme, selected: bool, hover: f64) void {
    if (selected) {
        cv.ringAA(cx, cy, radius + 3.0 * f, 2.0 * f, th.accent);
    } else if (hover > 0) {
        cv.ringAA(cx, cy, radius + 2.5 * f, 1.5 * f, theme.fade(th.hairline, 2 * hover));
    }
    cv.fillCircleAA(cx, cy, radius, col);
    cv.ringAA(cx, cy, radius - 0.5 * f, 1.0 * f, th.swatch_ring);
}

/// A slider's knob: white, on a soft two-step shadow.
pub fn knob(cv: *Canvas, cx: f64, cy: f64, radius: f64, f: f64) void {
    cv.fillCircleAA(cx, cy + 1.0 * f, radius + 1.0 * f, 0x26000000);
    cv.fillCircleAA(cx, cy + 0.5 * f, radius + 0.5 * f, 0x33000000);
    cv.fillCircleAA(cx, cy, radius, 0xFFFFFFFF);
}

/// What a key cap sits on: a window (a raised cap with an edge below), a
/// floating material (a flat tint), or the accent (a binding being set).
pub const CapLook = enum { window, material, accent };

const cap_style: text.Style = .semibold;

/// The width of a key cap labelled `label` at font size `fs` (px).
pub fn keycapWidth(fs: f64, label: []const u8, f: f64) i32 {
    return @max(px(22, f), text.widthStyled(fs, cap_style, label) + px(16, f));
}

/// A key cap in `r` (keycapWidth wide) labelled `label` at font size `fs`.
pub fn keycap(cv: *Canvas, r: Rect, label: []const u8, fs: f64, look: CapLook, f: f64, th: Theme) void {
    const rad = 6.0 * f;
    switch (look) {
        .accent => cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.accent_fill),
        .material => cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.track),
        .window => {
            cv.fillRoundRectAA(r.x, r.y, r.w, r.h, rad, th.line);
            cv.fillRoundRectAA(r.x, r.y, r.w, r.h - @max(1, px(1, f)), rad, th.chip);
        },
    }
    const fg = switch (look) {
        .accent => th.on_accent,
        .material => th.fg,
        .window => th.text,
    };
    const tw = text.widthStyled(fs, cap_style, label);
    text.drawStyled(cv, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h - text.heightStyled(fs, cap_style), 2), fs, fg, cap_style, label);
}

test "menu kit controls draw within their rects" {
    const th = Theme.get(true, null);
    var buf: [120 * 40]u32 = undefined;
    var cv = Canvas.init(&buf, 120, 40);
    const r: Rect = .{ .x = 4, .y = 4, .w = 112, .h = 30 };
    const bg = th.material_solid;
    inline for (.{ RowState{ .hot = true }, RowState{}, RowState{ .enabled = false, .focused = true } }) |st| {
        @memset(&buf, bg);
        menuRow(&cv, r, 1, th, .{ .icon = .copy, .label = "Copy", .key = "Ctrl+C" }, st);
        try std.testing.expectEqual(bg, buf[0]);
        var lit: usize = 0;
        for (buf) |p| lit += @intFromBool(p != bg);
        try std.testing.expect(lit > 10);
    }
    @memset(&buf, bg);
    segTrough(&cv, r, 1, th);
    segment(&cv, .{ .x = 6, .y = 6, .w = 50, .h = 26 }, 1, th, "50%", true, 0);
    try std.testing.expectEqual(th.seg_on, buf[19 * 120 + 10]);
    @memset(&buf, bg);
    swatch(&cv, 20, 20, 10, 0xFFFF0000, 1, th, true, 0);
    knob(&cv, 60, 20, 9, 1);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), buf[20 * 120 + 60]);
    try std.testing.expect(keycapWidth(13, "Shift", 1) > keycapWidth(13, "A", 1));
    try std.testing.expectEqual(px(22, 1), keycapWidth(13, "", 1));
    for ([_]CapLook{ .window, .material, .accent }) |look| keycap(&cv, .{ .x = 80, .y = 6, .w = 30, .h = 26 }, "K", 13, look, 1, th);
}
