//! The record picker: an area over the frozen desktop (ui/freeze_pick.zig,
//! the same selection as the editor's and the scrolling capture's), and
//! under it the bar (picker_bar.zig) choosing the format and sound.
//! Enter or Record starts, Esc cancels. The area goes out in logical
//! desktop pixels (what recordings use).

const std = @import("std");
const env_mod = @import("../../app/env.zig");
const window = @import("../../platform/api.zig").window;
const render = @import("../../gfx/render.zig");
const settings_mod = @import("../../record/settings.zig");
const bar = @import("picker_bar.zig");
const freeze_pick = @import("../freeze_pick.zig");
const theme = @import("../theme.zig");
const press = @import("../press.zig");
const material = @import("../material.zig");
const geom = @import("../../geom.zig");

pub const Result = union(enum) { area: geom.Rect, cancelled };

/// The record bar as the picker's mode (freeze_pick.run).
const Mode = struct {
    st: bar.State,
    /// the item pressed (it acts when released over it)
    pressed: press.Press(bar.Item) = .{},
    shadow: material.ShadowCache = .{},

    pub fn barSize(_: *Mode) [2]i32 {
        return bar.size();
    }

    pub fn onBar(self: *Mode, ev: freeze_pick.BarEvent) freeze_pick.BarReply {
        const it: ?bar.Item = if (ev.at) |a| bar.hit(a[0], a[1]) else null;
        switch (ev.kind) {
            .hover => {
                const changed = it != self.st.hover;
                self.st.hover = it;
                return .{ .over = it != null or self.pressed.held() != null, .repaint = changed };
            },
            .press => {
                if (it != null) self.pressed.down(it, ev.x, ev.y);
                return .{ .over = it != null };
            },
            .release => {
                const done = self.pressed.up(it) orelse return .{};
                return switch (done) {
                    .record => .{ .act = .confirm },
                    .close => .{ .act = .cancel },
                    else => blk: {
                        bar.toggle(&self.st, done);
                        break :blk .{ .repaint = true };
                    },
                };
            },
        }
    }

    pub fn paintBar(self: *Mode, gpa: std.mem.Allocator, cv: *render.Canvas, at: geom.Point, k: f64, _: theme.Theme) void {
        bar.paint(gpa, cv, at.x, at.y, k, &self.st, &self.shadow);
    }
};

const hint = "Drag to choose what to record \u{00B7} click: the whole screen \u{00B7} Esc: cancel";

/// Show the picker over the frozen desktop `frozen`; the chosen area
/// (logical), or cancelled. `set` holds the bar's choices (format, sound,
/// overlays); `th` is the desktop's appearance.
pub fn pick(gpa: std.mem.Allocator, env: env_mod.Env, frozen: freeze_pick.Frozen, set: *settings_mod.Settings, overlays: bool, th: theme.Theme) !Result {
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    var mode: Mode = .{ .st = .{ .set = set, .overlays = overlays, .th = th } };
    defer mode.shadow.release(gpa);
    var p = freeze_pick.Picker.init(gpa, &win, frozen, th, hint);
    defer p.deinit();
    return switch (try p.run("Shotlet", &mode)) {
        .area => |r| .{ .area = p.toLogical(r) },
        .cancelled => .cancelled,
    };
}

/// A spot (logical, from the bar's top-left) on item `it`.
fn spotOf(it: bar.Item) [2]i32 {
    var x: i32 = 0;
    while (x < bar.size()[0]) : (x += 1) if (bar.hit(x, @divTrunc(bar.size()[1], 2)) == it) return .{ x + 2, @divTrunc(bar.size()[1], 2) };
    unreachable;
}

test "the bar's items act on a release over them" {
    var s: settings_mod.Settings = .{};
    var m: Mode = .{ .st = .{ .set = &s, .overlays = true, .th = theme.of(.{}) } };
    const gif = spotOf(.gif);
    try std.testing.expect(m.onBar(.{ .kind = .hover, .at = gif, .x = 0, .y = 0 }).repaint);
    try std.testing.expect(m.onBar(.{ .kind = .press, .at = gif, .x = 0, .y = 0 }).over);
    // released off it: nothing
    try std.testing.expectEqual(freeze_pick.BarReply{}, m.onBar(.{ .kind = .release, .at = null, .x = 0, .y = 0 }));
    try std.testing.expect(s.format == .mp4);
    _ = m.onBar(.{ .kind = .press, .at = gif, .x = 0, .y = 0 });
    _ = m.onBar(.{ .kind = .release, .at = gif, .x = 0, .y = 0 });
    try std.testing.expect(s.format == .gif);
    inline for (.{ .{ bar.Item.record, .confirm }, .{ bar.Item.close, .cancel } }) |c| {
        _ = m.onBar(.{ .kind = .press, .at = spotOf(c[0]), .x = 0, .y = 0 });
        try std.testing.expect(m.onBar(.{ .kind = .release, .at = spotOf(c[0]), .x = 0, .y = 0 }).act.? == c[1]);
    }
}
