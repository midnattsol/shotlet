//! The record picker: the frozen desktop, one fullscreen surface per
//! monitor, dimmed outside the chosen area; drag an area (or click for
//! the whole monitor), move and resize it, and pick the format and sound
//! on the bar under it (picker_bar.zig). Enter or Record starts, Esc
//! cancels. Works in logical desktop pixels (what recordings use). It
//! opens on the frozen desktop as it looked and dims in, and eases back
//! to it before closing (the GNOME extension turns mutter's zoom off).

const std = @import("std");
const capture = @import("../../app/capture.zig");
const env_mod = @import("../../app/env.zig");
const window = @import("../../platform/api.zig").window;
const render = @import("../../gfx/render.zig");
const resample = @import("../../gfx/resample.zig");
const settings_mod = @import("../../record/settings.zig");
const selmod = @import("picker_sel.zig");
const bar = @import("picker_bar.zig");
const motion = @import("../motion.zig");
const theme = @import("../theme.zig");
const mixRows = @import("../../gfx/effects.zig").mixRows;
const dim = @import("../dim.zig");
const selchrome = @import("../selchrome.zig");
const shapes = @import("../shapes.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const focus = @import("../focus.zig");
const material = @import("../material.zig");
const Rect = selmod.Rect;
const Point = selmod.Point;

pub const Result = union(enum) { area: Rect, cancelled };

const Pane = struct {
    /// the monitor's logical rectangle
    rect: Rect,
    /// the image part showing it
    src: capture.Monitor,
    base: []u32 = &.{},
    bw: u32 = 0,
    bh: u32 = 0,
};

pub const Picker = struct {
    gpa: std.mem.Allocator,
    win: window.Window,
    cap: *const capture.Capture,
    panes: [window.max_surfaces]Pane = undefined,
    mon_rects: [window.max_surfaces]Rect = undefined,
    n: usize = 0,
    sel: selmod.Selection,
    st: bar.State,
    /// the bar, in logical desktop pixels (null: not shown)
    bar_at: ?Point = null,
    mouse: Point = .{ .x = 0, .y = 0 },
    /// the mid-edge handle showing under the pointer, for repaints
    edge_handle: ?usize = null,
    /// of 256, what the dim outside the area keeps (ui/dim.zig)
    dim_keep: u32 = 256,
    /// the bar item pressed (it acts when released over it)
    pressed_bar: press.Press(bar.Item) = .{},
    bar_shadow: material.ShadowCache = .{},
    dirty: bool = true,
    result: ?Result = null,
    /// the dim easing in from the first frame, and out once there is a
    /// result
    life: motion.Life = .{ .in_ms = theme.motion_fast, .out_ms = theme.motion_fast },

    pub fn deinit(self: *Picker) void {
        for (self.panes[0..self.n]) |p| self.gpa.free(p.base);
        self.bar_shadow.release(self.gpa);
        self.win.deinit();
    }

    fn setup(self: *Picker) void {
        const surfs = self.win.surfaceList();
        self.n = @min(surfs.len, self.panes.len);
        for (surfs[0..self.n], 0..) |s, i| {
            const r: Rect = if (s.out_w > 0) .{ .x = s.x, .y = s.y, .w = @intCast(s.out_w), .h = @intCast(s.out_h) } else .{ .x = 0, .y = 0, .w = @intCast(@max(1, s.logical_w)), .h = @intCast(@max(1, s.logical_h)) };
            self.panes[i] = .{ .rect = r, .src = self.sourceFor(r) };
            self.mon_rects[i] = r;
        }
        self.sel.monitors = self.mon_rects[0..self.n];
    }

    /// The captured monitor shown on the surface at logical `r`.
    fn sourceFor(self: *const Picker, r: Rect) capture.Monitor {
        for (self.cap.monitors) |m| if (m.logical) |l| {
            if (l.x == r.x and l.y == r.y) return m;
        };
        return self.cap.monitors[0];
    }

    fn paneAt(self: *const Picker, p: Point) usize {
        for (self.panes[0..self.n], 0..) |pane, i| if (selmod.inside(pane.rect, p)) return i;
        return 0;
    }

    fn toLogical(self: *const Picker, surface: u8, x: f64, y: f64) Point {
        const i = @min(surface, self.n - 1);
        const p = self.panes[i];
        const sx = @as(f64, @floatFromInt(p.rect.w)) / @as(f64, @floatFromInt(@max(1, p.bw)));
        const sy = @as(f64, @floatFromInt(p.rect.h)) / @as(f64, @floatFromInt(@max(1, p.bh)));
        return .{ .x = p.rect.x + @as(i32, @intFromFloat(@round(x * sx))), .y = p.rect.y + @as(i32, @intFromFloat(@round(y * sy))) };
    }

    fn scaleOf(self: *const Picker, i: usize) f64 {
        return @as(f64, @floatFromInt(self.panes[i].bw)) / @as(f64, @floatFromInt(@max(1, self.panes[i].rect.w)));
    }

    // --- events

    fn onEvent(self: *Picker, ev: window.InputEvent) !void {
        switch (ev) {
            .resize => |r| try self.onResize(r.surface, r.w, r.h),
            .frame_done => {},
            .close => self.result = .cancelled,
            .pointer_motion => |m| self.onMotion(self.toLogical(m.surface, m.x, m.y)),
            .pointer_button => |b| {
                const p = self.toLogical(b.surface, b.x, b.y);
                if (b.button == .right and b.pressed) self.result = .cancelled;
                if (b.button != .left) return;
                if (b.pressed) self.onPress(p, b.x, b.y) else self.onRelease(p);
                self.win.setCursor(self.cursorAt(p)) catch {};
            },
            .key => |k| if (k.pressed) self.onKey(k),
            .pointer_axis => {},
        }
    }

    fn onResize(self: *Picker, surface: u8, w: u32, h: u32) !void {
        if (surface >= self.n) return;
        const p = &self.panes[surface];
        if (w == 0 or h == 0) return;
        self.gpa.free(p.base);
        p.base = &.{};
        p.base = try self.gpa.alloc(u32, @as(usize, w) * h);
        const img = &self.cap.image;
        const off = p.src.y * img.width + p.src.x;
        resample.box(img.pixels[off..], img.width, p.src.w, p.src.h, p.base, w, h);
        p.bw = w;
        p.bh = h;
        self.dirty = true;
    }

    fn barItemAt(self: *const Picker, p: Point) ?bar.Item {
        const at = self.bar_at orelse return null;
        return bar.hit(p.x - at.x, p.y - at.y);
    }

    fn onMotion(self: *Picker, p: Point) void {
        self.mouse = p;
        if (self.sel.drag != .none) {
            self.sel.motion(p);
            self.dirty = true;
        }
        const eh = self.edgeHandle();
        if (eh != self.edge_handle) self.dirty = true;
        self.edge_handle = eh;
        const hv = if (self.sel.drag == .none) self.barItemAt(p) else null;
        if (hv != self.st.hover) self.dirty = true;
        self.st.hover = hv;
        self.win.setCursor(self.cursorAt(p)) catch {};
    }

    /// The mid-edge handle the pointer brings out (selchrome.handleShown).
    fn edgeHandle(self: *const Picker) ?usize {
        const s = self.sel.sel orelse return null;
        for ([_]usize{ 1, 3, 5, 7 }) |i| {
            if (selchrome.handleShown(shapeRect(s), i, .{ .x = self.mouse.x, .y = self.mouse.y }, grab)) return i;
        }
        return null;
    }

    /// What the drag in progress does, else what a press at `p` would.
    fn cursorAt(self: *const Picker, p: Point) window.Cursor {
        switch (self.sel.drag) {
            .moving => return .grabbing,
            .resizing => |rz| return selchrome.handleCursor(rz.handle),
            .selecting => return .crosshair,
            .none => {},
        }
        if (self.st.hover != null or self.pressed_bar.held() != null) return .arrow;
        if (self.sel.handleAt(p)) |h| return selchrome.handleCursor(h);
        if (self.sel.sel) |s| if (selmod.inside(s, p)) return .grab;
        return .crosshair;
    }

    fn onPress(self: *Picker, p: Point, x: f64, y: f64) void {
        if (self.barItemAt(p)) |it| {
            self.pressed_bar.down(it, x, y);
            return;
        }
        self.sel.press(p);
        self.dirty = true;
    }

    fn onRelease(self: *Picker, p: Point) void {
        if (self.pressed_bar.held() != null) {
            if (self.pressed_bar.up(self.barItemAt(p))) |it| self.activate(it);
            return;
        }
        self.sel.release(p);
        self.dirty = true;
    }

    fn activate(self: *Picker, it: bar.Item) void {
        switch (it) {
            .record => if (self.sel.sel) |s| {
                self.result = .{ .area = s };
            },
            .close => self.result = .cancelled,
            else => bar.toggle(&self.st, it),
        }
        self.dirty = true;
    }

    fn onKey(self: *Picker, k: window.Key) void {
        switch (focus.action(k, .none) orelse return) {
            .close => self.result = .cancelled,
            .activate => {
                const s = self.sel.sel orelse self.sel.monitorAt(self.mouse) orelse return;
                self.result = .{ .area = s };
            },
            .next, .prev => {},
        }
    }

    // --- drawing

    fn placeBar(self: *Picker) void {
        const s = self.sel.sel orelse {
            self.bar_at = null;
            return;
        };
        if (self.sel.drag == .selecting or s.w < 4) {
            self.bar_at = null;
            return;
        }
        const sz = bar.size();
        const mon = self.panes[self.paneAt(.{ .x = s.x + @divTrunc(s.w, 2), .y = s.bottom() - 1 })].rect;
        const x = std.math.clamp(s.x + @divTrunc(s.w - sz[0], 2), mon.x + 8, @max(mon.x + 8, mon.right() - sz[0] - 8));
        var y = s.bottom() + 14;
        if (y + sz[1] + 40 > mon.bottom()) y = s.y - sz[1] - 14;
        if (y < mon.y + 8) y = s.bottom() - sz[1] - 14;
        self.bar_at = .{ .x = x, .y = y };
    }

    fn draw(self: *Picker) !void {
        const now = motion.now();
        if (self.life.busy(now)) self.dirty = true;
        if (!self.dirty) return;
        self.placeBar();
        for (0..self.n) |i| {
            const s = &self.win.surfaceList()[i];
            if (s.frame_pending or self.panes[i].bw == 0) return;
        }
        self.dirty = false;
        self.life.start(now);
        const k: u32 = @intFromFloat(@round(self.life.alpha(now) * 256));
        for (0..self.n) |i| try self.renderPane(@intCast(i), k);
    }

    /// A logical desktop rect in pane i's buffer pixels (by its edges).
    fn bufRect(self: *const Picker, i: usize, r: Rect) Rect {
        const o = self.panes[i].rect;
        const b = scale.rect(.{ .x = r.x - o.x, .y = r.y - o.y, .w = r.w, .h = r.h }, self.scaleOf(i));
        return .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
    }

    fn renderPane(self: *Picker, i: u8, k_dim: u32) !void {
        const p = &self.panes[i];
        const px = try self.win.backBufferOf(i);
        @memcpy(px[0..p.base.len], p.base);
        var cv = render.Canvas.init(px, p.bw, p.bh);
        const k = self.scaleOf(i);
        const sb: ?Rect = if (self.sel.sel) |s| self.bufRect(i, s) else null;
        dim.outside(px[0..p.base.len], p.bw, p.bh, if (sb) |r| shapeRect(r) else null, self.dim_keep);
        if (sb) |r| self.drawSelection(i, &cv, shapeRect(r), k);
        if (self.sel.sel == null and i == self.paneAt(self.mouse)) drawHint(&cv, k, self.st.th);
        if (self.bar_at) |at| {
            const b = self.bufRect(i, .{ .x = at.x, .y = at.y, .w = 1, .h = 1 });
            if (selmod.inside(p.rect, at)) bar.paint(self.gpa, &cv, b.x, b.y, k, &self.st, &self.bar_shadow);
        }
        if (k_dim < 256) mixRows(px[0..p.base.len], p.base, px[0..p.base.len], k_dim);
        try self.win.presentSurface(i);
    }

    /// As the editor draws a capture's selection: the edge, the handles
    /// while nothing is dragged, the size (in recorded pixels) above it.
    fn drawSelection(self: *const Picker, i: u8, cv: *render.Canvas, r: shapes.Rect, k: f64) void {
        const th = self.st.th;
        selchrome.edge(cv, r, th);
        if (self.sel.drag == .none) {
            const m: ?shapes.Point = if (i == self.paneAt(self.mouse)) blk: {
                const b = self.bufRect(i, .{ .x = self.mouse.x, .y = self.mouse.y, .w = 1, .h = 1 });
                break :blk .{ .x = b.x, .y = b.y };
            } else null;
            selchrome.handles(cv, r, m, @max(6, @as(i32, @intFromFloat(@round(grab * k)))), k, th);
        }
        const logical = self.sel.sel.?;
        var buf: [32]u8 = undefined;
        const label = selchrome.sizeLabel(&buf, logical.w, logical.h);
        selchrome.sizePill(cv, selchrome.sizePillRect(label, r, cv.w, k), k, th, label);
    }
};

/// how near a handle the pointer grabs it, logical px (as the editor's)
const grab = 10;

fn shapeRect(r: Rect) shapes.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// The hint in the middle of the pane, before anything is chosen.
fn drawHint(cv: *render.Canvas, k: f64, th: theme.Theme) void {
    const s = "Drag to choose what to record \u{00B7} click: the whole screen \u{00B7} Esc: cancel";
    const sz = selchrome.hintPillSize(s, k);
    _ = selchrome.hintPill(cv, .{ .x = @divTrunc(cv.w - sz[0], 2), .y = @divTrunc(cv.h - sz[1], 2) }, s, k, th);
}

/// Show the picker over the frozen desktop `cap`; the chosen area, or
/// cancelled. `set` holds the bar's choices (format, sound, overlays);
/// `th` is the desktop's appearance.
pub fn pick(gpa: std.mem.Allocator, env: env_mod.Env, cap: *const capture.Capture, set: *settings_mod.Settings, overlays: bool, th: theme.Theme) !Result {
    var p: Picker = .{
        .gpa = gpa,
        .win = try window.Window.init(gpa, env),
        .cap = cap,
        .sel = .{ .monitors = &.{} },
        .st = .{ .set = set, .overlays = overlays, .th = th },
        .dim_keep = dim.keepFor(cap.image.pixels, cap.image.width, cap.image.height),
    };
    defer p.deinit();
    try p.win.openOutputs("Shotlet");
    p.setup();
    p.win.setCursor(.crosshair) catch {};
    while (p.result == null or p.life.busy(motion.now())) {
        if (p.result != null) p.life.leave(motion.now());
        if (try p.win.nextEventTimeout(p.win.pollTimeoutMs(if (p.life.busy(motion.now())) 8 else 100))) |ev| {
            if (p.result == null) try p.onEvent(ev);
            while (p.win.queue.items.len > 0) {
                const e = try p.win.nextEvent();
                if (p.result == null) try p.onEvent(e);
            }
        }
        try p.draw();
    }
    p.win.closeWindow();
    return p.result.?;
}
