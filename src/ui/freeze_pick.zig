//! The frozen desktop a picker chooses an area on: the recording picker
//! (ui/recui/picker.zig) and the scrolling capture's (ui/region_pick.zig).
//! One fullscreen surface per monitor shows its part of the capture
//! (ui/freeze_pane.zig), dimmed outside the area (ui/dim.zig) and easing in on
//! the first frame and out once done (motion.Life); the area's edge,
//! handles and size (ui/selchrome.zig) and its gestures (ui/areasel.zig,
//! kept on one monitor), all in the capture's image pixels. Enter
//! confirms, Esc, a right click or closing the surfaces cancels.
//!
//! A mode adds only its bar under the area (`run`'s `mode`):
//!   barSize(mode) [2]i32                  its logical size
//!   onBar(mode, BarEvent) BarReply        the pointer over it
//!   paintBar(mode, gpa, cv, at, k, th)    drawn at buffer point `at`
//!
//! A frame repaints only what changed: each surface keeps its part of the
//! capture plain and dimmed, and per back buffer where it drew anything
//! but the dimmed capture (the area, its chrome, the hint, the bar);
//! a frame copies back that and the new extent, and a surface with
//! nothing on it either time is not painted at all (two 4K monitors
//! would otherwise cost tens of milliseconds a frame).
//!
//! Surfaces are matched to the capture's monitors by their logical
//! rectangles (an exact match shows that monitor); with no match (the
//! layout unknown: --from, the Screenshot portal) each shows the whole
//! capture fitted (View.fit).

const std = @import("std");
const log = std.log.scoped(.area_picker);
const geom = @import("../geom.zig");
const window = @import("../platform/api.zig").window;
const render = @import("../gfx/render.zig");
const resample = @import("../gfx/resample.zig");
const mixRows = @import("../gfx/effects.zig").mixRows;
const view_mod = @import("view.zig");
const areasel = @import("areasel.zig");
const selchrome = @import("selchrome.zig");
const dim = @import("dim.zig");
const motion = @import("motion.zig");
const scale = @import("scale.zig");
const theme = @import("theme.zig");

const Rect = geom.Rect;
const Point = geom.Point;
const View = view_mod.View;
const Canvas = render.Canvas;

const pane_mod = @import("freeze_pane.zig");
pub const Frozen = pane_mod.Frozen;
pub const Pane = pane_mod.Pane;

/// The area chosen (image pixels), or none.
pub const Result = union(enum) { area: Rect, cancelled };

/// The pointer on a mode's bar: `at` in logical pixels from the bar's
/// top-left (null: off it), `x`, `y` the buffer point (ui/press.zig).
pub const BarEvent = struct {
    kind: enum { hover, press, release },
    at: ?[2]i32,
    x: f64,
    y: f64,
};

pub const BarReply = struct {
    /// over one of its controls (it takes presses; an arrow pointer)
    over: bool = false,
    repaint: bool = false,
    act: ?enum { confirm, cancel } = null,
};

/// how near a handle the pointer grabs it, logical px (as the editor's)
const grab = 10;

