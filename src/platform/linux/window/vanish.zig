//! A fullscreen window's last frame: fully transparent, shown before the
//! surface goes. Compositors animate a window that closes (GNOME shrinks
//! and fades it), and they animate what it showed last; for the editor
//! and the pickers that is a frozen picture of the desktop, which would
//! shrink over the live desktop (a second desktop for a few frames).
//! Once the last frame is a clear one the effect has nothing to show,
//! with or without the GNOME extension that turns it off. Compositors
//! that animate nothing (registry.Effects.none) get no such frame.

const std = @import("std");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");
const events = @import("events.zig");

const Window = window.Window;
const Surface = surface.Surface;

/// How long to wait for the compositor to show the clear frame (and,
/// before it, the frame still on its way) at most.
const present_timeout_ms = 120;

/// The clear buffers, alive until the surfaces are gone.
pub const Clear = struct {
    pool: [window.max_surfaces]wl.shm.Pool = @splat(.{}),
    buffer: [window.max_surfaces]u32 = @splat(0),

    /// Drop the buffers and pools (after the surfaces they were on).
    pub fn release(self: *Clear, c: *wl.Connection) void {
        for (&self.pool, &self.buffer) |*p, *b| {
            if (b.* != 0) c.request(b.*, wl.wl_buffer.destroy, &.{}) catch {};
            b.* = 0;
            p.deinit(c);
        }
    }
};

/// Show a clear frame on every fullscreen surface and wait (briefly) until
/// the compositor has; best effort, and only where closing windows are
/// animated (elsewhere a clear fullscreen frame can show black: sway).
/// Events that arrive meanwhile are dropped: the window is going.
pub fn vanish(w: *Window, clear: *Clear) void {
    const queued = w.queue.items.len;
    defer w.queue.shrinkRetainingCapacity(@min(queued, w.queue.items.len));
    if (w.globals.effects == .none or !anyFullscreen(w)) return;
    const deadline = sys.monoMs() + present_timeout_ms;
    // a frame still on its way would land after the clear one
    waitFrames(w, deadline);
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        if (wants(s)) commitClear(w, s, clear, i) catch |err| std.log.debug("clear frame: {t}", .{err});
    }
    if (w.globals.effects == .mutter) minimize(w);
    w.conn.flush() catch return;
    // destroyed before the compositor shows it, the effect would run on
    // the frame before
    waitFrames(w, deadline);
}

/// mutter hides its top bar under a fullscreen window, so a clear one
/// would leave the bar's place empty until it goes; minimized, it no
/// longer counts, and the bar is back in the same frame the clear one
/// shows. (Its minimize effect then animates nothing visible.)
fn minimize(w: *Window) void {
    for (w.surfaces[0..w.n_surfaces]) |*s| {
        if (wants(s) and s.toplevel != 0) w.conn.request(s.toplevel, wl.xdg_toplevel.set_minimized, &.{}) catch {};
    }
}

fn wants(s: *const Surface) bool {
    return s.alive and s.fullscreen and s.pool.id != 0 and s.width > 0 and s.height > 0;
}

fn anyFullscreen(w: *const Window) bool {
    for (w.surfaces[0..w.n_surfaces]) |*s| if (wants(s)) return true;
    return false;
}

/// Attach a buffer of the surface's size that is transparent all over
/// (a fresh pool reads as zeros: no pixels to write), with a frame
/// callback to know when it is on screen.
fn commitClear(w: *Window, s: *Surface, clear: *Clear, i: usize) !void {
    const c = &w.conn;
    clear.pool[i] = try .create(c, w.globals.shm, @as(usize, s.width) * s.height * 4);
    clear.buffer[i] = try clear.pool[i].buffer(c, 0, s.width, s.height, s.width * 4, wl.wl_shm.format_argb8888);
    try c.request(s.wl_surface, wl.wl_surface.set_opaque_region, &.{.{ .object = 0 }});
    try c.request(s.wl_surface, wl.wl_surface.attach, &.{ .{ .object = clear.buffer[i] }, .{ .int = 0 }, .{ .int = 0 } });
    try c.request(s.wl_surface, wl.wl_surface.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = @intCast(s.width) }, .{ .int = @intCast(s.height) } });
    if (!s.frame_pending) {
        s.frame_cb = c.newId();
        try c.request(s.wl_surface, wl.wl_surface.frame, &.{.{ .new_id = s.frame_cb }});
        s.frame_pending = true;
    }
    try c.request(s.wl_surface, wl.wl_surface.commit, &.{});
}

/// Until no fullscreen surface waits for a frame callback, or `deadline`.
/// Reads the socket itself: the events already queued stay first.
fn waitFrames(w: *Window, deadline: i64) void {
    while (sys.monoMs() < deadline) {
        w.conn.flush() catch return;
        events.drainPending(w) catch return;
        const pending = for (w.surfaces[0..w.n_surfaces]) |*s| {
            if (wants(s) and s.frame_pending) break true;
        } else false;
        if (!pending) return;
        var fds = [_]sys.pollfd{.{ .fd = w.conn.fd, .events = sys.POLL.IN, .revents = 0 }};
        const n = sys.poll(&fds, @intCast(@max(1, deadline - sys.monoMs()))) catch return;
        if (n > 0) events.dispatchOne(w) catch return;
    }
}
