//! The scrolling capture's control: a small glass card beside the region
//! with the stitched image growing in it, what is happening (or why it
//! stopped, in plain words) and its buttons:
//!
//!   running, warning   Stop                         Enter; Esc cancels
//!   paused             Cancel  Finish  Continue     Esc, Enter, C or Space
//!   done               Finish (the editor opens by itself)
//!   failed             Close                        Enter or Esc
//!
//! Light or dark with the desktop (ui/theme.zig). It changes in place:
//! the layout is the same in every phase, only words and buttons change,
//! and nothing animates (so reduced motion has nothing to reduce).
//!
//! Its window is titled "shotlet:scroll": the GNOME extension keeps it
//! above other windows and only steps a scrolling capture while it is on
//! screen. With layer shell it is an overlay in the top-right corner.

const std = @import("std");
const sys = @import("../platform/api.zig").sys;
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const scale = @import("scale.zig");
const press = @import("press.zig");
const barkit = @import("barkit.zig");
const floatui = @import("floatui.zig");
const floatwin = @import("floatwin.zig");
const material = @import("material.zig");
const window = @import("../platform/api.zig").window;
const Rect = @import("shapes.zig").Rect;

pub const title = "shotlet:scroll";
/// logical size
pub const width = 264;
pub const height = 356;
const pad = 14;
const radius = 18;
const preview_y = pad + 60;
const preview_h = 196;
const button_h = 32;
const button_gap = 6;

pub const Phase = enum {
    running,
    /// running, with something to say (the person scrolled too fast)
    warning,
    /// stopped short: Continue, Finish or Cancel
    paused,
    /// complete; the editor opens in a moment
    done,
    /// it could not start (no frame of the region): why, and Close
    failed,
};

pub const Action = enum { finish, cancel, @"continue" };

/// Rows of the image so far, for the preview.
pub const Source = struct {
    ctx: *const anyopaque,
    width: u32,
    height: u32,
    row: *const fn (ctx: *const anyopaque, y: u32) []const u32,
};

const Button = struct { r: Rect, action: Action, label: []const u8, primary: bool };

