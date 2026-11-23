//! Drawing the "Recent captures" panel: header, search field, the grid
//! of rounded thumbnails with relative times (clipped to its band), the
//! action bar of the picked capture and a passing notice, onto a card
//! with a shadow.

const std = @import("std");
const clock = @import("../clock.zig");
const sys = @import("../../platform/api.zig").sys;
const text = @import("../../gfx/text.zig");
const effects = @import("../../gfx/effects.zig");
const shapes = @import("../../ui/shapes.zig");
const fui = @import("../../ui/floatui.zig");
const floatwin = @import("../../ui/floatwin.zig");
const icons = @import("../../ui/icons.zig");
const barkit = @import("../../ui/barkit.zig");
const scale = @import("../../ui/scale.zig");
const theme = @import("../../ui/theme.zig");
const layout = @import("layout.zig");
const panel_mod = @import("panel.zig");

const Panel = panel_mod.Panel;
const Item = panel_mod.Item;
const Rect = shapes.Rect;
const Canvas = fui.Canvas;
const Opaque = theme.Opaque;
const panel_w = layout.panel_w;
const pad = layout.pad;
const inset = layout.inset;
const field_h = layout.field_h;
const thumb_h = layout.thumb_h;
const actions_h = layout.actions_h;
const s = scale.px;
const ff = scale.ff;

pub fn render(self: *Panel) !void {
    if (!self.dirty or !floatwin.canDraw(&self.win)) return;
    self.dirty = false;
    const kk = self.k();
    const px = try self.win.backBuffer();
    const bw = self.win.width;
    const bh = self.win.height;
    @memset(px, 0);
    const op = Opaque.of(self.th);
    const pw: u32 = @intCast(s(panel_w, kk));
    const ph: u32 = @min(bh -| @as(u32, @intCast(s(2 * pad, kk))), @as(u32, @intCast(s(self.panelH(), kk))));
    if (ph == 0 or pw == 0) return;
    const panel = try self.gpa.alloc(u32, @as(usize, pw) * ph);
    defer self.gpa.free(panel);
    @memset(panel, op.panel);
    var cv = Canvas.init(panel, pw, ph);

    drawHeader(self, &cv, kk, op);
    drawSearch(self, &cv, kk, op);
    try drawGrid(self, panel, pw, ph, kk, op);
    if (self.selected) |si| {
        drawActions(self, &cv, &self.items.items[si], kk, op);
    } else if (self.confirm_clear) {
        drawConfirm(self, &cv, kk, op);
    } else if (self.items.items.len > 0) drawClear(self, &cv, kk, op);
    const word = self.notice.text(sys.monoMs());
    if (word.len > 0) {
        // centred above the footer
        const nh = s(30, kk);
        const area: Rect = .{ .x = 0, .y = @as(i32, @intCast(ph)) - nh - s(actions_h + 12, kk), .w = @intCast(pw), .h = nh };
        fui.notice(&cv, area, word, kk, self.th);
    }

    const o = s(pad, kk);
    fui.place(.{ .px = px, .w = bw, .h = bh }, .{ .px = panel, .w = pw, .h = ph }, .{ o, o }, 14 * kk, self.th.card_shadow, kk);
    try floatwin.presentStraight(&self.win, px);
}

/// Title and the close button.
fn drawHeader(self: *const Panel, cv: *Canvas, kk: f64, op: Opaque) void {
    text.drawStyled(cv, s(inset, kk), s(inset, kk), 14 * kk, op.fg, .semibold, "Recent captures");
    const xr = self.closeRect();
    const xcx = (ff(xr.x) + 11) * kk;
    const xcy = (ff(xr.y) + 11) * kk;
    if (self.hover_close) cv.fillCircleAA(xcx, xcy, 11 * kk, op.field);
    icons.drawAt(cv, .close, xcx, xcy, 14 * kk, .{}, op.muted);
}

