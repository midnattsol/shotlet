//! Drawing the quick access thumbnails: each card (its picture, the
//! controls while hovered or focused, or its menu, and a notice) with a
//! shadow, faded as a whole; and the GNOME hint above the stack.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const text = @import("../../gfx/text.zig");
const effects = @import("../../gfx/effects.zig");
const shapes = @import("../../ui/shapes.zig");
const fui = @import("../../ui/floatui.zig");
const floatwin = @import("../../ui/floatwin.zig");
const icons = @import("../../ui/icons.zig");
const scale = @import("../../ui/scale.zig");
const theme = @import("../../ui/theme.zig");
const layout = @import("layout.zig");
const stack = @import("stack.zig");

const Quick = stack.Quick;
const Card = stack.Card;
const Control = layout.Control;
const Canvas = fui.Canvas;
const Rect = shapes.Rect;
const Theme = theme.Theme;
const card_w = layout.card_w;
const px = scale.px;
const ff = scale.ff;

/// corner radius of the cards and of the hint, logical px
const card_radius = 12;
const hint_radius = 10;
/// the round buttons' radius, logical px
const round_r = 13;

pub fn render(self: *Quick) !void {
    if (!self.dirty or !floatwin.canDraw(&self.win)) return;
    self.dirty = false;
    const buf = try self.win.backBuffer();
    const dst: fui.Surface = .{ .px = buf, .w = self.win.width, .h = self.win.height };
    @memset(buf, 0);
    const k = self.factor();
    const now = sys.monoMs();
    const lh: i32 = @intCast(self.size[1]);
    for (self.cards.items) |*c| c.life.start(now);
    var i = self.cards.items.len;
    while (i > 0) {
        i -= 1;
        try drawCard(self, dst, i, scale.rect(layout.cardRect(i, lh), k), now);
    }
    if (self.hint) try drawHint(self, dst);
    try floatwin.presentStraight(&self.win, buf);
    // committed (the cards fade in from it): the editor may go. Not on
    // its frame callback: mutter holds those back while the editor
    // still covers the window.
    self.signalReady();
}

/// The GNOME hint: an opaque pill above the cards with a link.
fn drawHint(self: *Quick, dst: fui.Surface) !void {
    const k = self.factor();
    const th = self.th;
    const o = theme.Opaque.of(th);
    const r = scale.rect(layout.hintRect(), k);
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    const buf = try self.gpa.alloc(u32, @as(usize, w) * h);
    defer self.gpa.free(buf);
    @memset(buf, o.panel);
    var cv = Canvas.init(buf, w, h);
    const hovered = if (self.hover) |hv| hv.control == .hint else false;
    text.draw(&cv, px(10, k), px(5, k), 12 * k, o.fg, self.hint_text);
    text.drawStyled(&cv, px(10, k), px(21, k), 12 * k, if (hovered) th.accent_hover else th.accent_text, .semibold, self.hint_link);
    fui.place(dst, .{ .px = buf, .w = w, .h = h }, .{ r.x, r.y }, hint_radius * k, th.card_shadow, k);
}

/// Card i at r (buffer pixels).
fn drawCard(self: *Quick, dst: fui.Surface, i: usize, r: Rect, now: i64) !void {
    const c = &self.cards.items[i];
    const k = self.factor();
    const cw: u32 = @intCast(r.w);
    const ch: u32 = @intCast(r.h);
    const pic = try c.pic.ensure(self.gpa, .{ .px = c.thumb.pixels, .w = c.thumb.width, .h = c.thumb.height }, cw, ch, .auto, theme.Opaque.of(self.th).panel);
    const card = try self.gpa.dupe(u32, pic);
    defer self.gpa.free(card);
    var cv = Canvas.init(card, cw, ch);
    const hovered = if (self.hover) |h| h.card == i and h.control != .hint else false;
    const focused = if (self.focus) |fo| fo.card == i else false;
    const dragged = self.dragging == i;
    // the controls fade in and out with the hover, the status the other way
    c.hov.to(if ((hovered or focused) and !dragged and !c.menu) 1 else 0, now);
    const shown = c.hov.at(now);
    if (c.menu) {
        drawMenu(self, &cv, c, i);
    } else {
        if (shown < 1) drawStatus(&cv, c, k, self.th);
        if (shown > 0) try drawControls(self, card, pic, cw, ch, i, .{ .hovered = hovered, .focused = focused }, shown);
    }
    const word = c.notice.text(now);
    if (word.len > 0) fui.notice(&cv, .{ .x = 0, .y = 0, .w = r.w, .h = r.h }, word, k, self.th);
    var alpha = c.life.alpha(now);
    if (dragged) alpha = @min(alpha, 0.5);
    try fui.compositeFaded(self.gpa, dst, .{ .px = card, .w = cw, .h = ch }, .{ r.x, r.y }, card_radius * k, self.th.card_shadow, alpha, k);
}