pub const Picker = struct {
    gpa: std.mem.Allocator,
    win: *window.Window,
    frozen: Frozen,
    th: theme.Theme,
    /// the hint before an area is chosen
    hint: []const u8,
    /// of 256, what the dim outside the area keeps
    keep: u32 = 256,
    panes: [window.max_surfaces]Pane = @splat(.{}),
    n: usize = 0,
    mon_rects: [window.max_outputs]Rect = undefined,
    sel: areasel.Selection = .{ .area = .{ .bounds = .empty } },
    /// the pointer: its surface and buffer point
    surface: u8 = 0,
    mouse: Point = .{ .x = -1, .y = -1 },
    /// the mid-edge handle showing (selchrome.handleShown), for repaints
    edge_shown: ?usize = null,
    /// the pointer is over the bar
    on_bar: bool = false,
    /// where the bar is: its surface and buffer top-left
    bar: ?struct { surface: u8, at: Point } = null,
    dirty: bool = true,
    result: ?Result = null,
    /// the first frame went out (the surfaces take the pointer from then)
    shown: bool = false,
    life: motion.Life = .{ .in_ms = theme.motion_fast, .out_ms = theme.motion_fast },

    pub fn init(gpa: std.mem.Allocator, win: *window.Window, frozen: Frozen, th: theme.Theme, hint: []const u8) Picker {
        return .{ .gpa = gpa, .win = win, .frozen = frozen, .th = th, .hint = hint, .keep = dim.keepFor(frozen.pixels, frozen.width, frozen.height) };
    }

    pub fn deinit(self: *Picker) void {
        for (&self.panes) |*p| p.release(self.gpa);
    }

    /// The areas: on one monitor of the capture.
    fn setArea(self: *Picker) void {
        const n = @min(self.frozen.monitors.len, self.mon_rects.len);
        for (self.frozen.monitors[0..n], 0..) |m, i| self.mon_rects[i] = m.pixelRect();
        self.sel.area = .{ .bounds = self.frozen.bounds(), .monitors = self.mon_rects[0..n], .one_monitor = true };
    }

    /// The view of a `w` x `h` surface at logical `r`: its monitor, else
    /// the whole capture fitted.
    fn viewFor(self: *const Picker, r: Rect, w: u32, h: u32) View {
        for (self.frozen.monitors) |m| if (m.logical) |l| {
            if (l.eql(r)) return view_mod.monitorView(m.pixelRect(), w, h);
        };
        return View.fit(self.frozen.width, self.frozen.height, .ofSize(w, h), 8);
    }

    /// Surface `i` is `w` x `h`: its part of the capture at that size.
    fn prepare(self: *Picker, i: usize, w: u32, h: u32) !void {
        try self.place(i, w, h);
        try self.panes[i].fill(self.gpa, self.frozen, self.keep);
    }

    /// Pane `i` sized `w` x `h` and placed on its monitor, not filled.
    fn place(self: *Picker, i: usize, w: u32, h: u32) !void {
        const p = &self.panes[i];
        p.release(self.gpa);
        if (w == 0 or h == 0) return;
        const s = self.win.surfaceList()[i];
        const l: Rect = if (s.out_w > 0) .{ .x = s.x, .y = s.y, .w = @intCast(s.out_w), .h = @intCast(s.out_h) } else .{ .x = 0, .y = 0, .w = @intCast(@max(1, s.logical_w)), .h = @intCast(@max(1, s.logical_h)) };
        try p.alloc(self.gpa, w, h, l, self.viewFor(l, w, h));
        self.dirty = true;
    }

    // --- mapping

    /// The image point at buffer point (`x`, `y`) of `surface`.
    fn imgAt(self: *const Picker, surface: u8, x: f64, y: f64) Point {
        const pt = self.panes[surface].view.toImgEdge(.{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) });
        return .{ .x = std.math.clamp(pt.x, 0, geom.dim(self.frozen.width)), .y = std.math.clamp(pt.y, 0, geom.dim(self.frozen.height)) };
    }

    /// The pane showing most of image rect `r`.
    fn paneOf(self: *const Picker, r: Rect) usize {
        var best: usize = 0;
        var best_a: i64 = -1;
        for (self.panes[0..self.n], 0..) |*p, i| {
            if (p.w == 0) continue;
            const b = p.view.rectToBuf(r).intersect(p.bounds());
            const a = if (b) |x| x.area() else 0;
            if (a > best_a) {
                best_a = a;
                best = i;
            }
        }
        return best;
    }

    /// Image rect `r` in the compositor's logical layout, through the
    /// surface showing most of it.
    pub fn toLogical(self: *const Picker, r: Rect) Rect {
        const p = &self.panes[self.paneOf(r)];
        const b = p.view.rectToBuf(r);
        const lx = struct {
            fn f(v: i32, k: f64, o: i32) i32 {
                return o + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(v)) / k)));
            }
        }.f;
        return .fromEdges(lx(b.x, p.k, p.logical.x), lx(b.y, p.k, p.logical.y), lx(b.right(), p.k, p.logical.x), lx(b.bottom(), p.k, p.logical.y));
    }

    fn radius(self: *const Picker, i: usize) i32 {
        return @max(6, scale.px(grab, self.panes[i].k));
    }

    /// What a press at the pointer takes hold of.
    fn grabHere(self: *const Picker) areasel.Grab {
        const s = self.sel.rect() orelse return .outside;
        return areasel.grabAt(self.panes[self.surface].view.rectToBuf(s), self.mouse, self.radius(self.surface));
    }

    // --- events

    fn onEvent(self: *Picker, mode: anytype, ev: window.InputEvent) !void {
        switch (ev) {
            .resize => |r| if (r.surface < self.n) try self.prepare(r.surface, r.w, r.h),
            .close => self.result = .cancelled,
            .pointer_motion => |m| if (m.x >= 0 and m.surface < self.n) self.onMotion(mode, m.surface, m.x, m.y),
            .pointer_button => |b| if (b.surface < self.n) self.onButton(mode, b),
            .key => |k| self.onKey(k),
            .frame_done, .pointer_axis => {},
        }
        if (ev == .pointer_motion or ev == .pointer_button or ev == .key)
            self.win.setCursor(if (self.on_bar and self.sel.drag == .none) .arrow else areasel.cursorFor(self.sel.drag, self.grabHere())) catch {};
    }

    /// The pointer on the bar, as `mode` sees it.
    fn barEvent(self: *Picker, mode: anytype, kind: @FieldType(BarEvent, "kind"), x: f64, y: f64) BarReply {
        const at: ?[2]i32 = if (self.bar) |b| if (b.surface == self.surface) .{
            scale.toLogical(x - scale.ff(b.at.x), self.panes[b.surface].k),
            scale.toLogical(y - scale.ff(b.at.y), self.panes[b.surface].k),
        } else null else null;
        const r = mode.onBar(.{ .kind = kind, .at = at, .x = x, .y = y });
        if (r.repaint) self.dirty = true;
        if (r.act) |a| self.result = switch (a) {
            .confirm => if (self.sel.rect()) |s| .{ .area = s } else null,
            .cancel => .cancelled,
        };
        return r;
    }

    fn onMotion(self: *Picker, mode: anytype, surface: u8, x: f64, y: f64) void {
        if (surface != self.surface) self.dirty = true;
        self.surface = surface;
        self.mouse = .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)) };
        if (self.sel.drag != .none) {
            self.sel.motion(self.imgAt(surface, x, y));
            self.dirty = true;
        }
        const eh = self.edgeShown();
        if (eh != self.edge_shown) self.dirty = true;
        self.edge_shown = eh;
        self.on_bar = self.sel.drag == .none and self.barEvent(mode, .hover, x, y).over;
    }

    /// The mid-edge handle the pointer brings out.
    fn edgeShown(self: *const Picker) ?usize {
        const s = self.sel.rect() orelse return null;
        const b = self.panes[self.surface].view.rectToBuf(s);
        for ([_]usize{ 1, 3, 5, 7 }) |i| if (selchrome.handleShown(b, i, self.mouse, self.radius(self.surface))) return i;
        return null;
    }

    fn onButton(self: *Picker, mode: anytype, b: @FieldType(window.InputEvent, "pointer_button")) void {
        self.surface = b.surface;
        self.mouse = .{ .x = @intFromFloat(@round(b.x)), .y = @intFromFloat(@round(b.y)) };
        if (b.button == .right) {
            if (b.pressed) self.result = .cancelled;
            return;
        }
        if (b.button != .left) return;
        self.dirty = true;
        if (b.pressed) {
            if (self.barEvent(mode, .press, b.x, b.y).over) return;
            self.sel.press(self.imgAt(b.surface, b.x, b.y), self.grabHere());
            self.on_bar = false;
        } else if (self.sel.drag != .none) {
            self.sel.motion(self.imgAt(b.surface, b.x, b.y));
            self.sel.release();
        } else _ = self.barEvent(mode, .release, b.x, b.y);
    }

    fn onKey(self: *Picker, k: window.Key) void {
        if (k.pressed and !k.ctrl) switch (k.code) {
            .escape => self.result = .cancelled,
            .enter, .kp_enter => if (self.sel.drag == .none) {
                if (self.sel.confirm(self.imgAt(self.surface, scale.ff(self.mouse.x), scale.ff(self.mouse.y)))) |s| self.result = .{ .area = s };
            },
            else => {},
        };
        if (self.sel.key(k)) self.dirty = true;
    }

    // --- drawing

    /// The bar under the area (above it, else inside it, where there is
    /// no room), on the surface showing most of it; none while an area
    /// is drawn out.
    fn placeBar(self: *Picker, size: [2]i32) void {
        self.bar = null;
        const s = self.sel.rect() orelse return;
        if (self.sel.drag == .drawing or s.w < 1 or s.h < 1) return;
        const i = self.paneOf(s);
        const p = &self.panes[i];
        const r = p.view.rectToBuf(s);
        const bw = scale.px(size[0], p.k);
        const bh = scale.px(size[1], p.k);
        const gap = scale.px(14, p.k);
        const edge = scale.px(8, p.k);
        const pw: i32 = @intCast(p.w);
        const x = std.math.clamp(r.x + @divTrunc(r.w - bw, 2), edge, @max(edge, pw - bw - edge));
        var y = r.bottom() + gap;
        if (y + bh + scale.px(40, p.k) > @as(i32, @intCast(p.h))) y = r.y - bh - gap;
        if (y < edge) y = r.bottom() - bh - gap;
        self.bar = .{ .surface = @intCast(i), .at = .{ .x = x, .y = y } };
    }

    fn draw(self: *Picker, mode: anytype) !void {
        const now = motion.now();
        if (self.life.busy(now)) self.dirty = true;
        if (!self.dirty) return;
        const surfs = self.win.surfaceList();
        for (self.panes[0..self.n], 0..) |p, i| if (surfs[i].alive and (surfs[i].frame_pending or p.w == 0)) return;
        self.placeBar(mode.barSize());
        self.dirty = false;
        self.life.start(now);
        const fade: u32 = @intFromFloat(@round(self.life.alpha(now) * 256));
        for (0..self.n) |i| if (surfs[i].alive) try self.paint(mode, i, fade);
        if (!self.shown) log.info("up on {d} surfaces", .{self.n});
        self.shown = true;
    }

    fn paint(self: *Picker, mode: anytype, i: usize, fade: u32) !void {
        const px = (try self.win.backBufferOf(@intCast(i)))[0..self.panes[i].base.len];
        const told = self.paintInto(mode, i, px, @intCast(self.win.surfaceList()[i].cur_buf), fade) orelse return;
        try self.win.presentDamaged(@intCast(i), told);
    }

    /// Pane `i`'s frame into its back buffer `px` (buffer `bi` of two):
    /// what changed since the frame on screen, or null when nothing did.
    fn paintInto(self: *Picker, mode: anytype, i: usize, px: []u32, bi: u1, fade: u32) ?Rect {
        const p = &self.panes[i];
        const now = self.extent(mode, i);
        // both buffers (so the one shown) have only the dimmed capture,
        // and so would this frame
        if (fade == 256 and now.isEmpty() and p.drawn[0].isEmpty() and p.drawn[1].isEmpty()) return null;
        const redo = if (fade < 256) p.bounds() else now.unite(p.drawn[bi]);
        self.compose(p, px, redo);
        var cv = Canvas.init(px, p.w, p.h);
        self.paintChrome(mode, &cv, i);
        if (fade < 256) mixRows(px, p.base, px, fade);
        const told = redo.unite(p.drawn[1 - bi]);
        p.drawn[bi] = if (fade < 256) p.bounds() else now;
        return told.clip(p.w, p.h) orelse p.bounds();
    }

    /// The dimmed capture over `r` of pane `p`, bright inside the area.
    fn compose(self: *const Picker, p: *const Pane, px: []u32, r: Rect) void {
        const c = r.clip(p.w, p.h) orelse return;
        const lit: ?Rect = if (self.sel.rect()) |s| p.view.rectToBuf(s) else null;
        var y = c.y;
        while (y < c.bottom()) : (y += 1) {
            const row = @as(usize, @intCast(y)) * p.w;
            var x0 = c.right();
            var x1 = c.right();
            if (lit) |b| if (y >= b.y and y < b.bottom()) {
                x0 = std.math.clamp(b.x, c.x, c.right());
                x1 = std.math.clamp(b.right(), x0, c.right());
            };
            const a: usize = row + @as(usize, @intCast(c.x));
            const sa: usize = row + @as(usize, @intCast(x0));
            const sb: usize = row + @as(usize, @intCast(x1));
            const e: usize = row + @as(usize, @intCast(c.right()));
            @memcpy(px[a..sa], p.dimmed[a..sa]);
            @memcpy(px[sa..sb], p.base[sa..sb]);
            @memcpy(px[sb..e], p.dimmed[sb..e]);
        }
    }

    /// The area, its chrome, the hint and the bar on pane `i`.
    fn paintChrome(self: *Picker, mode: anytype, cv: *Canvas, i: usize) void {
        const p = &self.panes[i];
        const s = self.sel.rect();
        if (s) |r| self.drawArea(cv, i, p.view.rectToBuf(r));
        if (s == null and i == self.surface) {
            const sz = selchrome.hintPillSize(self.hint, p.k);
            _ = selchrome.hintPill(cv, .{ .x = @divTrunc(cv.w - sz[0], 2), .y = @divTrunc(cv.h - sz[1], 2) }, self.hint, p.k, self.th);
        }
        if (self.bar) |bar| if (bar.surface == i) mode.paintBar(self.gpa, cv, bar.at, p.k, self.th);
    }

    /// Where pane `i` shows anything but the dimmed capture this frame
    /// (generously: the handles' shadows, the size pill, the bar's
    /// shadow and tooltips); empty when nothing.
    fn extent(self: *const Picker, mode: anytype, i: usize) Rect {
        const p = &self.panes[i];
        var r = Rect.empty;
        if (self.sel.rect()) |s| {
            const b = p.view.rectToBuf(s);
            r = r.unite(b.expand(scale.px(16, p.k)));
            var buf: [32]u8 = undefined;
            r = r.unite(selchrome.sizePillRect(selchrome.sizeLabel(&buf, s.w, s.h), b, @intCast(p.w), p.k).expand(scale.px(4, p.k)));
        } else if (i == self.surface) {
            const sz = selchrome.hintPillSize(self.hint, p.k);
            r = r.unite((Rect{ .x = @divTrunc(@as(i32, @intCast(p.w)) - sz[0], 2), .y = @divTrunc(@as(i32, @intCast(p.h)) - sz[1], 2), .w = sz[0], .h = sz[1] }).expand(scale.px(4, p.k)));
        }
        if (self.bar) |bar| if (bar.surface == i) {
            // the bar's rows, all the way across: its shadow, and the
            // tooltips above or below it
            const sz = mode.barSize();
            const room = scale.px(96, p.k);
            r = r.unite(.{ .x = 0, .y = bar.at.y - room, .w = @intCast(p.w), .h = scale.px(sz[1], p.k) + 2 * room });
        };
        return r.clip(p.w, p.h) orelse Rect.empty;
    }

    /// As the editor draws a capture's area: its edge, the handles while
    /// nothing is dragged, its size (image pixels) on the surface showing
    /// most of it.
    fn drawArea(self: *const Picker, cv: *Canvas, i: usize, r: Rect) void {
        const k = self.panes[i].k;
        selchrome.edge(cv, r, self.th);
        if (self.sel.drag == .none)
            selchrome.handles(cv, r, if (i == self.surface) self.mouse else null, self.radius(i), k, self.th);
        const s = self.sel.rect().?;
        if (i != self.paneOf(s)) return;
        var buf: [32]u8 = undefined;
        const label = selchrome.sizeLabel(&buf, s.w, s.h);
        selchrome.sizePill(cv, selchrome.sizePillRect(label, r, cv.w, k), k, self.th, label);
    }

    // --- running

    /// Open a surface per monitor and run until an area is chosen or the
    /// pick cancelled; the surfaces are closed again, after easing back
    /// to the plain desktop.
    pub fn run(self: *Picker, title: []const u8, mode: anytype) !Result {
        try self.win.openOutputs(title);
        defer self.win.closeWindow();
        self.n = @min(self.win.surfaceList().len, self.panes.len);
        self.setArea();
        self.win.setCursor(.crosshair) catch {};
        // every monitor's part at once, a thread each (two 4K monitors)
        for (self.win.surfaceList()[0..self.n], 0..) |s, i| if (s.alive) try self.place(i, s.width, s.height);
        try pane_mod.fillAll(self.gpa, self.frozen, self.panes[0..self.n], self.keep);
        while (self.result == null or self.life.busy(motion.now())) {
            if (self.result != null) self.life.leave(motion.now());
            const wait = self.win.pollTimeoutMs(if (self.life.busy(motion.now())) 8 else 100);
            if (try self.win.nextEventTimeout(wait)) |ev| {
                if (self.result == null) try self.onEvent(mode, ev);
                while (self.win.queue.items.len > 0) {
                    const e = try self.win.nextEvent();
                    if (self.result == null) try self.onEvent(mode, e);
                }
            }
            try self.draw(mode);
        }
        return self.result.?;
    }
};