/// The search field; without Tesseract it shows dimmed, takes no typing
/// and says why. A long search shows its end.
fn drawSearch(self: *const Panel, cv: *Canvas, kk: f64, op: Opaque) void {
    const y = s(self.searchTop(), kk);
    const k: f64 = if (self.searchable) 1 else theme.disabled_alpha;
    cv.fillRoundRectAA(s(inset, kk), y, s(panel_w - 2 * inset, kk), s(field_h, kk), 8 * kk, theme.fade(op.field, k));
    icons.drawAt(cv, .search, ff(inset + 17) * kk, ff(y) + 16 * kk, 14 * kk, .{}, theme.fade(op.muted, k));
    const fs = 13 * kk;
    const tx = s(inset + 32, kk);
    const ty = y + @divTrunc(s(field_h, kk) - text.height(fs), 2);
    if (self.search.items.len == 0) {
        const hint = if (self.searchable) "Search text in captures" else "Search needs Tesseract (not installed)";
        // the reason stays legible: it is all the field has to say
        text.draw(cv, tx, ty, fs, op.muted, hint);
    } else {
        var buf: [256]u8 = undefined;
        const shown = text.ellipsize(&buf, fs, .regular, self.search.items, s(panel_w - inset - 10, kk) - tx, .start);
        text.draw(cv, tx, ty, fs, op.fg, shown);
    }
}

/// The grid, drawn into its own band-sized buffer (so it clips) and
/// copied into the panel.
fn drawGrid(self: *Panel, panel: []u32, pw: u32, ph: u32, kk: f64, op: Opaque) !void {
    const top = s(self.gridTop(), kk);
    const view_h = s(self.gridViewH(), kk);
    const grid = try self.gpa.alloc(u32, @as(usize, pw) * @as(usize, @intCast(@max(1, view_h))));
    defer self.gpa.free(grid);
    @memset(grid, op.panel);
    var band: Band = .{ .gc = Canvas.init(grid, pw, @intCast(@max(1, view_h))), .px = grid, .w = pw, .h = @intCast(@max(1, view_h)) };
    const gc = &band.gc;
    if (self.shown.items.len == 0) {
        const msg = if (!self.cfg.history) "History is off (history=false)" else if (self.search.items.len > 0) "No capture has that text" else "Nothing copied or saved yet";
        fui.textCentered(gc, .{ .x = 0, .y = 0, .w = @intCast(pw), .h = @min(view_h, s(60, kk)) }, 13 * kk, op.muted, .regular, msg);
    }
    const now = sys.realtimeSec();
    const now_local = now + clock.utcOffset(self.gpa, self.env.tz, now);
    for (self.shown.items, 0..) |idx, n| {
        const r = self.itemRect(n);
        const rx = s(r.x, kk);
        const ry = s(r.y, kk) - top;
        if (ry + s(layout.itemH(), kk) < 0 or ry > view_h) continue;
        try drawItem(self, &band, idx, rx, ry, s(r.w, kk), kk, now_local, op);
    }
    for (0..@intCast(view_h)) |row| {
        const dy = @as(usize, @intCast(top)) + row;
        if (dy >= ph) break;
        @memcpy(panel[dy * pw ..][0..pw], grid[row * pw ..][0..pw]);
    }
}

/// The grid's band: a canvas on it, and its pixels for the blit.
const Band = struct { gc: Canvas, px: []u32, w: u32, h: u32 };

