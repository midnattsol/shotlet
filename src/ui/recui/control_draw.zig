//! Layout and drawing of the recording control (control.zig): an opaque
//! pill in the desktop's light or dark look (theme.Opaque), in logical
//! pixels, scaled when painted.
//!
//!   countdown:  [ 3   Recording in 3…   × ]
//!   recording:  [ ● 0:12 | ❚❚  ■  🗑 ]

const std = @import("std");
const fui = @import("../floatui.zig");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const icons = @import("../icons.zig");
const theme = @import("../theme.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const material = @import("../material.zig");
const Rect = @import("../shapes.zig").Rect;

pub const Mode = enum { countdown, recording };
pub const Button = enum { pause, stop, discard, cancel, skip };

pub const State = struct {
    mode: Mode = .countdown,
    count: u32 = 3,
    elapsed_ms: i64 = 0,
    paused: bool = false,
    pulse: bool = false,
    hover: ?Button = null,
    /// the desktop's appearance (control.zig loads it)
    th: theme.Theme = theme.Theme.get(true, null),
};

/// room around the pill for its shadow (theme card_shadow)
pub const pad = theme.card_room;
const pill_w = 232;
const pill_h = 44;
const btn = 32;

/// The colours of the pill, from the theme.
const Look = struct {
    bg: u32,
    fg: u32,
    muted: u32,
    hover: u32,
    line: u32,
    red: u32,

    fn of(th: theme.Theme) Look {
        const o = theme.Opaque.of(th);
        return .{ .bg = o.panel, .fg = o.fg, .muted = o.muted, .hover = o.hover, .line = o.line, .red = th.destructive };
    }
};

pub fn windowSize() [2]u32 {
    return .{ pill_w + 2 * pad, pill_h + 2 * pad };
}

pub fn pillRect() Rect {
    return .{ .x = pad, .y = pad, .w = pill_w, .h = pill_h };
}

/// A button's rectangle, relative to the pill.
fn buttonRect(b: Button) Rect {
    const y = (pill_h - btn) / 2;
    return switch (b) {
        .pause => .{ .x = pill_w - 6 - 3 * btn - 8, .y = y, .w = btn, .h = btn },
        .stop => .{ .x = pill_w - 6 - 2 * btn - 4, .y = y, .w = btn, .h = btn },
        .discard, .cancel => .{ .x = pill_w - 6 - btn, .y = y, .w = btn, .h = btn },
        .skip => .{ .x = 0, .y = 0, .w = pill_w - 6 - btn, .h = pill_h },
    };
}

fn buttons(mode: Mode) []const Button {
    return switch (mode) {
        .countdown => &.{ .cancel, .skip },
        .recording => &.{ .pause, .stop, .discard },
    };
}

/// The button under a logical point of the window.
pub fn hit(x: i32, y: i32, mode: Mode) ?Button {
    var buf: [3]press.Target(Button) = undefined;
    const bs = buttons(mode);
    for (bs, 0..) |b, i| buf[i] = .{ .r = buttonRect(b), .t = b };
    return press.hitTest(Button, buf[0..bs.len], x - pad, y - pad);
}

/// "0:07", "12:30", "1:02:03"
pub fn formatTime(buf: []u8, ms: i64) []const u8 {
    const s: u64 = @intCast(@max(0, @divTrunc(ms, 1000)));
    if (s >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

const px = scale.px;
const ff = scale.ff;

/// Paint onto a transparent (straight alpha) buffer of the window.
pub fn paint(gpa: std.mem.Allocator, buf: []u32, bw: u32, bh: u32, k: f64, st: *const State) void {
    const look = Look.of(st.th);
    const cw: u32 = @intCast(px(pill_w, k));
    const ch: u32 = @intCast(px(pill_h, k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    @memset(card, look.bg);
    var cv = render.Canvas.init(card, cw, ch);
    switch (st.mode) {
        .countdown => paintCountdown(&cv, k, st, look),
        .recording => paintRecording(&cv, k, st, look),
    }
    const radius = ff(ch) / 2;
    material.hairline(&cv, .ofSize(cw, ch), radius, look.line);
    fui.place(.{ .px = buf, .w = bw, .h = bh }, .{ .px = card, .w = cw, .h = ch }, .{ px(pad, k), px(pad, k) }, radius, st.th.card_shadow, k);
}

/// The button's rectangle on the card, with its hover fill.
fn buttonBg(cv: *render.Canvas, k: f64, b: Button, st: *const State, look: Look) Rect {
    const s = scale.rect(buttonRect(b), k);
    if (st.hover == b) cv.fillRoundRectAA(s.x, s.y, s.w, s.h, 9 * k, look.hover);
    return s;
}

fn centre(r: Rect) [2]f64 {
    return .{ ff(r.x) + ff(r.w) / 2, ff(r.y) + ff(r.h) / 2 };
}

fn paintCountdown(cv: *render.Canvas, k: f64, st: *const State, look: Look) void {
    var buf: [32]u8 = undefined;
    const fs = 22 * k;
    const digit = std.fmt.bufPrint(&buf, "{d}", .{st.count}) catch "";
    const cy = @divTrunc(cv.h, 2);
    text.drawStyled(cv, px(18, k), cy - @divTrunc(text.heightStyled(fs, .semibold), 2), fs, look.red, text.Style.semibold.num(), digit);
    const label = if (st.hover == .skip) "Start now" else "Recording starts\u{2026}";
    const ls = 13 * k;
    text.draw(cv, px(46, k), cy - @divTrunc(text.height(ls), 2), ls, if (st.hover == .skip) look.fg else look.muted, label);
    const c = centre(buttonBg(cv, k, .cancel, st, look));
    icons.drawAt(cv, .close, c[0], c[1], 16 * k, .{}, look.fg);
}

fn paintRecording(cv: *render.Canvas, k: f64, st: *const State, look: Look) void {
    const cy = ff(cv.h) / 2;
    const dot: u32 = if (st.paused) look.muted else if (st.pulse) look.red else theme.mix(look.red, 0xFF000000, 0.22);
    cv.fillCircleAA(18 * k, cy, 6 * k, dot);
    var buf: [32]u8 = undefined;
    const fs = 15 * k;
    const t = formatTime(&buf, st.elapsed_ms);
    text.drawStyled(cv, px(32, k), @as(i32, @intFromFloat(cy)) - @divTrunc(text.heightStyled(fs, .semibold), 2), fs, if (st.paused) look.muted else look.fg, text.Style.semibold.num(), t);
    const sep_x = px(buttonRect(.pause).x - 6, k);
    cv.fillRect(sep_x, px(12, k), @max(1, px(1, k)), px(pill_h - 24, k), look.line);
    const p = centre(buttonBg(cv, k, .pause, st, look));
    icons.drawAt(cv, if (st.paused) .play else .pause, p[0], p[1], 18 * k, .{}, look.fg);
    const s = buttonBg(cv, k, .stop, st, look);
    const q = px(12, k);
    cv.fillRoundRectAA(s.x + @divTrunc(s.w - q, 2), s.y + @divTrunc(s.h - q, 2), q, q, 2.5 * k, look.red);
    const d = centre(buttonBg(cv, k, .discard, st, look));
    icons.drawAt(cv, .trash, d[0], d[1], 17 * k, .{}, look.fg);
}

test "time format and hit testing" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0:07", formatTime(&buf, 7400));
    try std.testing.expectEqualStrings("12:30", formatTime(&buf, 750_000));
    try std.testing.expectEqualStrings("1:02:03", formatTime(&buf, 3_723_000));
    const r = buttonRect(.stop);
    try std.testing.expectEqual(@as(?Button, .stop), hit(pad + r.x + 4, pad + r.y + 4, .recording));
    try std.testing.expectEqual(@as(?Button, null), hit(1, 1, .recording));
    try std.testing.expectEqual(@as(?Button, .skip), hit(pad + 20, pad + 20, .countdown));
}

test "the control follows the theme" {
    const d = Look.of(theme.Theme.get(true, null));
    const l = Look.of(theme.Theme.get(false, null));
    try std.testing.expect(theme.luminance(d.bg) < theme.luminance(l.bg));
    try std.testing.expect(theme.contrast(l.fg, l.bg) > 4.5 and theme.contrast(d.fg, d.bg) > 4.5);
}
