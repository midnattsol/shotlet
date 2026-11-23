//! Drawing the pin's menu as the editor draws its menus (ui/theme.zig's
//! menu metrics and colours): the material (opaque: a client cannot
//! blur what lies behind it), a hairline edge and a soft shadow, rows
//! with an icon, a label and their shortcut, the accent under the hot
//! row, and the opacity as a segmented control. It fades and grows in
//! from 96% from its corner at the pointer, and fades out when closed.

const std = @import("std");
const theme = @import("../../ui/theme.zig");
const fui = @import("../../ui/floatui.zig");
const material = @import("../../ui/material.zig");
const menukit = @import("../../ui/menukit.zig");
const scale = @import("../../ui/scale.zig");
const text = @import("../../gfx/text.zig");
const Rect = @import("../../ui/shapes.zig").Rect;
const menu = @import("menu.zig");
const view = @import("view.zig");

const Theme = theme.Theme;
const px = scale.px;

/// What the rows show beside the layout.
pub const Marks = struct { locked: bool, opacity: view.Opacity };

/// The menu `st` onto the straight-alpha surface `dst` at scale k.
pub fn draw(gpa: std.mem.Allocator, dst: fui.Surface, k: f64, th: Theme, st: *const menu.State, marks: Marks, now: i64) !void {
    const a = st.alpha(now);
    if (a <= 0.001) return;
    const f = k * (0.96 + 0.04 * a);
    const sz = st.lay.size();
    const mw: u32 = @intCast(px(sz[0], f));
    const mh: u32 = @intCast(px(sz[1], f));
    const card = try gpa.alloc(u32, @as(usize, mw) * mh);
    defer gpa.free(card);
    var cv = fui.Canvas.init(card, mw, mh);
    const rad = theme.menu_radius * f;
    @memset(card, th.material_solid);
    material.hairline(&cv, .ofSize(mw, mh), rad, material.hairlineColor(th, f));
    drawRows(&cv, f, th, st, marks);
    // the card and its shadow, faded as one
    try fui.compositeFaded(gpa, dst, .{ .px = card, .w = mw, .h = mh }, .{ px(st.at[0], k), px(st.at[1], k) }, rad, th.card_shadow, a, k);
}

fn drawRows(cv: *fui.Canvas, f: f64, th: Theme, st: *const menu.State, marks: Marks) void {
    const l = &st.lay;
    for (l.seps[0..l.n_seps]) |y| cv.fillRect(px(menu.pad + 10, f), px(y, f), px(menu.width - 2 * menu.pad - 20, f), 1, th.hairline);
    for (l.items[0..l.n], l.rows[0..l.n], 0..) |it, r, i| {
        const hot = st.hot != null and st.hot.? == i;
        if (it == .opacity) {
            drawOpacity(cv, f, th, r, hot, st.hot_seg, marks.opacity);
        } else menukit.menuRow(cv, scale.rect(r, f), f, th, .{ .icon = it.icon(), .label = it.label(marks.locked), .key = it.key() }, .{ .hot = hot });
    }
}

/// "Opacity 1-4" over four segments, the current one raised.
fn drawOpacity(cv: *fui.Canvas, f: f64, th: Theme, row: Rect, hot: bool, hot_seg: ?u2, cur: view.Opacity) void {
    const r = scale.rect(row, f);
    if (hot and hot_seg == null) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 7 * f, th.hover);
    const ks = theme.font_small * f;
    const head_h = px(menu.heading_h, f);
    const hy = r.y + @divTrunc(head_h - text.height(ks), 2);
    text.draw(cv, r.x + px(10, f), hy, ks, th.muted, menu.Item.opacity.label(false));
    text.draw(cv, r.right() - px(10, f) - text.width(ks, menu.Item.opacity.key()), hy, ks, th.muted, menu.Item.opacity.key());
    menukit.segTrough(cv, scale.rect(.{ .x = row.x, .y = row.y + menu.heading_h, .w = row.w, .h = menu.seg_h }, f), f, th);
    for (view.Opacity.all, 0..) |o, i| {
        const under = hot and hot_seg != null and hot_seg.? == i;
        menukit.segment(cv, scale.rect(menu.segment(row, i), f), f, th, o.label(), o == cur, if (under) 1 else 0);
    }
}
