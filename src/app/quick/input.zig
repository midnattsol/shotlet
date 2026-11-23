//! Input and time of the quick access thumbnails: hover, clicks, drags
//! out, the right-click menu, keyboard shortcuts and focus, and each
//! card's life (fade in, stay, fade out).

const std = @import("std");
const log = std.log.scoped(.quick_access);
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;
const focus = @import("../../ui/focus.zig");
const layout = @import("layout.zig");
const stack = @import("stack.zig");

const Quick = stack.Quick;
const Control = layout.Control;

pub fn onEvent(self: *Quick, ev: window.InputEvent) void {
    switch (ev) {
        .resize, .frame_done => self.dirty = true,
        .close => {
            const now = sys.monoMs();
            for (self.cards.items) |*c| c.life.leave(now);
        },
        .pointer_motion => |m| {
            onMotion(self, m.x, m.y);
            self.win.setCursor(cursorOf(self)) catch {};
        },
        .pointer_button => |b| {
            onButton(self, b.button, b.pressed, b.x, b.y);
            self.win.setCursor(cursorOf(self)) catch {};
        },
        .pointer_axis => {},
        .key => |k| if (k.pressed) {
            // a layer surface has the keyboard only while the pointer
            // is over it, but KWin keeps it focused after that: keys
            // then belong to whatever the person went back to typing
            // in, not to the thumbnail's shortcuts
            if (self.layer and !self.win.pointer_in) {
                log.debug("key ignored, the pointer is elsewhere", .{});
            } else onKey(self, k);
        },
    }
}

/// Hover, and a drag out once a pressed card moved far enough.
fn onMotion(self: *Quick, x: f64, y: f64) void {
    if (self.layer) self.win.setLayerKeyboard(0, if (self.win.pointer_in) .on_demand else .none) catch {};
    const h = self.hitAt(x, y);
    if (!std.meta.eql(h, self.hover)) self.dirty = true;
    self.hover = h;
    if (self.press.held()) |p| if (p.control == .body and self.dragging == null and self.press.dragged(x, y, self.factor())) {
        self.press.cancel();
        self.startDrag(p.card) catch |err| log.warn("drag failed: {t}", .{err});
    };
}

/// The hand over a card's picture, which drags the capture out (closed
/// while pressed); the pointing hand over the "Saved" link; the arrow
/// over its buttons and menu.
fn cursorOf(self: *const Quick) window.Cursor {
    const h = self.hover orelse return .arrow;
    if (h.control == .notice) return .pointer;
    if (h.control != .body) return .arrow;
    const held = if (self.press.held()) |p| p.control == .body else false;
    return window.Cursor.hand(held);
}

/// Right press toggles a card's menu; a left click (press and release
/// on the same control) activates it.
fn onButton(self: *Quick, button: window.Button, pressed: bool, x: f64, y: f64) void {
    const h = self.hitAt(x, y);
    self.hover = h;
    self.dirty = true;
    if (button == .right and pressed) {
        if (h) |hh| if (hh.control != .hint) {
            const c = &self.cards.items[hh.card];
            c.menu = !c.menu;
        };
    } else if (button == .left) {
        if (pressed) {
            self.press.down(h, x, y);
            self.focus = null;
        } else if (self.press.up(h)) |t| self.activate(t);
    }
}

/// the "Saved" link first while it shows (focusable says)
const focus_order = [_]Control{ .notice, .primary, .secondary, .annotate, .pin, .close };

/// Whether card i's control `ctl` takes the focus now.
fn focusable(self: *const Quick, i: usize, ctl: Control) bool {
    return ctl != .notice or linkShows(self, i);
}

fn linkShows(self: *const Quick, i: usize) bool {
    return i < self.cards.items.len and self.cards.items[i].notice.file(sys.monoMs()) != null;
}