/// The veil, the round buttons and the bottom pills over the picture
/// `pic`, mixed into `card` at `shown` (0..1).
fn drawControls(self: *Quick, card: []u32, pic: []const u32, cw: u32, ch: u32, i: usize, on: struct { hovered: bool, focused: bool }, shown: f64) !void {
    const c = &self.cards.items[i];
    const k = self.factor();
    const deco = try self.gpa.dupe(u32, pic);
    defer self.gpa.free(deco);
    var dv = Canvas.init(deco, cw, ch);
    dv.fillRect(0, 0, @intCast(cw), @intCast(ch), self.th.scrim(.veil));
    const fo: ?Control = if (on.focused) self.focus.?.control else null;
    const hv: ?Control = if (on.hovered) self.hover.?.control else null;
    // Close, Annotate and Pin: round buttons along the top
    for ([_]Control{ .close, .annotate, .pin }, [_]icons.Icon{ .close, .pen, .pin }) |ctl, icon| {
        const cr = layout.controlRect(ctl);
        const st: fui.State = .{ .hot = hv == ctl, .dim = ctl == .annotate and !c.editable, .focused = fo == ctl };
        fui.roundButton(&dv, ff(cr.x + round_r) * k, ff(cr.y + round_r) * k, round_r * k, icon, st, k, self.th);
    }
    // the two pills along the bottom: the primary one in the accent
    for ([_]Control{ .primary, .secondary }, layout.pillActions(c.meta.saved.len > 0)) |ctl, a| {
        const look: fui.PillLook = if (ctl == .primary) .primary else .light;
        const size: f64 = if (a == .show_in_files) 12 else 13;
        fui.pillButton(&dv, scale.rect(layout.controlRect(ctl), k), a.label(), look, size, .{ .hot = hv == ctl, .focused = fo == ctl }, k, self.th);
    }
    effects.mixRows(card, card, deco, @intFromFloat(@round(shown * 256)));
}

/// What happened to the capture, along the bottom: "Copied" or
/// "Saved · NAME".
fn drawStatus(cv: *Canvas, c: *const Card, k: f64, th: Theme) void {
    const saved = c.meta.saved;
    var buf: [300]u8 = undefined;
    var cut: [300]u8 = undefined;
    const label = if (saved.len == 0) "Copied" else blk: {
        const name = saved[(std.mem.lastIndexOfScalar(u8, saved, '/') orelse return) + 1 ..];
        break :blk std.fmt.bufPrint(&buf, "Saved \u{00B7} {s}", .{name}) catch "Saved";
    };
    // the pill may take the card's width but its margins
    const room = px(card_w - 16, k) - fui.scrimPillWidth("", .check, k);
    const shown = text.ellipsize(&cut, 12 * k, .semibold, label, room, .end);
    const h = px(fui.scrim_pill_h, k);
    const r: Rect = .{ .x = px(8, k), .y = @as(i32, @intCast(cv.h)) - h - px(8, k), .w = fui.scrimPillWidth(shown, .check, k), .h = h };
    fui.scrimPill(cv, r, shown, .check, .pill, k, th);
}

/// The right-click menu over the card's picture.
fn drawMenu(self: *const Quick, cv: *Canvas, c: *const Card, i: usize) void {
    const k = self.factor();
    const th = self.th;
    cv.fillRect(0, 0, @intCast(cv.w), @intCast(cv.h), th.scrim(.pill));
    const top = layout.menuTop();
    for (layout.menu_items, 0..) |item, j| {
        const row = scale.rect(.{ .x = 8, .y = top + @as(i32, @intCast(j)) * layout.menu_row, .w = card_w - 16, .h = layout.menu_row }, k);
        const on = if (self.hover) |h| h.card == i and h.control == .menu and h.item == j else false;
        if (on) cv.fillRoundRectAA(row.x, row.y, row.w, row.h, 5 * k, theme.withAlpha(th.on_scrim, 0x40));
        const dim = item.action == .annotate and !c.editable;
        const fs = 12.5 * k;
        text.draw(cv, row.x + px(10, k), row.y + @divTrunc(row.h - text.height(fs), 2), fs, if (dim) th.on_scrim_dim else th.on_scrim, item.label);
    }
}
