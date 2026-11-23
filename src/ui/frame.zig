//! The drawn frame of the ordinary windows (Settings, Trim): the content
//! goes into an opaque buffer and is placed with rounded corners, a
//! hairline edge and a soft shadow on a see-through surface, as the
//! history panel and the pins are. GNOME draws no decorations for us, so
//! this is the window's whole frame. The window geometry and the input
//! region are the content alone: the compositor snaps, tiles and
//! hit-tests the window proper, never its shadow. Maximized, fullscreen
//! or tiled, the compositor owns the edges: the content fills the surface
//! exactly, square and without a shadow, until the window floats again.
//!
//! Stable API:
//!   pad                       shadow room around the content (logical px)
//!   outer(w, h)               the surface size for w x h of content
//!   Frame.begin(gpa, win)     the content's canvas for the next frame
//!   Frame.present(win, edge)  frame the content and present it
//!   Frame.toContent(win, x)   a surface coordinate (buffer px) in content px
//!   bare(win)                 drawn edge to edge (maximized, tiled...)
//!   Frame.deinit(gpa)
//! Open the window with .transparent = true at outer(w, h).

const std = @import("std");
const window = @import("../platform/api.zig").window;
const render = @import("../gfx/render.zig");
const floatui = @import("floatui.zig");
const shapes = @import("shapes.zig");
const floatwin = @import("floatwin.zig");
const material = @import("material.zig");
const scale = @import("scale.zig");
const theme = @import("theme.zig");

const Window = window.Window;
const Canvas = render.Canvas;

/// room for the window's shadow (theme.window_shadow) all round
pub const pad = theme.window_room;
/// as the history panel: a little rounder than the cards inside
const radius = theme.popover_radius;

pub fn outer(w: u32, h: u32) [2]u32 {
    return .{ w + 2 * pad, h + 2 * pad };
}

/// The compositor fixes the window's size and edges (maximized,
/// fullscreen, tiled): no rounded corners, no shadow, no room for it.
pub fn bare(win: *const Window) bool {
    return win.maximized or win.tiled;
}

/// What the window geometry was last set for.
const Geom = struct { w: u32 = 0, h: u32 = 0, bare: bool = false };

pub const Frame = struct {
    content: []u32 = &.{},
    cw: u32 = 0,
    ch: u32 = 0,
    /// the shadow alone, for the current surface size
    shade: []u32 = &.{},
    shade_w: u32 = 0,
    shade_h: u32 = 0,
    geom: Geom = .{},

    pub fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(self.content);
        gpa.free(self.shade);
        self.* = .{};
    }

    fn padPx(win: *const Window) u32 {
        if (bare(win)) return 0;
        return @intCast(scale.px(pad, scale.of(win.scale120)));
    }

    /// A surface coordinate (buffer pixels) in content pixels.
    pub fn toContent(win: *const Window, v: f64) f64 {
        return v - @as(f64, @floatFromInt(padPx(win)));
    }

    /// The content's canvas for this frame (its size follows the window).
    pub fn begin(self: *Frame, gpa: std.mem.Allocator, win: *Window) !Canvas {
        try self.syncGeometry(win);
        const p = 2 * padPx(win);
        const cw = win.width -| p;
        const ch = win.height -| p;
        if (cw != self.cw or ch != self.ch) {
            gpa.free(self.content);
            self.content = &.{};
            self.content = try gpa.alloc(u32, @as(usize, cw) * ch);
            self.cw = cw;
            self.ch = ch;
        }
        try self.ensureShade(gpa, win);
        return Canvas.init(self.content, cw, ch);
    }

    /// Only the content is the window: for snapping, tiling and input.
    fn syncGeometry(self: *Frame, win: *Window) !void {
        const s = win.surfaceList()[0];
        const g: Geom = .{ .w = s.logical_w, .h = s.logical_h, .bare = bare(win) };
        if (std.meta.eql(g, self.geom)) return;
        self.geom = g;
        const p: u32 = if (g.bare) 0 else pad;
        const r: window.Rect = .{ .x = @intCast(p), .y = @intCast(p), .w = @intCast(g.w -| 2 * p), .h = @intCast(g.h -| 2 * p) };
        try win.setWindowGeometry(0, r);
        try win.setInputRegion(0, &.{r});
    }

    fn ensureShade(self: *Frame, gpa: std.mem.Allocator, win: *const Window) !void {
        if (bare(win)) return;
        if (self.shade_w == win.width and self.shade_h == win.height) return;
        gpa.free(self.shade);
        self.shade = &.{};
        self.shade = try gpa.alloc(u32, @as(usize, win.width) * win.height);
        self.shade_w = win.width;
        self.shade_h = win.height;
        @memset(self.shade, 0);
        const p: i32 = @intCast(padPx(win));
        const r: shapes.Rect = .{ .x = p, .y = p, .w = @intCast(self.cw), .h = @intCast(self.ch) };
        var cache: material.ShadowCache = .{};
        defer cache.release(gpa);
        const k = scale.of(win.scale120);
        material.shadowStraight(gpa, self.shade, win.width, win.height, r, radius * k, theme.window_shadow, k, 1, &cache);
    }

    /// Edge the content with `edge`, round it onto the shadow and present.
    pub fn present(self: *Frame, win: *Window, edge: u32) !void {
        if (bare(win)) return self.presentBare(win);
        const k = scale.of(win.scale120);
        var cv = Canvas.init(self.content, self.cw, self.ch);
        const rad = radius * k;
        material.hairline(&cv, .{ .x = 0, .y = 0, .w = cv.w, .h = cv.h }, rad, edge);
        const px = try win.backBuffer();
        @memcpy(px, self.shade[0..px.len]);
        const p: i32 = @intCast(padPx(win));
        const content: floatui.Image = .{ .px = self.content, .w = self.cw, .h = self.ch };
        floatui.place(.{ .px = px, .w = win.width, .h = win.height }, content, .{ p, p }, rad, null, k);
        try floatwin.presentStraight(win, px);
    }

    /// Edge to edge: the opaque content is the whole surface.
    fn presentBare(self: *Frame, win: *Window) !void {
        const px = try win.backBuffer();
        @memcpy(px, self.content[0..px.len]);
        try win.present();
    }
};

test "the surface is the content plus room for the shadow" {
    const o = outer(720, 372);
    try std.testing.expectEqual(@as(u32, 720 + 2 * pad), o[0]);
    try std.testing.expectEqual(@as(u32, 372 + 2 * pad), o[1]);
}