fn onKey(self: *Quick, k: window.Key) void {
    self.dirty = true;
    const cur = self.current() orelse return;
    const card = &self.cards.items[cur];
    // Tab and the left/right arrows move focus along a card's controls
    if (focus.action(k, .horizontal)) |a| return switch (a) {
        .next, .prev => cycleFocus(self, if (a == .next) .next else .prev),
        // with nothing focused: the "Saved" link while it shows, else Copy
        .activate => if (self.focus) |fo| self.activate(fo) else if (card.notice.opensOn(k, sys.monoMs())) self.act(cur, .show_in_files) else self.act(cur, .copy),
        .close => if (card.menu) {
            card.menu = false;
        } else self.act(cur, .close),
    };
    switch (k.code) {
        .up, .down => {
            const n = self.cards.items.len;
            const c: usize = if (k.code == .up) (cur + 1) % n else (cur + n - 1) % n;
            const ctl = if (self.focus) |fo| fo.control else .primary;
            self.focus = .{ .card = c, .control = if (focusable(self, c, ctl)) ctl else .primary };
        },
        .delete => self.act(cur, .close),
        .c => if (k.ctrl) self.act(cur, .copy),
        .s => if (k.ctrl) self.act(cur, if (k.shift) .save_as else .save),
        .e, .a => if (!k.ctrl) self.act(cur, .annotate),
        .p => if (!k.ctrl) self.act(cur, .pin),
        else => {},
    }
}

/// Move focus to the next (or previous) control, across all cards.
fn cycleFocus(self: *Quick, dir: focus.Dir) void {
    const n = self.cards.items.len * focus_order.len;
    const cur: ?usize = if (self.focus) |fo|
        fo.card * focus_order.len + (std.mem.indexOfScalar(Control, &focus_order, fo.control) orelse 0)
    else
        null;
    // with nothing focused, Tab and Shift+Tab both start at the newest
    // card's first control
    var idx = (if (cur == null) 0 else focus.cycle(n, cur, dir)) orelse return;
    // past the controls that are not there now (the link once gone)
    while (!focusable(self, idx / focus_order.len, focus_order[idx % focus_order.len])) {
        idx = focus.cycle(n, idx, if (cur == null) .next else dir) orelse return;
    }
    self.focus = .{ .card = idx / focus_order.len, .control = focus_order[idx % focus_order.len] };
}

// --- time ---

/// Age the cards: keep them while used, fade them out when their time
/// is up, drop the faded ones.
pub fn tick(self: *Quick) void {
    const now = sys.monoMs();
    const keep_alive = self.win.pointer_in or self.dragging != null;
    var i: usize = 0;
    while (i < self.cards.items.len) {
        const c = &self.cards.items[i];
        if (c.menu or (keep_alive and c.life.leaving == 0)) c.deadline_ms = @max(c.deadline_ms, now + 2000);
        if (now >= c.deadline_ms) c.life.leave(now);
        if (onLink(self.hover, i)) c.notice.hold(now);
        if (c.notice.expire(now)) {
            self.dirty = true;
            // the link went from under the focus: the first button has it
            if (self.focus) |*fo| if (fo.card == i and fo.control == .notice) {
                fo.control = .primary;
            };
            if (onLink(self.hover, i)) {
                self.hover.?.control = .body;
                self.win.setCursor(cursorOf(self)) catch {};
            }
        }
        if (fading(c, now)) self.dirty = true;
        if (c.life.gone(now)) {
            self.remove(i);
            continue;
        }
        i += 1;
    }
}

fn onLink(h: ?layout.Hit, i: usize) bool {
    const hh = h orelse return false;
    return hh.card == i and hh.control == .notice;
}

/// Not drawn yet, fading in or out, or its controls fading: a frame per
/// refresh.
fn fading(c: *const stack.Card, now: i64) bool {
    return c.life.busy(now) or c.hov.busy(now);
}

pub fn nextWakeMs(self: *const Quick) i32 {
    var wait: i64 = 1000;
    const now = sys.monoMs();
    for (self.cards.items) |*c| {
        if (fading(c, now)) return 16;
        wait = @min(wait, c.deadline_ms - now);
        if (c.notice.left(now)) |l| wait = @min(wait, l);
    }
    return @intCast(std.math.clamp(wait, 5, 1000));
}
