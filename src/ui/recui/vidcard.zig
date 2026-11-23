//! The video thumbnail card (record/quickvid.zig): the first picture,
//! the duration (and "GIF") in a badge; on hover the filmstrip plays and
//! Copy / Save as… / trim / close show, as on the screenshot thumbnail;
//! a right-click opens its menu (ui/cardmenu.zig, as the screenshot
//! card's), with Show in Files.

const std = @import("std");
const fui = @import("../floatui.zig");
const render = @import("../../gfx/render.zig");
const theme = @import("../theme.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const control_draw = @import("control_draw.zig");
const Rect = @import("../shapes.zig").Rect;
const Notice = @import("../notice.zig").Notice;
const cardmenu = @import("../cardmenu.zig");

pub const card_w = 240;
pub const card_h = 150;
/// room around the card for its shadow (theme card_shadow)
pub const pad = theme.card_room;

/// `show_in_files`: only in the menu
pub const Control = enum { body, close, trim, copy, save_as, show_in_files };

/// the right-click menu's rows
pub const menu_items = [_]struct { label: []const u8, control: Control }{
    .{ .label = "Copy", .control = .copy },
    .{ .label = "Save as\u{2026}", .control = .save_as },
    .{ .label = "Show in Files", .control = .show_in_files },
    .{ .label = "Trim", .control = .trim },
    .{ .label = "Close", .control = .close },
};

pub const View = struct {
    /// the picture shown (first frame, or a strip picture on hover)
    pic: []const u32,
    pic_w: u32,
    pic_h: u32,
    duration_ms: i64,
    gif: bool,
    hover: ?Control = null,
    hovered: bool = false,
    /// "Copied", "✓ Saved" over the card, as at `now`
    notice: ?*const Notice = null,
    now: i64 = 0,
    /// the right-click menu instead of the controls
    menu: bool = false,
    alpha: f64 = 1,
    /// the desktop's appearance (the controls over the picture look the
    /// same in both; the card behind a narrow picture follows it)
    th: theme.Theme = theme.Theme.get(true, null),
};

pub fn windowSize() [2]u32 {
    return .{ card_w + 2 * pad, card_h + 2 * pad };
}

pub fn controlRect(c: Control) Rect {
    const pw = (card_w - 16 - 6) / 2;
    return switch (c) {
        .close => .{ .x = 8, .y = 8, .w = 26, .h = 26 },
        .trim => .{ .x = card_w - 8 - 26, .y = 8, .w = 26, .h = 26 },
        .copy => .{ .x = 8, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .save_as => .{ .x = 8 + pw + 6, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .body, .show_in_files => .{ .x = 0, .y = 0, .w = card_w, .h = card_h },
    };
}

/// the controls, top-most first (the body last: anything else on the card)
const targets = blk: {
    var t: [5]press.Target(Control) = undefined;
    for (.{ .close, .trim, .copy, .save_as, .body }, 0..) |c, i| t[i] = .{ .r = controlRect(c), .t = c };
    break :blk t;
};

/// What is under a logical point of the window (`menu`: the menu is
/// open, its rows take the card).
pub fn hit(x: i32, y: i32, menu: bool) ?Control {
    const c = press.hitTest(Control, &targets, x - pad, y - pad) orelse return null;
    if (!menu) return c;
    const row = cardmenu.rowAt(menu_items.len, card_h, y - pad) orelse return .body;
    return menu_items[row].control;
}

const px = scale.px;
const ff = scale.ff;

/// Paint the card onto the window buffer (straight alpha).
pub fn paint(gpa: std.mem.Allocator, buf: []u32, bw: u32, bh: u32, k: f64, v: *const View) void {
    const cw: u32 = @intCast(px(card_w, k));
    const ch: u32 = @intCast(px(card_h, k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    fui.drawImage(gpa, .{ .px = card, .w = cw, .h = ch }, .{ .px = v.pic, .w = v.pic_w, .h = v.pic_h }, .auto, theme.Opaque.of(v.th).panel);
    var cv = render.Canvas.init(card, cw, ch);
    if (v.menu) {
        drawMenu(&cv, k, v);
    } else {
        badge(&cv, k, v);
        if (v.hovered) controls(&cv, k, v);
    }
    if (v.notice) |n| n.draw(&cv, .ofSize(cw, ch), v.now, k, v.th);
    const at = px(pad, k);
    fui.compositeFaded(gpa, .{ .px = buf, .w = bw, .h = bh }, .{ .px = card, .w = cw, .h = ch }, .{ at, at }, 12 * k, v.th.card_shadow, v.alpha, k) catch {};
}

/// The duration (and "GIF") in a dark pill: bottom right, under the
/// trim button while hovered.
fn badge(cv: *render.Canvas, k: f64, v: *const View) void {
    var buf: [40]u8 = undefined;
    var tb: [32]u8 = undefined;
    const t = control_draw.formatTime(&tb, v.duration_ms + 500);
    const s = if (v.gif) std.fmt.bufPrint(&buf, "GIF \u{00B7} {s}", .{t}) catch t else t;
    const w = fui.scrimPillWidth(s, .play, k);
    const h = px(fui.scrim_pill_h, k);
    const x = cv.w - w - px(8, k);
    const y = if (v.hovered) px(8 + 26 + 6, k) else cv.h - h - px(8, k);
    fui.scrimPill(cv, .{ .x = x, .y = y, .w = w, .h = h }, s, .play, .strong, k, v.th);
}

fn drawMenu(cv: *render.Canvas, k: f64, v: *const View) void {
    var items: [menu_items.len]cardmenu.Item = undefined;
    var hot: ?usize = null;
    for (menu_items, &items, 0..) |m, *it, i| {
        it.* = .{ .label = m.label };
        if (v.hover == m.control) hot = i;
    }
    cardmenu.draw(cv, &items, hot, card_w, k, v.th);
}

fn controls(cv: *render.Canvas, k: f64, v: *const View) void {
    cv.fillRect(0, 0, cv.w, cv.h, v.th.scrim(.soft));
    for ([_]Control{ .close, .trim }) |c| {
        const r = controlRect(c);
        const icon: @import("../icons.zig").Icon = if (c == .close) .close else .scissors;
        fui.roundButton(cv, (ff(r.x) + 13) * k, (ff(r.y) + 13) * k, 13 * k, icon, .{ .hot = v.hover == c }, k, v.th);
    }
    for ([_]Control{ .copy, .save_as }) |c| {
        const label = if (c == .copy) "Copy" else "Save as\u{2026}";
        fui.pillButton(cv, scale.rect(controlRect(c), k), label, .light, 13, .{ .hot = v.hover == c }, k, v.th);
    }
}

test "card controls hit" {
    try std.testing.expectEqual(@as(?Control, .close), hit(pad + 10, pad + 10, false));
    try std.testing.expectEqual(@as(?Control, .trim), hit(pad + card_w - 20, pad + 10, false));
    try std.testing.expectEqual(@as(?Control, .copy), hit(pad + 20, pad + card_h - 20, false));
    try std.testing.expectEqual(@as(?Control, .body), hit(pad + 120, pad + 70, false));
    try std.testing.expect(hit(2, 2, false) == null);
}

test "the menu's rows take the card while it is open" {
    const t = cardmenu.top(menu_items.len, card_h);
    const row = cardmenu.row_h;
    try std.testing.expectEqual(@as(?Control, .copy), hit(pad + 120, pad + t + 2, true));
    try std.testing.expectEqual(@as(?Control, .show_in_files), hit(pad + 120, pad + t + 2 * row + 2, true));
    try std.testing.expectEqual(@as(?Control, .close), hit(pad + 120, pad + t + 4 * row + 2, true));
    // the buttons' places are rows or nothing now; outside the card, null
    try std.testing.expectEqual(@as(?Control, .body), hit(pad + 10, pad + 2, true));
    try std.testing.expect(hit(2, 2, true) == null);
}
