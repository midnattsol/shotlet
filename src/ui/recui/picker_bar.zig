//! The record picker's bar (picker.zig), in the editor toolbar's look
//! (ui/barkit.zig, the theme's metrics and colours): Glass over the
//! blurred desktop, in logical pixels relative to the bar.
//!
//!   [ MP4 GIF ] | 🎙 🔊 | click keys | × [ ● Record ]
//!
//! Clicks and keystrokes are drawn by the GNOME Shell extension; without
//! it those two are greyed and say so.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const icons = @import("../icons.zig");
const theme = @import("../theme.zig");
const barkit = @import("../barkit.zig");
const material = @import("../material.zig");
const selchrome = @import("../selchrome.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const shapes = @import("../shapes.zig");
const settings_mod = @import("../../record/settings.zig");
const Rect = shapes.Rect;

pub const Item = enum { mp4, gif, mic, system, clicks, keys, close, record };

pub const State = struct {
    set: *settings_mod.Settings,
    /// clicks and keystrokes can be shown (the GNOME integration records)
    overlays: bool,
    th: theme.Theme,
    hover: ?Item = null,
};

const pad: i32 = @intFromFloat(theme.bar_pad);
const gap: i32 = @intFromFloat(theme.bar_gap);
const btn: i32 = @intFromFloat(theme.button);
const sep_w: i32 = 1 + 2 * @as(i32, @intFromFloat(theme.sep_margin));
const h = 2 * pad + btn;
const hf: f64 = @floatFromInt(h);

/// Items in order, by group (a separator between groups).
const order = [_]struct { item: Item, group: u8 }{
    .{ .item = .mp4, .group = 0 },
    .{ .item = .gif, .group = 0 },
    .{ .item = .mic, .group = 1 },
    .{ .item = .system, .group = 1 },
    .{ .item = .clicks, .group = 2 },
    .{ .item = .keys, .group = 2 },
    .{ .item = .close, .group = 3 },
    .{ .item = .record, .group = 3 },
};

const Layout = struct {
    x: [order.len]i32 = undefined,
    w: [order.len]i32 = undefined,
    seps: [3]i32 = undefined,
    width: i32 = 0,
};

fn itemWidth(item: Item) i32 {
    return switch (item) {
        .mp4, .gif => text.width(theme.font_label, formatLabel(item)) + 20,
        .record => barkit.primaryWidth(1, "Record"),
        else => btn,
    };
}

fn layout() Layout {
    var l: Layout = .{};
    var x = pad;
    var n_seps: usize = 0;
    for (order, 0..) |o, i| {
        if (i > 0) {
            if (o.group != order[i - 1].group) {
                l.seps[n_seps] = x + gap + @as(i32, @intFromFloat(theme.sep_margin));
                n_seps += 1;
                x += gap + sep_w + gap;
            } else x += gap;
        }
        l.x[i] = x;
        l.w[i] = itemWidth(o.item);
        x += l.w[i];
    }
    l.width = x + pad;
    return l;
}

pub fn size() [2]i32 {
    return .{ layout().width, h };
}

fn rectOf(l: *const Layout, item: Item) Rect {
    for (order, 0..) |o, i| if (o.item == item) return .{ .x = l.x[i], .y = pad, .w = l.w[i], .h = btn };
    unreachable;
}

pub fn hit(lx: i32, ly: i32) ?Item {
    const l = layout();
    var targets: [order.len]press.Target(Item) = undefined;
    for (order, 0..) |o, i| targets[i] = .{ .r = rectOf(&l, o.item), .t = o.item };
    return press.hitTest(Item, &targets, lx, ly);
}

/// What an item does to the settings (the caller handles .record and
/// .close).
pub fn toggle(st: *State, item: Item) void {
    const s = st.set;
    switch (item) {
        .mp4 => s.format = .mp4,
        .gif => s.format = .gif,
        .mic => s.mic = !s.mic,
        .system => s.system_audio = !s.system_audio,
        .clicks => if (st.overlays) {
            s.clicks = !s.clicks;
        },
        .keys => if (st.overlays) {
            s.keys = !s.keys;
        },
        .record, .close => {},
    }
}

/// What an item's tooltip says: its name, and its shortcut key.
pub const Tip = struct { name: []const u8, key: []const u8 = "" };

pub fn tooltip(st: *const State, item: Item) Tip {
    return switch (item) {
        .record => .{ .name = "Start recording", .key = "Enter" },
        .mp4 => .{ .name = "Video (MP4)" },
        .gif => .{ .name = "Animated GIF" },
        .mic => .{ .name = if (st.set.format == .gif) "Microphone (not in GIFs)" else "Microphone" },
        .system => .{ .name = if (st.set.format == .gif) "System sound (not in GIFs)" else "System sound" },
        .clicks => .{ .name = if (st.overlays) "Show clicks" else "Show clicks: GNOME with Shotlet's integration only" },
        .keys => .{ .name = if (st.overlays) "Show keystrokes" else "Show keystrokes: GNOME with Shotlet's integration only" },
        .close => .{ .name = "Cancel", .key = "Esc" },
    };
}

fn formatLabel(item: Item) []const u8 {
    return if (item == .mp4) "MP4" else "GIF";
}

fn isOn(st: *const State, item: Item) bool {
    const s = st.set;
    return switch (item) {
        .mp4 => s.format == .mp4,
        .gif => s.format == .gif,
        .mic => s.mic,
        .system => s.system_audio,
        .clicks => s.clicks and st.overlays,
        .keys => s.keys and st.overlays,
        else => false,
    };
}

fn isDisabled(st: *const State, item: Item) bool {
    return switch (item) {
        .clicks, .keys => !st.overlays,
        .mic, .system => st.set.format == .gif,
        else => false,
    };
}

const px = scale.px;

/// Paint the bar at buffer x, y (scale k) onto an opaque canvas: the
/// bar's shadow and Glass material over what the canvas holds, then the
/// items; the tooltip of the item under the pointer below it. `shadow`
/// keeps the shadow between frames.
pub fn paint(gpa: std.mem.Allocator, cv: *render.Canvas, x: i32, y: i32, k: f64, st: *const State, shadow: *material.ShadowCache) void {
    const l = layout();
    const th = st.th;
    const r: Rect = .{ .x = x, .y = y, .w = px(l.width, k), .h = px(h, k) };
    const rad = theme.bar_radius * k;
    material.shadow(gpa, cv, r, rad, th.bar_shadow, k, 1, shadow);
    material.glass(gpa, cv, r, rad, th, k);
    const sep_y = y + px((hf - theme.sep_h) / 2, k);
    for (l.seps) |sx| barkit.separator(cv, x + px(sx, k), sep_y, px(theme.sep_h, k), th);
    for (order) |o| {
        const ir = scale.rect(rectOf(&l, o.item), k);
        paintItem(cv, k, st, o.item, .{ .x = x + ir.x, .y = y + ir.y, .w = ir.w, .h = ir.h });
    }
    if (st.hover) |hv| {
        const tip = tooltip(st, hv);
        const sz = selchrome.tooltipSize(tip.name, tip.key, k);
        selchrome.tooltip(cv, .{ .x = x, .y = r.bottom() + px(8, k), .w = sz[0], .h = sz[1] }, tip.name, tip.key, k, th);
    }
}

fn paintItem(cv: *render.Canvas, k: f64, st: *const State, item: Item, r: Rect) void {
    const th = st.th;
    const hover: f64 = if (st.hover == item) 1 else 0;
    if (item == .record) {
        const red = theme.mix(theme.destructive_fill, theme.destructive_fill_hover, hover);
        barkit.primary(cv, r, k, red, th.on_accent, .dot, "Record");
        return;
    }
    const disabled = isDisabled(st, item);
    const look: barkit.Look = if (isOn(st, item)) .toggled else .plain;
    barkit.fill(cv, r, k, th, look, if (disabled) 0 else hover);
    const col = barkit.ink(th, look, disabled);
    const icon: icons.Icon = switch (item) {
        .mp4, .gif => {
            const fs = theme.font_label * k;
            const label = formatLabel(item);
            const cx = r.x + @divTrunc(r.w, 2);
            const cy = r.y + @divTrunc(r.h, 2);
            text.draw(cv, cx - @divTrunc(text.width(fs, label), 2), cy - @divTrunc(text.height(fs), 2), fs, col, label);
            return;
        },
        .mic => .mic,
        .system => .speaker,
        .clicks => .click,
        .keys => .keyboard,
        .close => .close,
        .record => return,
    };
    icons.drawAt(cv, icon, scale.ff(r.x) + scale.ff(r.w) / 2, scale.ff(r.y) + scale.ff(r.h) / 2, theme.icon * k, .{}, col);
}

test "bar items do not overlap and hit back" {
    const l = layout();
    for (order, 0..) |o, i| {
        const r = rectOf(&l, o.item);
        try std.testing.expectEqual(@as(?Item, o.item), hit(r.x + 2, r.y + 2));
        if (i > 0) try std.testing.expect(r.x >= l.x[i - 1] + l.w[i - 1]);
    }
    try std.testing.expect(hit(0, 0) == null);
    try std.testing.expectEqual(@as(i32, 46), size()[1]);
    var s: settings_mod.Settings = .{};
    var st: State = .{ .set = &s, .overlays = false, .th = theme.Theme.get(true, null) };
    toggle(&st, .gif);
    toggle(&st, .clicks);
    try std.testing.expect(s.format == .gif and !s.clicks);
    try std.testing.expect(isDisabled(&st, .mic));
    st.overlays = true;
    toggle(&st, .clicks);
    try std.testing.expect(s.clicks);
}