pub const Hud = struct {
    win: *window.Window,
    th: theme.Theme,
    /// the card's colours (theme.Opaque: no backdrop blur for a client)
    look: theme.Opaque,
    phase: Phase = .running,
    headline_buf: [96]u8 = undefined,
    headline: []const u8 = "Starting\u{2026}",
    hint_buf: [96]u8 = undefined,
    hint: []const u8 = "",
    detail_buf: [48]u8 = undefined,
    detail: []const u8 = "",
    buttons_buf: [3]Button = undefined,
    buttons: []const Button = &.{},
    hover: ?Action = null,
    /// a click is a press and a release on the same button (ui/press.zig)
    pressed: press.Press(Action) = .{},
    dirty: bool = true,

    pub fn open(win: *window.Window, th: theme.Theme) !Hud {
        _ = try floatwin.open(win, .{
            .title = title,
            .namespace = "shotlet-scroll",
            .size = .{ width, height },
            .anchor = .{ .top = true, .right = true },
            .margin = .{ 24, 24, 0, 0 },
            .keyboard = .on_demand,
        });
        return .{ .win = win, .th = th, .look = theme.Opaque.of(th) };
    }

    /// What the card says: `headline`, an optional `hint` under it, and
    /// the image's height so far.
    pub fn show(self: *Hud, phase: Phase, headline: []const u8, hint: []const u8, height_px: u32) void {
        self.phase = phase;
        self.headline = copy(&self.headline_buf, headline);
        self.hint = copy(&self.hint_buf, hint);
        var nbuf: [24]u8 = undefined;
        self.detail = std.fmt.bufPrint(&self.detail_buf, "{s} px tall", .{grouped(&nbuf, height_px)}) catch "";
        self.dirty = true;
    }

    /// A message "Headline \u{2014} hint" on two lines, the hint capitalised.
    pub fn showMessage(self: *Hud, phase: Phase, message: []const u8, height_px: u32) void {
        const sep = " \u{2014} ";
        const i = std.mem.indexOf(u8, message, sep) orelse return self.show(phase, message, "", height_px);
        var hbuf: [96]u8 = undefined;
        const hint = copy(&hbuf, message[i + sep.len ..]);
        if (hint.len > 0) hbuf[0] = std.ascii.toUpper(hbuf[0]);
        self.show(phase, message[0..i], hint, height_px);
    }

    fn k(self: *const Hud) f64 {
        return scale.of(self.win.scale120);
    }

    fn sc(self: *const Hud, v: anytype) i32 {
        return scale.px(v, self.k());
    }

    pub fn draw(self: *Hud, src: ?Source) !void {
        if (!self.dirty or !floatwin.canDraw(self.win)) return;
        self.dirty = false;
        const bw = self.win.width;
        const bh = self.win.height;
        const gpa = self.win.alloc;
        const card = try gpa.alloc(u32, @as(usize, bw) * bh);
        defer gpa.free(card);
        var cv = render.Canvas.init(card, bw, bh);
        self.drawCard(&cv, src);
        const px = try self.win.backBuffer();
        @memset(px, 0);
        floatui.place(gpa, .{ .px = px, .w = bw, .h = bh }, .{ .px = card, .w = bw, .h = bh }, .{ 0, 0 }, self.radiusPx(), null, self.k());
        try floatwin.presentStraight(self.win, px);
    }

    fn radiusPx(self: *const Hud) f64 {
        return @floatFromInt(self.sc(radius));
    }

    /// Everything on the card, on an opaque canvas of the window's size.
    fn drawCard(self: *Hud, cv: *render.Canvas, src: ?Source) void {
        const lk = self.look;
        @memset(cv.px, lk.panel);
        material.hairline(cv, .{ .x = 0, .y = 0, .w = cv.w, .h = cv.h }, self.radiusPx(), lk.line);
        const x0 = self.sc(pad);
        const inner = cv.w - 2 * x0;
        const fs = theme.font_small * self.k();
        text.drawStyled(cv, x0, self.sc(pad), theme.font_label * self.k(), lk.fg, .semibold, "Scrolling capture");
        const loud = self.phase != .running;
        const head_style: text.Style = if (loud) .semibold else .regular;
        var ebuf: [128]u8 = undefined;
        text.drawStyled(cv, x0, self.sc(pad + 22), fs, if (loud) lk.fg else lk.muted, head_style, text.ellipsize(&ebuf, fs, head_style, self.headline, inner, .end));
        text.draw(cv, x0, self.sc(pad + 38), fs, lk.muted, text.ellipsize(&ebuf, fs, .regular, self.hint, inner, .end));
        const pv: Rect = .{ .x = x0, .y = self.sc(preview_y), .w = inner, .h = self.sc(preview_h) };
        cv.fillRect(pv.x, pv.y, pv.w, pv.h, lk.field);
        if (src) |s| drawPreview(cv, pv, s);
        if (self.phase != .failed) text.drawStyled(cv, x0, pv.y + pv.h + self.sc(8), fs, lk.muted, text.Style.regular.num(), self.detail);
        self.layoutButtons(cv.w, cv.h);
        for (self.buttons) |b| {
            const hot: f64 = if (self.hover == b.action) 1 else 0;
            barkit.textButton(cv, b.r, self.k(), self.th, if (b.primary) .primary else .secondary, hot, b.label);
        }
    }

    /// The bottom row for this phase: one wide button, or three.
    fn layoutButtons(self: *Hud, w: i32, h: i32) void {
        const bh = self.sc(button_h);
        const y = h - self.sc(pad) - bh;
        const x0 = self.sc(pad);
        const inner = w - 2 * x0;
        const b = &self.buttons_buf;
        if (self.phase != .paused) {
            b[0] = .{ .r = .{ .x = x0, .y = y, .w = inner, .h = bh }, .action = .finish, .label = switch (self.phase) {
                .done => "Finish",
                .failed => "Close",
                else => "Stop",
            }, .primary = true };
            self.buttons = b[0..1];
            return;
        }
        const gap = self.sc(button_gap);
        const bw = @divTrunc(inner - 2 * gap, 3);
        const acts = [3]Action{ .cancel, .finish, .@"continue" };
        const labels = [3][]const u8{ "Cancel", "Finish", "Continue" };
        for (0..3) |i| {
            const x = x0 + @as(i32, @intCast(i)) * (bw + gap);
            const last = i == 2;
            b[i] = .{ .r = .{ .x = x, .y = y, .w = if (last) x0 + inner - x else bw, .h = bh }, .action = acts[i], .label = labels[i], .primary = last };
        }
        self.buttons = b[0..3];
    }

    /// The bottom of the image, as wide as the preview.
    fn drawPreview(cv: *render.Canvas, pv: Rect, s: Source) void {
        if (s.width == 0 or s.height == 0) return;
        const ratio = @as(f64, @floatFromInt(pv.w)) / @as(f64, @floatFromInt(s.width));
        const shown: u32 = @min(s.height, @as(u32, @intFromFloat(@as(f64, @floatFromInt(pv.h)) / ratio)));
        const first = s.height - shown;
        const dh: i32 = @intFromFloat(@as(f64, @floatFromInt(shown)) * ratio);
        const top = pv.y + pv.h - dh;
        var y: i32 = 0;
        while (y < dh) : (y += 1) {
            const sy = first + @min(shown - 1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(y)) / ratio)));
            const row = s.row(s.ctx, sy);
            const out = cv.px[@as(usize, @intCast((top + y) * cv.w + pv.x))..][0..@intCast(pv.w)];
            for (out, 0..) |*o, x| o.* = row[@min(s.width - 1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(x)) / ratio)))] | 0xFF000000;
        }
    }

    /// Wait up to `ms` for input: the action asked for, if any.
    pub fn poll(self: *Hud, ms: i32) !?Action {
        const deadline = sys.monoMs() + ms;
        while (true) {
            const left = deadline - sys.monoMs();
            const ev = (try self.win.nextEventTimeout(@intCast(@max(0, left)))) orelse return null;
            if (self.handle(ev)) |a| return a;
            if (left <= 0) return null;
        }
    }

    fn handle(self: *Hud, ev: window.InputEvent) ?Action {
        switch (ev) {
            .close => return .cancel,
            .resize, .frame_done => self.dirty = true,
            .key => |key| if (key.pressed and !key.repeat) return keyAction(self.phase, key),
            .pointer_motion => |m| {
                const over = self.buttonAt(m.x, m.y);
                if (over != self.hover) self.dirty = true;
                self.hover = over;
            },
            .pointer_button => |b| if (b.button == .left) {
                const hit = self.buttonAt(b.x, b.y);
                if (b.pressed) self.pressed.down(hit, b.x, b.y) else return self.pressed.up(hit);
            },
            else => {},
        }
        return null;
    }

    fn buttonAt(self: *const Hud, x: f64, y: f64) ?Action {
        for (self.buttons) |b| if (b.r.contains(@intFromFloat(x), @intFromFloat(y))) return b.action;
        return null;
    }
};