// --- tests

const testing = std.testing;

test "image rects back in the layout, at the surface's scale" {
    var p: Picker = .{ .gpa = testing.allocator, .win = undefined, .frozen = .{ .pixels = &.{}, .width = 5440, .height = 1800 }, .th = theme.of(.{}), .hint = "" };
    // a 2x monitor (2560 logical wide shown on a 5120 px buffer) and a 1x one right of it
    p.panes[0] = .{ .w = 5120, .h = 1800, .k = 2, .logical = .{ .x = 0, .y = 0, .w = 2560, .h = 900 }, .view = view_mod.monitorView(.{ .x = 0, .y = 0, .w = 5120, .h = 1800 }, 5120, 1800) };
    p.panes[1] = .{ .w = 320, .h = 200, .k = 1, .logical = .{ .x = 2560, .y = 0, .w = 320, .h = 200 }, .view = view_mod.monitorView(.{ .x = 5120, .y = 0, .w = 320, .h = 200 }, 320, 200) };
    p.n = 2;
    try testing.expectEqual(Rect{ .x = 100, .y = 50, .w = 200, .h = 150 }, p.toLogical(.{ .x = 200, .y = 100, .w = 400, .h = 300 }));
    try testing.expectEqual(Rect{ .x = 2570, .y = 20, .w = 100, .h = 50 }, p.toLogical(.{ .x = 5130, .y = 20, .w = 100, .h = 50 }));
    try testing.expectEqual(Point{ .x = 5130, .y = 20 }, p.imgAt(1, 10, 20));
    try testing.expectEqual(@as(usize, 1), p.paneOf(.{ .x = 5000, .y = 0, .w = 300, .h = 10 }));
}

