//! The scrolling capture's region picker, over a frozen capture on one
//! fullscreen surface per monitor: drag out a region, then Start (or
//! Enter) confirms it. Esc, a right click or closing the surfaces
//! cancels. Everything is in the capture's image pixels. Light or dark
//! with the desktop, in its accent (ui/theme.zig).

const std = @import("std");
const capture = @import("../app/capture.zig");
const render = @import("../gfx/render.zig");
const view_mod = @import("view.zig");
const window = @import("../platform/api.zig").window;
const dim = @import("dim.zig");
const selchrome = @import("selchrome.zig");
const barkit = @import("barkit.zig");
const press = @import("press.zig");
const scale = @import("scale.zig");
const theme = @import("theme.zig");
const Rect = @import("shapes.zig").Rect;
const View = view_mod.View;

pub const Result = union(enum) {
    cancelled,
    region: Rect,
};

/// the Start button, logical px
const start_h = 34;
const start_gap = 10;
/// a smaller drag is no region (image px)
const min_side = 8;

const Pane = struct {
    view: View = .{},
    bright: []u32 = &.{},
    dimmed: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,

    fn deinit(self: *Pane, gpa: std.mem.Allocator) void {
        gpa.free(self.bright);
        gpa.free(self.dimmed);
        self.* = .{};
    }

    fn bounds(self: *const Pane) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.w), .h = @intCast(self.h) };
    }
};

/// The Start button: buffer pixels of the surface it is on.
const Start = struct { surface: u8, r: Rect };

pub const Picker = struct {
    gpa: std.mem.Allocator,
    win: *window.Window,
    cap: *const capture.Capture,
    th: theme.Theme,
    label: []const u8,
    /// of 256, what the dim outside the selection keeps (ui/dim.zig)
    keep: u32 = 256,
    panes: [window.max_surfaces]Pane = @splat(.{}),
    sel: ?Rect = null,
    anchor: ?[2]i32 = null,
    start_btn: ?Start = null,
    /// Start activates on a press and release over it (ui/press.zig)
    pressed: press.Press(Start) = .{},
    dirty: bool = true,

    pub fn deinit(self: *Picker) void {
        for (&self.panes) |*p| p.deinit(self.gpa);
    }

    /// The view of surface i: its monitor's part of the image.
    fn viewFor(self: *const Picker, i: usize, w: u32, h: u32) View {
        const sf = self.win.surfaceList()[i];
        for (self.cap.monitors) |m| {
            const l = m.logical orelse continue;
            if (l.x == sf.x and l.y == sf.y and l.w == sf.out_w and l.h == sf.out_h)
                return view_mod.monitorView(.{ .x = @intCast(m.x), .y = @intCast(m.y), .w = @intCast(m.w), .h = @intCast(m.h) }, w, h);
        }
        return View.fit(self.cap.image.width, self.cap.image.height, .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) }, 8);
    }

    fn prepare(self: *Picker, i: usize, w: u32, h: u32) !void {
        const p = &self.panes[i];
        p.deinit(self.gpa);
        if (w == 0 or h == 0) return;
        p.w = w;
        p.h = h;
        p.view = self.viewFor(i, w, h);
        p.bright = try self.gpa.alloc(u32, @as(usize, w) * h);
        p.dimmed = try self.gpa.alloc(u32, p.bright.len);
        const img = &self.cap.image;
        view_mod.resample(img.pixels, img.width, img.height, p.view, p.bright, w, h, p.bounds());
        dim.dimRow(p.bright, p.dimmed, self.keep);
    }

    fn paint(self: *Picker, i: usize) !void {
        const p = &self.panes[i];
        if (p.w == 0) return;
        const px = try self.win.backBufferOf(@intCast(i));
        @memcpy(px, p.dimmed);
        var cv = render.Canvas.init(px, p.w, p.h);
        const k = scale.of(self.win.surfaceList()[i].scale120);
        if (self.sel) |s| {
            const b = p.view.rectToBuf(s);
            // the selection shows the screen as it is
            if (Rect.intersect(b, p.bounds())) |c| for (@intCast(c.y)..@intCast(c.bottom())) |y| {
                const row = y * @as(usize, p.w) + @as(usize, @intCast(c.x));
                @memcpy(cv.px[row..][0..@intCast(c.w)], p.bright[row..][0..@intCast(c.w)]);
            };
            selchrome.edge(&cv, b, self.th);
            if (self.anchor == null) self.drawStart(i, &cv, k, b);
        } else {
            const msg = "Drag over what to scroll \u{00b7} Esc to cancel";
            const sz = selchrome.hintPillSize(msg, k);
            _ = selchrome.hintPill(&cv, .{ .x = @divTrunc(cv.w - sz[0], 2), .y = scale.px(28, k) }, msg, k, self.th);
        }
        try self.win.presentSurface(@intCast(i));
    }

    /// Start, centred under the selection (over its bottom edge when
    /// there is no room below); lit while held.
    fn drawStart(self: *Picker, i: usize, cv: *render.Canvas, k: f64, b: Rect) void {
        const w = barkit.textButtonWidth(k, self.label);
        const h = scale.px(start_h, k);
        const gap = scale.px(start_gap, k);
        var y = b.bottom() + gap;
        if (y + h > cv.h) y = b.bottom() - h - gap;
        const x = std.math.clamp(b.x + @divTrunc(b.w - w, 2), 0, @max(0, cv.w - w));
        const r: Rect = .{ .x = x, .y = y, .w = w, .h = h };
        const held: f64 = if (self.pressed.held() != null) 1 else 0;
        barkit.textButton(cv, r, k, self.th, .primary, held, self.label);
        self.start_btn = .{ .surface = @intCast(i), .r = r };
    }

    fn imgAt(self: *const Picker, surface: u8, x: f64, y: f64) [2]i32 {
        const v = self.panes[surface].view;
        const pt = v.toImgEdge(.{ .x = @intFromFloat(x), .y = @intFromFloat(y) });
        const iw: i32 = @intCast(self.cap.image.width);
        const ih: i32 = @intCast(self.cap.image.height);
        return .{ std.math.clamp(pt.x, 0, iw), std.math.clamp(pt.y, 0, ih) };
    }

    fn onMotion(self: *Picker, surface: u8, x: f64, y: f64) void {
        const a = self.anchor orelse return;
        const pt = self.imgAt(surface, x, y);
        self.sel = .{ .x = @min(a[0], pt[0]), .y = @min(a[1], pt[1]), .w = @intCast(@abs(pt[0] - a[0])), .h = @intCast(@abs(pt[1] - a[1])) };
        self.dirty = true;
    }

    /// The Start button under a pointer on `surface`, if it shows.
    fn startAt(self: *const Picker, surface: u8, x: f64, y: f64) ?Start {
        if (self.sel == null) return null;
        const b = self.start_btn orelse return null;
        if (b.surface != surface or !b.r.contains(@intFromFloat(x), @intFromFloat(y))) return null;
        return b;
    }

    /// A press or release: the result once the picker is done. Start is
    /// a press and a release over it; a press anywhere else drags anew.
    fn onButton(self: *Picker, b: anytype) ?Result {
        if (b.button == .right) return if (b.pressed) .cancelled else null;
        if (b.button != .left) return null;
        self.dirty = true;
        const on_start = self.startAt(b.surface, b.x, b.y);
        if (b.pressed) {
            if (on_start != null) {
                self.pressed.down(on_start, b.x, b.y);
                return null;
            }
            self.anchor = self.imgAt(b.surface, b.x, b.y);
            self.sel = null;
            self.start_btn = null;
        } else if (self.pressed.held() != null) {
            if (self.pressed.up(on_start) != null) return .{ .region = self.sel.? };
        } else if (self.anchor != null) {
            self.onMotion(b.surface, b.x, b.y);
            self.anchor = null;
            if (self.sel) |s| if (s.w < min_side or s.h < min_side) {
                self.sel = null;
            };
        }
        return null;
    }

    fn onKey(self: *const Picker, k: window.Key) ?Result {
        if (!k.pressed) return null;
        if (k.code == .escape) return .cancelled;
        if (k.code == .enter or k.code == .kp_enter) if (self.sel) |s| return .{ .region = s };
        return null;
    }

    fn handle(self: *Picker, ev: window.InputEvent) !?Result {
        switch (ev) {
            .close => return .cancelled,
            .resize => |r| {
                try self.prepare(r.surface, r.w, r.h);
                self.dirty = true;
            },
            .frame_done => {},
            .pointer_motion => |m| if (m.x >= 0) self.onMotion(m.surface, m.x, m.y),
            .pointer_button => |b| return self.onButton(b),
            .key => |k| return self.onKey(k),
            .pointer_axis => {},
        }
        return null;
    }

    fn paintAll(self: *Picker) !void {
        if (!self.dirty) return;
        const surfs = self.win.surfaceList();
        for (surfs) |s| if (s.alive and s.frame_pending) return;
        self.dirty = false;
        for (surfs, 0..) |s, i| if (s.alive) try self.paint(i);
    }

    /// Open the surfaces and run until a region is picked or cancelled;
    /// the surfaces are closed again before returning.
    pub fn run(self: *Picker, title: []const u8) !Result {
        try self.win.openOutputs(title);
        defer self.win.closeWindow();
        self.win.setCursor(.crosshair) catch {};
        for (self.win.surfaceList(), 0..) |s, i| if (s.alive) try self.prepare(i, s.width, s.height);
        while (true) {
            try self.paintAll();
            const ev = (try self.win.nextEventTimeout(500)) orelse continue;
            if (try self.handle(ev)) |r| return r;
        }
    }
};

