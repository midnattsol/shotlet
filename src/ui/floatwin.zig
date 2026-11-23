//! Opening and presenting the floating windows (thumbnails, toasts, the
//! recorder's control, pins, the countdown), one way: a layer surface
//! where the platform has them, else an ordinary see-through window with
//! the same size (and a "shotlet:..." title the GNOME extension places);
//! leave events on and the arrow cursor. Drawing goes into the back
//! buffer in straight alpha (ui/floatui.zig), converted on present.
//!
//! Stable API:
//!   Placement                     title, namespace, size, anchor, margin,
//!                                 layer, keyboard
//!   open(win, placement) !bool    open it; true when it is a layer surface
//!   canDraw(win) bool             a frame may be drawn now (configured, no
//!                                 frame pending); callers also check their
//!                                 own `dirty`
//!   presentStraight(win, px) !void   premultiply the straight-alpha back
//!                                 buffer `px` and present it

const std = @import("std");
const window = @import("../platform/api.zig").window;
const floatui = @import("floatui.zig");

const Layer = window.Layer;

/// Where and how a floating window opens.
pub const Placement = struct {
    /// the window title where there is no layer shell (on GNOME the
    /// extension reads where to put it from it)
    title: []const u8 = "shotlet:quick",
    /// what the compositor may call the layer surface (rules, animations)
    namespace: []const u8 = "shotlet",
    /// logical size
    size: [2]u32,
    /// the screen edges it sticks to, and how far from them (top, right,
    /// bottom, left; logical px)
    anchor: Layer.Anchor = .{},
    margin: [4]i32 = .{ 0, 0, 0, 0 },
    layer: Layer.Level = .overlay,
    keyboard: Layer.Keyboard = .none,
};

/// Open `win` as a floating window; true when it became a layer surface
/// (anchor, margin, layer and keyboard apply only then).
pub fn open(win: *window.Window, p: Placement) !bool {
    const layer = win.hasLayerShell();
    var opts: window.OpenOptions = .{ .fullscreen = false, .transparent = true, .width = p.size[0], .height = p.size[1] };
    if (layer) opts.layer = .{
        .layer = p.layer,
        .anchor = p.anchor,
        .width = p.size[0],
        .height = p.size[1],
        .margin = p.margin,
        .keyboard = p.keyboard,
        .namespace = p.namespace,
    };
    try win.open(p.title, opts);
    win.report_leave = true;
    win.setCursor(.arrow) catch {};
    return layer;
}

/// Whether a frame can be drawn now: the surface has a size and the
/// last frame was shown.
pub fn canDraw(win: *const window.Window) bool {
    return win.width > 0 and !win.frame_pending;
}

/// Convert the back buffer `px` (drawn in straight alpha) to the
/// premultiplied alpha the surface wants, and present it.
pub fn presentStraight(win: *window.Window, px: []u32) !void {
    floatui.premultiply(px, win.width, win.height, .ofSize(win.width, win.height));
    try win.present();
}

test "a placement defaults to a keyboard-less overlay" {
    const p: Placement = .{ .size = .{ 10, 20 } };
    try std.testing.expectEqual(Layer.Level.overlay, p.layer);
    try std.testing.expectEqual(Layer.Keyboard.none, p.keyboard);
    try std.testing.expectEqualStrings("shotlet:quick", p.title);
}