test "a frame painted from what changed equals one painted whole" {
    const w = 320;
    const h = 200;
    const gpa = testing.allocator;
    var img: [w * h]u32 = undefined;
    for (&img, 0..) |*c, i| c.* = 0xFF000000 | @as(u32, @truncate(std.hash.Wyhash.hash(i / 7, "pick")));
    var p: Picker = .{ .gpa = gpa, .win = undefined, .frozen = .{ .pixels = &img, .width = w, .height = h }, .th = theme.of(.{}), .hint = "Drag over it", .keep = 180 };
    defer p.deinit();
    p.n = 1;
    p.setArea();
    p.mouse = .{ .x = 30, .y = 30 };
    const pane = &p.panes[0];
    try pane.alloc(gpa, w, h, .ofSize(w, h), view_mod.monitorView(.ofSize(w, h), w, h));
    try pane.fill(gpa, p.frozen, p.keep);
    // a bar: a block and, below it, a tooltip-like strip
    const Mode = struct {
        pub fn barSize(_: *@This()) [2]i32 {
            return .{ 60, 20 };
        }
        pub fn paintBar(_: *@This(), _: std.mem.Allocator, cv: *Canvas, at: Point, _: f64, _: theme.Theme) void {
            cv.fillRect(at.x, at.y, 60, 20, 0xFF2266AA);
            cv.fillRect(at.x, at.y + 28, 90, 12, 0xFF101010);
        }
    };
    var mode: Mode = .{};
    var bufs: [2][w * h]u32 = .{ @splat(0xFFDEADBE), @splat(0xFFDEADBE) };
    var ref: [w * h]u32 = undefined;
    // away: the pointer on another surface (nothing on this one at all)
    const steps = [_]struct { sel: ?Rect, drag: areasel.Drag = .none, bar: ?Point = null, away: bool = false }{
        .{ .sel = null },
        .{ .sel = .{ .x = 20, .y = 20, .w = 100, .h = 80 }, .drag = .{ .drawing = .{ .anchor = .{ .x = 20, .y = 20 }, .limit = .ofSize(w, h) } } },
        .{ .sel = .{ .x = 20, .y = 20, .w = 150, .h = 120 }, .bar = .{ .x = 40, .y = 150 } },
        .{ .sel = .{ .x = 100, .y = 50, .w = 60, .h = 40 }, .bar = .{ .x = 80, .y = 100 } },
        .{ .sel = .{ .x = 100, .y = 50, .w = 60, .h = 40 }, .bar = .{ .x = 80, .y = 100 } },
        .{ .sel = null },
        .{ .sel = null },
        .{ .sel = .{ .x = 290, .y = 5, .w = 30, .h = 30 } },
        .{ .sel = null, .away = true },
        .{ .sel = null, .away = true },
        .{ .sel = null, .away = true },
        .{ .sel = null },
    };
    for (steps, 0..) |st, k| {
        p.sel.sel = st.sel;
        p.sel.drag = st.drag;
        p.bar = if (st.bar) |b| .{ .surface = 0, .at = b } else null;
        p.surface = if (st.away) 1 else 0;
        const bi: u1 = @intCast(k % 2);
        const told = p.paintInto(&mode, 0, &bufs[bi], bi, 256);
        // the work stays with what changed: a small area, or nothing
        if (k == 7) try testing.expect(told.?.area() * 2 < w * h);
        if (k == 10) try testing.expectEqual(@as(?Rect, null), told);
        p.compose(pane, &ref, pane.bounds());
        var cv = Canvas.init(&ref, w, h);
        p.paintChrome(&mode, &cv, 0);
        try testing.expectEqualSlices(u32, &ref, &bufs[bi]);
    }
}