/// Pick a region of `cap`; `label` names the Start button.
pub fn pick(gpa: std.mem.Allocator, win: *window.Window, cap: *const capture.Capture, label: []const u8, th: theme.Theme) !Result {
    var p: Picker = .{ .gpa = gpa, .win = win, .cap = cap, .th = th, .label = label, .keep = dim.keepFor(cap.image.pixels, cap.image.width, cap.image.height) };
    defer p.deinit();
    return p.run("Shotlet");
}

test "Start is a press and a release over it; releasing elsewhere cancels" {
    const B = struct { button: window.Button, pressed: bool, x: f64, y: f64, surface: u8 = 0 };
    const sel: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 80 };
    var p: Picker = .{ .gpa = std.testing.allocator, .win = undefined, .cap = undefined, .th = theme.of(.{}), .label = "Start" };
    p.sel = sel;
    p.start_btn = .{ .surface = 0, .r = .{ .x = 40, .y = 100, .w = 60, .h = 30 } };
    try std.testing.expectEqual(@as(?Result, null), p.onButton(B{ .button = .left, .pressed = true, .x = 50, .y = 110 }));
    try std.testing.expectEqual(@as(?Result, null), p.onButton(B{ .button = .left, .pressed = false, .x = 5, .y = 5 }));
    try std.testing.expectEqual(sel, p.sel.?);
    _ = p.onButton(B{ .button = .left, .pressed = true, .x = 50, .y = 110 });
    try std.testing.expectEqual(@as(?Result, .{ .region = sel }), p.onButton(B{ .button = .left, .pressed = false, .x = 60, .y = 120 }));
    try std.testing.expectEqual(@as(?Result, .cancelled), p.onButton(B{ .button = .right, .pressed = true, .x = 0, .y = 0 }));
}
