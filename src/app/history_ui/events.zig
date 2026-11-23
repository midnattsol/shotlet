//! Input of the "Recent captures" panel: hover, clicks, the wheel, and
//! keys (Enter copies, Delete removes, arrows move the pick, typing
//! searches, Esc clears the search, then the pick, then closes). Clear
//! history asks first; any other click or key backs out of it. A click
//! acts on release over what was pressed (ui/press.zig).

const std = @import("std");
const log = std.log.scoped(.history);
const window = @import("../../platform/api.zig").window;
const focus = @import("../../ui/focus.zig");
const utf8 = @import("../../gfx/utf8.zig");
const layout = @import("layout.zig");
const Panel = @import("panel.zig").Panel;

const pad = layout.pad;
const inset = layout.inset;
const header_h = layout.header_h;

fn hitItem(self: *const Panel, x: i32, y: i32) ?usize {
    if (y < self.gridTop() or y >= self.gridTop() + self.gridViewH()) return null;
    for (self.shown.items, 0..) |idx, n| {
        if (self.itemRect(n).contains(x, y)) return idx;
    }
    return null;
}

fn hitAction(self: *const Panel, x: i32, y: i32) ?usize {
    if (self.selected == null) return null;
    for (0..layout.action_names.len) |i| if (self.actionRect(i).contains(x, y)) return i;
    return null;
}

/// Clear history shows in the footer while nothing is picked.
fn hitClear(self: *const Panel, x: i32, y: i32) bool {
    return self.selected == null and !self.confirm_clear and self.items.items.len > 0 and self.clearRect().contains(x, y);
}

fn hitConfirm(self: *const Panel, x: i32, y: i32) ?layout.Confirm {
    if (!self.confirm_clear) return null;
    for ([_]layout.Confirm{ .cancel, .clear }) |c| if (self.confirmRect(c).contains(x, y)) return c;
    return null;
}

fn onMotion(self: *Panel, bx: f64, by: f64) void {
    const kk = self.k();
    const x: i32 = @intFromFloat(bx / kk - pad);
    const y: i32 = @intFromFloat(by / kk - pad);
    const inside = bx >= 0;
    const hi = if (inside) hitItem(self, x, y) else null;
    const ha = if (inside) hitAction(self, x, y) else null;
    const hc = inside and hitClear(self, x, y);
    const hf = if (inside) hitConfirm(self, x, y) else null;
    const hx = inside and self.closeRect().contains(x, y);
    if (hi != self.hover_item or ha != self.hover_action or hc != self.hover_clear or hf != self.hover_confirm or hx != self.hover_close) self.dirty = true;
    self.hover_item = hi;
    self.hover_action = ha;
    self.hover_clear = hc;
    self.hover_confirm = hf;
    self.hover_close = hx;
}

/// Returns false to close the panel.
pub fn onEvent(self: *Panel, ev: window.InputEvent) !bool {
    switch (ev) {
        .close => return false,
        .resize, .frame_done => self.dirty = true,
        .pointer_motion => |m| onMotion(self, m.x, m.y),
        .pointer_button => |b| {
            onMotion(self, b.x, b.y);
            if (b.button != .left) return true;
            if (b.pressed) return onPress(self, b.x, b.y);
            return onClick(self, self.click.up(hovered(self)) orelse return true);
        },
        .pointer_axis => |a| {
            const maxs = @max(0, self.contentH() - self.gridViewH());
            self.scroll = std.math.clamp(self.scroll + @as(i32, @intFromFloat(a.value * 4)), 0, maxs);
            self.dirty = true;
        },
        .key => |key| {
            if (!key.pressed) return true;
            if (!onKey(self, key)) return false;
            self.dirty = true;
        },
    }
    return true;
}

/// What a click now would act on (the hover onMotion keeps).
fn hovered(self: *const Panel) ?layout.Target {
    if (self.hover_close) return .close;
    if (self.confirm_clear) return if (self.hover_confirm) |c| .{ .confirm = c } else .outside;
    if (self.hover_clear) return .clear;
    if (self.hover_action) |a| return .{ .action = a };
    if (self.hover_item) |i| return .{ .item = i };
    return null;
}

/// A left press: on a target, the start of a click; on the header, a
/// move of the window.
fn onPress(self: *Panel, bx: f64, by: f64) !bool {
    const y: i32 = @intFromFloat(by / self.k() - pad);
    const t = hovered(self);
    self.click.down(t, bx, by);
    if (t == null and y < inset + header_h + 4) try self.win.startMoveOf(0);
    return true;
}

/// A click on `t`; returns false to close.
fn onClick(self: *Panel, t: layout.Target) !bool {
    switch (t) {
        .close => return false,
        .clear => askClear(self),
        .confirm => |c| if (c == .clear) try self.clearAll() else backOut(self),
        .outside => backOut(self),
        .action => |a| self.act(@fromBackingInt(@intCast(a))),
        .item => |i| self.selected = if (self.selected == i) null else i,
    }
    self.hover_confirm = null;
    self.dirty = true;
    return true;
}

/// The first step of Clear history: ask.
fn askClear(self: *Panel) void {
    self.confirm_clear = true;
    self.hover_clear = false;
    log.info("asking before clearing {d} captures", .{self.items.items.len});
}

/// Not clearing after all.
fn backOut(self: *Panel) void {
    self.confirm_clear = false;
    log.info("clearing cancelled", .{});
}

/// A key press; returns false to close.
fn onKey(self: *Panel, key: window.Key) bool {
    if (self.confirm_clear) {
        // any key backs out of clearing; Esc does nothing else
        backOut(self);
        if (key.code == .escape) return true;
    }
    switch (key.code) {
        .escape => {
            if (self.search.items.len > 0) {
                self.search.clearRetainingCapacity();
                self.filter();
            } else if (self.selected != null) {
                self.selected = null;
            } else return false;
        },
        .delete => self.act(.delete),
        .enter, .kp_enter => self.act(.copy),
        .backspace => if (self.search.items.len > 0) {
            self.search.shrinkRetainingCapacity(utf8.prevBoundary(self.search.items, self.search.items.len));
            self.filter();
        },
        .left, .right, .up, .down, .tab => moveSelection(self, key),
        else => if (key.ctrl and key.code == .c) {
            self.act(.copy);
        } else if (key.ctrl and key.code == .s) {
            self.act(.save);
        } else if (self.searchable and key.text().len > 0 and !key.ctrl) {
            self.search.appendSlice(self.gpa, key.text()) catch {};
            self.filter();
        },
    }
    return true;
}

/// The arrows and Tab move the pick through the grid (up and down by a
/// row of two), wrapping.
fn moveSelection(self: *Panel, key: window.Key) void {
    const n = self.shown.items.len;
    if (n == 0) return;
    const cur: ?usize = if (self.selected) |s| std.mem.indexOfScalar(usize, self.shown.items, s) else null;
    const pos: usize = switch (key.code) {
        .down => if (cur) |c| (c + 2) % n else 0,
        .up => if (cur) |c| (c + n - @min(n, 2)) % n else n - 1,
        else => focus.cycle(n, cur, if (focus.action(key, .horizontal) == .prev) .prev else .next).?,
    };
    self.selected = self.shown.items[pos];
    // keep it in view
    const r = self.itemRect(pos);
    if (r.y < self.gridTop()) self.scroll -= self.gridTop() - r.y;
    if (r.bottom() > self.gridTop() + self.gridViewH()) self.scroll += r.bottom() - self.gridTop() - self.gridViewH();
}