/// Enter finishes, Esc cancels; when paused, C or Space continues.
pub fn keyAction(phase: Phase, key: window.Key) ?Action {
    if (key.ctrl or key.alt) return null;
    switch (key.code) {
        .escape => return .cancel,
        .enter, .kp_enter => return .finish,
        else => {},
    }
    if (phase != .paused) return null;
    const c = if (key.char != 0) key.char == 'c' or key.char == 'C' else key.code == .c;
    return if (c or key.code == .space) .@"continue" else null;
}

fn copy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// `v` with a thin space between groups of three digits: 20 000.
pub fn grouped(buf: []u8, v: u32) []const u8 {
    var digits: [10]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{v}) catch unreachable;
    const sep = "\u{2009}";
    var n: usize = 0;
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0 and n + sep.len <= buf.len) {
            @memcpy(buf[n..][0..sep.len], sep);
            n += sep.len;
        }
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

test "keys: Enter finishes, Esc cancels, C or Space continues only when paused" {
    const key = struct {
        fn of(code: window.KeyCode, char: u21) window.Key {
            return .{ .code = code, .pressed = true, .ctrl = false, .shift = false, .char = char };
        }
    }.of;
    try std.testing.expectEqual(@as(?Action, .finish), keyAction(.running, key(.enter, 0)));
    try std.testing.expectEqual(@as(?Action, .cancel), keyAction(.paused, key(.escape, 0)));
    try std.testing.expectEqual(@as(?Action, .@"continue"), keyAction(.paused, key(.space, ' ')));
    try std.testing.expectEqual(@as(?Action, .@"continue"), keyAction(.paused, key(.c, 'c')));
    // C where the layout puts it, not the physical key
    try std.testing.expectEqual(@as(?Action, null), keyAction(.paused, key(.c, 'j')));
    try std.testing.expectEqual(@as(?Action, null), keyAction(.running, key(.space, ' ')));
    var ctrl_c = key(.c, 'c');
    ctrl_c.ctrl = true;
    try std.testing.expectEqual(@as(?Action, null), keyAction(.paused, ctrl_c));
}

test "the labels fit their buttons" {
    text.init(std.testing.allocator);
    defer text.deinit();
    if (!text.available()) return error.SkipZigTest;
    const inner = width - 2 * pad;
    const bw = @divTrunc(inner - 2 * button_gap, 3);
    for ([_][]const u8{ "Cancel", "Finish", "Continue" }) |l|
        try std.testing.expect(text.widthStyled(theme.font_label, .semibold, l) + 12 <= bw);
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("20\u{2009}000", grouped(&buf, 20_000));
}

// the scrolling capture's region picker is tested from here (main.zig
// does not list it; wave 3 registers the tests there)
test {
    _ = @import("region_pick.zig");
}