/// One capture at rx, ry of the grid: its thumbnail, pick or hover ring,
/// and when it was taken.
fn drawItem(self: *Panel, band: *Band, idx: usize, rx: i32, ry: i32, rw: i32, kk: f64, now_local: i64, op: Opaque) !void {
    const gc = &band.gc;
    const rh = s(thumb_h, kk);
    const it = &self.items.items[idx];
    const tw: u32 = @intCast(rw);
    const tth: u32 = @intCast(rh);
    // a rounded thumbnail, the picture fitted to it (cached per size)
    const pic: fui.Image = if (it.thumb) |t| .{ .px = t.pixels, .w = t.width, .h = t.height } else .{ .px = &.{}, .w = 0, .h = 0 };
    const thumb = try it.fit.ensure(self.gpa, pic, tw, tth, .auto, op.field);
    effects.blitRounded(band.px, band.w, band.h, thumb, tw, tth, rx, ry, s(8, kk));
    const ring: Rect = .{ .x = rx, .y = ry, .w = rw, .h = rh };
    if (self.selected == idx) {
        barkit.focusRing(gc, ring, 8 * kk, kk, op.accent);
    } else if (self.hover_item == idx) {
        shapes.roundRectRing(gc, ring.expand(s(2, kk)), 10 * kk, 1.5 * kk, op.line);
    }
    var tb: [32]u8 = undefined;
    const then = @divFloor(it.entry.meta.time_ms, 1000);
    const when = clock.relTime(&tb, now_local, then + clock.utcOffset(self.gpa, self.env.tz, then));
    text.draw(gc, rx, ry + rh + s(6, kk), 11 * kk, op.muted, when);
    if (it.entry.meta.saved.len > 0) {
        const w2 = text.width(11 * kk, when);
        text.draw(gc, rx + w2 + s(6, kk), ry + rh + s(6, kk), 11 * kk, op.muted, "· saved");
    }
}

/// The action bar for the picked capture (Annotate dimmed if it cannot).
fn drawActions(self: *const Panel, cv: *Canvas, it: *const Item, kk: f64, op: Opaque) void {
    footerLine(self, cv, kk, op);
    for (layout.action_names, 0..) |name, i| {
        const r = self.actionRect(i);
        const cx = (ff(r.x) + ff(r.w) / 2) * kk;
        const dim = i == 2 and !it.entry.editable;
        const color = if (dim) op.line else if (self.hover_action == i) op.accent else op.fg;
        icons.drawAt(cv, layout.action_icons[i], cx, (ff(r.y) + 13) * kk, 16 * kk, .{}, color);
        fui.textCentered(cv, scale.rect(.{ .x = r.x, .y = r.y + 24, .w = r.w, .h = 14 }, kk), 10 * kk, if (dim) op.line else op.muted, .regular, name);
    }
}

/// The footer's separator, above the action bar.
fn footerLine(self: *const Panel, cv: *Canvas, kk: f64, op: Opaque) void {
    const ay = s(self.actionRect(0).y, kk);
    cv.fillRect(s(inset, kk), ay - s(2, kk), s(panel_w - 2 * inset, kk), @max(1, s(1, kk)), op.line);
}

/// "Clear history…" in the footer, the first of two steps.
fn drawClear(self: *const Panel, cv: *Canvas, kk: f64, op: Opaque) void {
    footerLine(self, cv, kk, op);
    const r = scale.rect(self.clearRect(), kk);
    if (self.hover_clear) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, 7 * kk, op.hover);
    const red = theme.legible(op.destructive, op.panel, theme.aa_text);
    fui.textCentered(cv, r, 12 * kk, if (self.hover_clear) red else op.muted, .regular, "Clear history\u{2026}");
}

/// "Clear N captures?" with Cancel and a destructive Clear.
fn drawConfirm(self: *const Panel, cv: *Canvas, kk: f64, op: Opaque) void {
    footerLine(self, cv, kk, op);
    const cancel = scale.rect(self.confirmRect(.cancel), kk);
    const clear = scale.rect(self.confirmRect(.clear), kk);
    var buf: [48]u8 = undefined;
    const n = self.items.items.len;
    const q = std.fmt.bufPrint(&buf, "Clear {d} capture{s}?", .{ n, if (n == 1) "" else "s" }) catch "Clear all?";
    text.drawStyled(cv, s(inset, kk), cancel.y + @divTrunc(cancel.h - text.height(12 * kk), 2), 12 * kk, op.fg, .semibold, q);
    barkit.textButton(cv, cancel, kk, self.th, .secondary, ff(@intFromBool(self.hover_confirm == .cancel)), "Cancel");
    barkit.textButton(cv, clear, kk, self.th, .destructive, ff(@intFromBool(self.hover_confirm == .clear)), "Clear");
}
