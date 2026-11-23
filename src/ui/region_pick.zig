//! The scrolling capture's region picker: an area over the frozen desktop
//! (ui/freeze_pick.zig, the same selection as the editor's and the
//! recording picker's), and under it a bar in the record bar's look:
//!
//!   [ × | ↧ Start scrolling capture ]
//!
//! Start or Enter confirms, × or Esc cancels. The region goes out in the
//! capture's image pixels.

const std = @import("std");
const window = @import("../platform/api.zig").window;
const render = @import("../gfx/render.zig");
const freeze_pick = @import("freeze_pick.zig");
const barkit = @import("barkit.zig");
const material = @import("material.zig");
const selchrome = @import("selchrome.zig");
const icons = @import("icons.zig");
const press = @import("press.zig");
const scale = @import("scale.zig");
const theme = @import("theme.zig");
const geom = @import("../geom.zig");
const Rect = geom.Rect;

pub const Result = union(enum) {
    cancelled,
    region: Rect,
};

const Item = enum { close, start };

const pad: i32 = @intFromFloat(theme.bar_pad);
const gap: i32 = @intFromFloat(theme.bar_gap);
const btn: i32 = @intFromFloat(theme.button);
const sep_w: i32 = 1 + 2 * @as(i32, @intFromFloat(theme.sep_margin));
const bar_h = 2 * pad + btn;

/// The bar as the picker's mode (freeze_pick.run): × and Start, in
/// logical pixels from its top-left.
const Mode = struct {
    label: []const u8,
    hover: ?Item = null,
    pressed: press.Press(Item) = .{},
    shadow: material.ShadowCache = .{},

    fn rectOf(self: *const Mode, it: Item) Rect {
        return switch (it) {
            .close => .{ .x = pad, .y = pad, .w = btn, .h = btn },
            .start => .{ .x = pad + btn + gap + sep_w + gap, .y = pad, .w = barkit.primaryWidth(1, self.label), .h = btn },
        };
    }

    fn hit(self: *const Mode, at: ?[2]i32) ?Item {
        const a = at orelse return null;
        for ([_]Item{ .close, .start }) |it| if (self.rectOf(it).contains(a[0], a[1])) return it;
        return null;
    }

    pub fn barSize(self: *Mode) [2]i32 {
        return .{ self.rectOf(.start).right() + pad, bar_h };
    }

    pub fn onBar(self: *Mode, ev: freeze_pick.BarEvent) freeze_pick.BarReply {
        const it = self.hit(ev.at);
        switch (ev.kind) {
            .hover => {
                const changed = it != self.hover;
                self.hover = it;
                return .{ .over = it != null or self.pressed.held() != null, .repaint = changed };
            },
            .press => {
                if (it != null) self.pressed.down(it, ev.x, ev.y);
                return .{ .over = it != null, .repaint = it != null };
            },
            .release => return switch (self.pressed.up(it) orelse return .{ .repaint = true }) {
                .start => .{ .act = .confirm },
                .close => .{ .act = .cancel },
            },
        }
    }

    /// Glass over the blurred desktop, as the record bar; Start in the
    /// accent, lit while held; the tooltip of the item under the pointer.
    pub fn paintBar(self: *Mode, gpa: std.mem.Allocator, cv: *render.Canvas, at: geom.Point, k: f64, th: theme.Theme) void {
        const sz = self.barSize();
        const r: Rect = .{ .x = at.x, .y = at.y, .w = scale.px(sz[0], k), .h = scale.px(sz[1], k) };
        const rad = theme.bar_radius * k;
        material.shadow(gpa, cv, r, rad, th.bar_shadow, k, 1, &self.shadow);
        material.glass(gpa, cv, r, rad, th, k);
        const sx = pad + btn + gap + @as(i32, @intFromFloat(theme.sep_margin));
        barkit.separator(cv, at.x + scale.px(sx, k), at.y + scale.px((scale.ff(bar_h) - theme.sep_h) / 2, k), scale.px(theme.sep_h, k), th);
        const cr = self.place(.close, at, k);
        barkit.fill(cv, cr, k, th, .plain, if (self.hover == .close) 1 else 0);
        icons.drawAt(cv, .close, scale.ff(cr.x) + scale.ff(cr.w) / 2, scale.ff(cr.y) + scale.ff(cr.h) / 2, theme.icon * k, .{}, barkit.ink(th, .plain, false));
        const lit = self.hover == .start or self.pressed.held() == .start;
        barkit.primary(cv, self.place(.start, at, k), k, if (lit) th.accent_fill_hover else th.accent_fill, th.on_accent, .{ .icon = .capture_scroll }, self.label);
        if (self.hover) |hv| {
            const name, const key = switch (hv) {
                .close => .{ "Cancel", "Esc" },
                .start => .{ self.label, "Enter" },
            };
            const tz = selchrome.tooltipSize(name, key, k);
            selchrome.tooltip(cv, .{ .x = at.x, .y = r.bottom() + scale.px(8, k), .w = tz[0], .h = tz[1] }, name, key, k, th);
        }
    }

    fn place(self: *const Mode, it: Item, at: geom.Point, k: f64) Rect {
        const ir = scale.rect(self.rectOf(it), k);
        return .{ .x = at.x + ir.x, .y = at.y + ir.y, .w = ir.w, .h = ir.h };
    }
};

const hint = "Drag over what to scroll \u{00B7} click: the whole screen \u{00B7} Esc: cancel";

/// Pick a region of `frozen` on `win`'s surfaces (closed again before
/// returning); `label` names the Start button.
pub fn pick(gpa: std.mem.Allocator, win: *window.Window, frozen: freeze_pick.Frozen, label: []const u8, th: theme.Theme) !Result {
    var mode: Mode = .{ .label = label };
    defer mode.shadow.release(gpa);
    var p = freeze_pick.Picker.init(gpa, win, frozen, th, hint);
    defer p.deinit();
    return switch (try p.run("Shotlet", &mode)) {
        .area => |r| .{ .region = r },
        .cancelled => .cancelled,
    };
}

test "Start and × act on a press and release over them; releasing elsewhere cancels the press" {
    var m: Mode = .{ .label = "Start" };
    const sz = m.barSize();
    try std.testing.expectEqual(@as(i32, 46), sz[1]);
    const start = m.rectOf(.start);
    const on: [2]i32 = .{ start.x + 4, start.y + 4 };
    try std.testing.expect(m.onBar(.{ .kind = .press, .at = on, .x = 0, .y = 0 }).over);
    try std.testing.expect(m.onBar(.{ .kind = .release, .at = .{ 2, 2 }, .x = 0, .y = 0 }).act == null);
    _ = m.onBar(.{ .kind = .press, .at = on, .x = 0, .y = 0 });
    try std.testing.expect(m.onBar(.{ .kind = .release, .at = on, .x = 0, .y = 0 }).act.? == .confirm);
    const x: [2]i32 = .{ pad + 4, pad + 4 };
    try std.testing.expect(m.onBar(.{ .kind = .hover, .at = x, .x = 0, .y = 0 }).repaint);
    _ = m.onBar(.{ .kind = .press, .at = x, .x = 0, .y = 0 });
    try std.testing.expect(m.onBar(.{ .kind = .release, .at = x, .x = 0, .y = 0 }).act.? == .cancel);
    try std.testing.expect(m.hit(.{ start.right() + 2, 10 }) == null);
}
