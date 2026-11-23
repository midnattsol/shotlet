//! The floating control of a recording: a small Glass pill next to the
//! recorded area (below it, else above, else inside its bottom edge),
//! never inside the area when there is room outside. During the
//! countdown it shows the seconds left (click it to start at once, × to
//! cancel); while recording, the elapsed time, pause/resume, stop and
//! discard.
//!
//! Placement as for the thumbnail: a layer-shell overlay surface where
//! the compositor has one, else a window titled "shotlet:rec:X:Y" that the
//! GNOME Shell extension puts at X, Y (logical) and keeps above, handing
//! the keyboard back to the app that had it.
//! On GNOME a recording of a whole monitor has no floating control: the
//! top bar's stop button (the extension's) is not in the way.

const std = @import("std");
const desktop = @import("../../platform/api.zig").desktop;
const env_mod = @import("../../app/env.zig");
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;
const floatwin = @import("../floatwin.zig");
const press = @import("../press.zig");
const scale = @import("../scale.zig");
const theme = @import("../theme.zig");
const text = @import("../../gfx/text.zig");
const region = @import("../../record/region.zig");
const geom = @import("../../geom.zig");
const engine_mod = @import("../../record/engine.zig");
const ctlsock = @import("../../record/ctlsock.zig");
const draw = @import("control_draw.zig");
const Env = env_mod.Env;

pub const Outcome = enum { stop, discard };

pub const Control = struct {
    gpa: std.mem.Allocator,
    win: window.Window,
    bus: *desktop.Session,
    /// logical position on the desktop, and the monitor it is on
    pos: [2]i32,
    covers_monitor: bool = false,
    layer: bool,
    hover: ?draw.Button = null,
    pressed: press.Press(draw.Button) = .{},
    dirty: bool = true,
    state: draw.State = .{},
    last_draw_ms: i64 = 0,

    pub fn open(gpa: std.mem.Allocator, env: Env, bus: *desktop.Session, area: geom.Rect) !Control {
        text.init(gpa);
        errdefer text.deinit();
        var c: Control = .{ .gpa = gpa, .win = try window.Window.init(gpa, env), .bus = bus, .pos = .{ 0, 0 }, .layer = false };
        errdefer c.win.deinit();
        const mon = monitorOf(&c.win, area);
        c.pos = place(area, mon);
        c.covers_monitor = inside(area, mon);
        c.state.th = theme.load(gpa, env, 300);
        // on GNOME the extension reads where to put it from the title
        var tbuf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "shotlet:rec:{d}:{d}", .{ c.pos[0], c.pos[1] }) catch "shotlet:rec";
        c.layer = try floatwin.open(&c.win, .{
            .title = title,
            .namespace = "shotlet-rec",
            .size = draw.windowSize(),
            .anchor = .{ .top = true, .left = true },
            .margin = .{ c.pos[1] - mon.y, 0, 0, c.pos[0] - mon.x },
        });
        const pill = draw.pillRect();
        try c.win.setInputRegion(0, &.{.{ .x = pill.x, .y = pill.y, .w = pill.w, .h = pill.h }});
        return c;
    }

    pub fn close(self: *Control) void {
        self.win.deinit();
        text.deinit();
    }

    pub fn fd(self: *const Control) sys.fd_t {
        return self.win.pollFd();
    }

    pub fn waitMs(self: *const Control) i32 {
        return self.win.pollTimeoutMs(if (self.state.mode == .recording) 250 else 100);
    }

    /// The button under a pointer position (physical px).
    fn hitAt(self: *const Control, x: f64, y: f64) ?draw.Button {
        const k = scale.of(self.win.scale120);
        return draw.hit(scale.toLogical(x, k), scale.toLogical(y, k), self.state.mode);
    }

    /// Count down `seconds`; false when cancelled (× or a stop or discard
    /// command), true at zero or when clicked to start at once.
    pub fn countdown(self: *Control, seconds: u32, server: *ctlsock.Server) bool {
        const end = sys.monoMs() + @as(i64, seconds) * 1000;
        self.state.mode = .countdown;
        while (true) {
            const left = end - sys.monoMs();
            if (left <= 0) return true;
            self.state.count = @intCast(@divTrunc(left + 999, 1000));
            if (self.pump()) |b| switch (b) {
                .cancel, .discard => return false,
                else => return true,
            };
            var conn: sys.fd_t = -1;
            if (server.poll(&conn)) |cmd| {
                ctlsock.Server.reply(conn, "ok countdown");
                if (cmd == .stop or cmd == .discard) return false;
            }
            self.render() catch {};
            var fds = [_]sys.pollfd{ .{ .fd = self.fd(), .events = sys.POLL.IN, .revents = 0 }, .{ .fd = server.fd, .events = sys.POLL.IN, .revents = 0 } };
            _ = sys.poll(&fds, self.waitMs()) catch {};
        }
    }

    /// While recording: handle input and redraw; an outcome when a button
    /// ends the recording.
    pub fn step(self: *Control, eng: *engine_mod.Engine) ?Outcome {
        self.state.mode = .recording;
        self.state.paused = eng.paused();
        const ms = eng.elapsedMs();
        if (@divTrunc(ms, 1000) != @divTrunc(self.state.elapsed_ms, 1000) or self.state.paused) self.dirty = true;
        self.state.elapsed_ms = ms;
        if (self.pump()) |b| switch (b) {
            .stop => return .stop,
            .discard => return .discard,
            .pause => if (eng.paused()) eng.unpause() else eng.pause(),
            else => {},
        };
        self.render() catch {};
        return null;
    }

    /// Window events; the button clicked (pressed and released over it),
    /// if any.
    fn pump(self: *Control) ?draw.Button {
        var clicked: ?draw.Button = null;
        while (self.win.nextEventTimeout(0) catch null) |ev| {
            switch (ev) {
                .resize, .frame_done => self.dirty = true,
                .pointer_motion => |m| {
                    const h = self.hitAt(m.x, m.y);
                    if (h != self.hover) self.dirty = true;
                    self.hover = h;
                },
                .pointer_button => |b| if (b.button == .left) {
                    const h = self.hitAt(b.x, b.y);
                    if (b.pressed) self.pressed.down(h, b.x, b.y) else if (self.pressed.up(h)) |c| {
                        clicked = c;
                    }
                },
                .close => clicked = .stop,
                else => {},
            }
        }
        return clicked;
    }

    fn render(self: *Control) !void {
        const now = sys.monoMs();
        // the dot pulses: a frame every quarter second while recording
        if (self.state.mode == .recording and now - self.last_draw_ms >= 250) self.dirty = true;
        if (!self.dirty or !floatwin.canDraw(&self.win)) return;
        self.dirty = false;
        self.last_draw_ms = now;
        const px = try self.win.backBuffer();
        @memset(px, 0);
        self.state.hover = self.hover;
        self.state.pulse = @mod(now, 1000) < 500;
        draw.paint(self.gpa, px, self.win.width, self.win.height, scale.of(self.win.scale120), &self.state);
        try floatwin.presentStraight(&self.win, px);
    }
};

