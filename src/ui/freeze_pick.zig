//! The frozen desktop a picker chooses an area on: the recording picker
//! (ui/recui/picker.zig) and the scrolling capture's (ui/region_pick.zig).
//! One fullscreen surface per monitor shows its part of the capture
//! (resample.box), dimmed outside the area (ui/dim.zig) and easing in on
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
//! Surfaces are matched to the capture's monitors by their logical
//! rectangles (an exact match shows that monitor); with no match (the
//! layout unknown: --from, the Screenshot portal) each shows the whole
//! capture fitted (View.fit).

const std = @import("std");
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

/// The capture the picker shows.
pub const Frozen = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    /// where each monitor is in the image and in the layout (empty: one
    /// monitor, the whole image)
    monitors: []const geom.Monitor = &.{},

    fn bounds(self: Frozen) Rect {
        return .ofSize(self.width, self.height);
    }
};

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

/// One surface: its part of the capture at its own size.
pub const Pane = struct {
    view: View = .{},
    base: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    /// buffer pixels per logical pixel
    k: f64 = 1,
    /// the surface's logical rectangle (its output's)
    logical: Rect = .empty,

    fn bounds(self: *const Pane) Rect {
        return .ofSize(self.w, self.h);
    }
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
    life: motion.Life = .{ .in_ms = theme.motion_fast, .out_ms = theme.motion_fast },

    pub fn init(gpa: std.mem.Allocator, win: *window.Window, frozen: Frozen, th: theme.Theme, hint: []const u8) Picker {
        return .{ .gpa = gpa, .win = win, .frozen = frozen, .th = th, .hint = hint, .keep = dim.keepFor(frozen.pixels, frozen.width, frozen.height) };
    }

    pub fn deinit(self: *Picker) void {
        for (&self.panes) |*p| {
            self.gpa.free(p.base);
            p.* = .{};
        }
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
        const p = &self.panes[i];
        self.gpa.free(p.base);
        p.base = &.{};
        p.w = 0;
        if (w == 0 or h == 0) return;
        const s = self.win.surfaceList()[i];
        p.logical = if (s.out_w > 0) .{ .x = s.x, .y = s.y, .w = @intCast(s.out_w), .h = @intCast(s.out_h) } else .{ .x = 0, .y = 0, .w = @intCast(@max(1, s.logical_w)), .h = @intCast(@max(1, s.logical_h)) };
        p.k = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(@max(1, p.logical.w)));
        p.view = self.viewFor(p.logical, w, h);
        p.base = try self.gpa.alloc(u32, @as(usize, w) * h);
        p.w = w;
        p.h = h;
        try self.fill(p);
        self.dirty = true;
    }

    /// The capture under pane `p`, area-averaged onto its buffer
    /// (letterboxed where the view leaves room).
    fn fill(self: *Picker, p: *Pane) !void {
        const f = &self.frozen;
        const tl = p.view.toImgEdge(.{ .x = 0, .y = 0 });
        const br = p.view.toImgEdge(.{ .x = @intCast(p.w), .y = @intCast(p.h) });
        const src = Rect.fromEdges(tl.x, tl.y, br.x, br.y).intersect(f.bounds()) orelse return @memset(p.base, view_mod.letterbox);
        const dst = p.view.rectToBuf(src).intersect(p.bounds()) orelse return @memset(p.base, view_mod.letterbox);
        const sx: usize = @intCast(src.x);
        const off = @as(usize, @intCast(src.y)) * f.width + sx;
        if (dst.eql(p.bounds())) return resample.box(f.pixels[off..], f.width, @intCast(src.w), @intCast(src.h), p.base, p.w, p.h);
        @memset(p.base, view_mod.letterbox);
        const tmp = try self.gpa.alloc(u32, @intCast(dst.area()));
        defer self.gpa.free(tmp);
        resample.box(f.pixels[off..], f.width, @intCast(src.w), @intCast(src.h), tmp, @intCast(dst.w), @intCast(dst.h));
        const dw: usize = @intCast(dst.w);
        for (0..@intCast(dst.h)) |row| {
            const at = (@as(usize, @intCast(dst.y)) + row) * p.w + @as(usize, @intCast(dst.x));
            @memcpy(p.base[at..][0..dw], tmp[row * dw ..][0..dw]);
        }
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
    }

    fn paint(self: *Picker, mode: anytype, i: usize, fade: u32) !void {
        const p = &self.panes[i];
        const px = (try self.win.backBufferOf(@intCast(i)))[0..p.base.len];
        @memcpy(px, p.base);
        var cv = Canvas.init(px, p.w, p.h);
        const s = self.sel.rect();
        const b: ?Rect = if (s) |r| p.view.rectToBuf(r) else null;
        dim.outside(px, p.w, p.h, b, self.keep);
        if (b) |r| self.drawArea(&cv, i, r);
        if (s == null and i == self.surface) {
            const sz = selchrome.hintPillSize(self.hint, p.k);
            _ = selchrome.hintPill(&cv, .{ .x = @divTrunc(cv.w - sz[0], 2), .y = @divTrunc(cv.h - sz[1], 2) }, self.hint, p.k, self.th);
        }
        if (self.bar) |bar| if (bar.surface == i) mode.paintBar(self.gpa, &cv, bar.at, p.k, self.th);
        if (fade < 256) mixRows(px, p.base, px, fade);
        try self.win.presentSurface(@intCast(i));
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
        for (self.win.surfaceList()[0..self.n], 0..) |s, i| if (s.alive) try self.prepare(i, s.width, s.height);
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

test "a surface's part of the capture, area-averaged, letterboxed when unmatched" {
    var px: [16]u32 = undefined;
    for (&px, 0..) |*c, i| c.* = 0xFF000000 | @as(u32, @intCast(i * 10));
    var p: Picker = .{ .gpa = testing.allocator, .win = undefined, .frozen = .{ .pixels = &px, .width = 4, .height = 4 }, .th = theme.of(.{}), .hint = "" };
    defer p.deinit();
    // the whole capture on a buffer twice as wide: fitted, bars left and right
    var pane: Pane = .{ .w = 8, .h = 4, .view = View.fit(4, 4, .ofSize(8, 4), 8) };
    pane.base = try testing.allocator.alloc(u32, 32);
    defer testing.allocator.free(pane.base);
    try p.fill(&pane);
    try testing.expectEqual(view_mod.letterbox, pane.base[0]);
    try testing.expectEqual(px[0], pane.base[2]);
    try testing.expectEqual(px[3], pane.base[5]);
    // a monitor's part at half size: each pixel the mean of four
    const mon: geom.Monitor = .{ .x = 2, .y = 0, .w = 2, .h = 2, .logical = .{ .x = 0, .y = 0, .w = 1, .h = 1 } };
    var half: Pane = .{ .w = 1, .h = 1, .view = view_mod.monitorView(mon.pixelRect(), 1, 1) };
    half.base = try testing.allocator.alloc(u32, 1);
    defer testing.allocator.free(half.base);
    try p.fill(&half);
    try testing.expectEqual(@as(u32, 0xFF000000 | (20 + 30 + 60 + 70 + 2) / 4), half.base[0]);
}

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