fn monitorOf(win: *window.Window, area: geom.Rect) geom.Rect {
    var rects: [window.max_outputs]geom.Rect = undefined;
    var n: usize = 0;
    for (win.outputList()) |o| {
        if (o.id == 0) continue;
        const r = o.logicalRect();
        rects[n] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        n += 1;
    }
    const i = region.bestMonitor(area, rects[0..n]) orelse return area;
    return rects[i];
}

/// Top-left of the control window: the pill centred `gap` under the
/// area, else above it, else inside its bottom edge; the window on the
/// area's monitor.
pub fn place(area: geom.Rect, mon: geom.Rect) [2]i32 {
    const sz = draw.windowSize();
    const w: i32 = @intCast(sz[0]);
    const h: i32 = @intCast(sz[1]);
    const pill = draw.pillRect();
    const gap = 18;
    const x = std.math.clamp(area.x + @divTrunc(area.w - w, 2), mon.x, @max(mon.x, mon.right() - w));
    var py = area.bottom() + gap;
    if (py + pill.h + pill.y > mon.bottom()) py = area.y - gap - pill.h;
    if (py - pill.y < mon.y) py = area.bottom() - pill.h - 32;
    return .{ x, std.math.clamp(py - pill.y, mon.y, @max(mon.y, mon.bottom() - h)) };
}

/// Whether the control would sit inside the area (it would be recorded).
pub fn inside(area: geom.Rect, mon: geom.Rect) bool {
    const p = place(area, mon);
    const pill = draw.pillRect();
    const r: geom.Rect = .{ .x = p[0] + pill.x, .y = p[1] + pill.y, .w = pill.w, .h = pill.h };
    return r.intersect(area) != null;
}

test "the control goes under the area, else above, else inside" {
    const mon: geom.Rect = .{ .x = 0, .y = 0, .w = 1600, .h = 900 };
    const below = place(.{ .x = 100, .y = 100, .w = 400, .h = 300 }, mon);
    try std.testing.expectEqual(@as(i32, 400 + 18), below[1] + draw.pillRect().y);
    try std.testing.expect(!inside(.{ .x = 100, .y = 100, .w = 400, .h = 300 }, mon));
    const above = place(.{ .x = 100, .y = 500, .w = 400, .h = 395 }, mon);
    try std.testing.expect(above[1] < 500);
    try std.testing.expect(inside(mon, mon));
}
