//! The editor's own dim transition, in place of the compositor's window
//! effects: it opens on the frozen frame exactly as the desktop looked
//! and dims in; it closes by easing everything it drew (dim, chrome,
//! annotations) back to that plain frame, then the window shows a clear
//! last frame (window/vanish.zig), so taking it away changes nothing on
//! screen, whatever effect the compositor runs. Reduced motion makes both
//! instant.
//!
//! The open has no such cure on GNOME without the extension (which skips
//! mutter's map effect): mutter zooms the first frame in. A clear first
//! frame shows black there (mutter backs a fullscreen window that is not
//! opaque with black), and a window mapped clear before it goes
//! fullscreen hides the top bar while nothing covers its place, or gets
//! the resize effect instead.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const editor = @import("../editor.zig");
const motion = @import("../motion.zig");
const theme = @import("../theme.zig");
const view_mod = @import("../view.zig");
const shapes_mod = @import("../shapes.zig");
const mix = @import("../../gfx/effects.zig").mixRows;
const bands = @import("../bands.zig");

const Editor = editor.Editor;
const Rect = shapes_mod.Rect;

/// Both directions take this long.
pub const duration_ms = theme.motion_fast;

/// The fade-in's progress: when the first frame went out (0: not yet).
pub const Enter = struct {
    start_ms: i64 = 0,
    done: bool = false,
};

/// Still fading in (the loop keeps drawing frames).
pub fn entering(ed: *const Editor) bool {
    return !ed.enter.done and motion.enabled;
}

/// How far the fade-in is, 0..256, for the frame being drawn now; null
/// once it is over. Ending it marks every back buffer for a full
/// repaint, since the blended frames left traces in them.
pub fn enterLevel(ed: *Editor) ?u32 {
    if (ed.enter.done) return null;
    const now = sys.monoMs();
    if (ed.enter.start_ms == 0) ed.enter.start_ms = now;
    const k = level(ed.enter.start_ms, now);
    if (k < 256) return k;
    ed.enter.done = true;
    for (ed.panes[0..ed.n_panes]) |*p| {
        if (!p.alive) continue;
        const all: Rect = .ofSize(p.width, p.height);
        for (&p.pending) |*q| q.add(all);
    }
    return null;
}

/// The frame just drawn into `px`, seen through the fade-in: the
/// undimmed view, turning into the frame as `k` goes to 256.
pub fn blendIn(ed: *Editor, px: []u32, k: u32) void {
    const p = ed.pn();
    if (p.viewc.len != px.len) return;
    mixBands(px, p.viewc, px, k, p.width);
}

/// `dst` = `a` turning into `b` as `k` goes to 256, rows `w` wide: a
/// whole 4K frame per refresh while a fade lasts, so in bands.
fn mixBands(dst: []u32, a: []const u32, b: []const u32, k: u32, w: u32) void {
    const Ctx = struct {
        dst: []u32,
        a: []const u32,
        b: []const u32,
        w: usize,
        k: u32,
        fn band(c: @This(), r: Rect) void {
            const from = @as(usize, @intCast(r.y)) * c.w;
            const to = @as(usize, @intCast(r.bottom())) * c.w;
            mix(c.dst[from..to], c.a[from..to], c.b[from..to], c.k);
        }
    };
    const h: u32 = @intCast(dst.len / @max(1, w));
    bands.run(.ofSize(w, h), Ctx{ .dst = dst, .a = a, .b = b, .w = w, .k = k }, Ctx.band);
}

/// 0..256 along the eased curve, `start` ms ago; 256 without motion.
fn level(start: i64, now: i64) u32 {
    if (!motion.enabled) return 256;
    const t = @as(f64, @floatFromInt(now - start)) / @as(f64, @floatFromInt(duration_ms));
    return @intFromFloat(@round(motion.easeOut(t) * 256));
}

/// Per pane: the last frame shown and the plain capture as it shows.
const Frames = struct {
    from: [editor.max_panes][]u32 = @splat(&.{}),
    plain: [editor.max_panes][]u32 = @splat(&.{}),
    shown: [editor.max_panes]bool = @splat(true),

    fn init(ed: *Editor) !Frames {
        var f: Frames = .{};
        errdefer f.deinit(ed.alloc);
        for (ed.panes[0..ed.n_panes], 0..) |*p, i| {
            const n = @as(usize, p.width) * p.height;
            if (!p.alive or n == 0 or p.last_frame.len != n) continue;
            f.from[i] = try ed.alloc.dupe(u32, p.last_frame);
            f.plain[i] = try ed.alloc.alloc(u32, n);
            plainView(ed, p, f.plain[i]);
            f.shown[i] = false;
        }
        return f;
    }

    /// The capture without annotations as pane `p` shows it: its view
    /// when nothing is drawn, else resampled anew, in bands.
    fn plainView(ed: *const Editor, p: *const editor.Pane, dst: []u32) void {
        if (ed.doc.shapes.items.len == 0 and p.viewc.len == dst.len and !p.view_stale) return @memcpy(dst, p.viewc);
        const Ctx = struct {
            ed: *const Editor,
            p: *const editor.Pane,
            dst: []u32,
            fn band(c: @This(), b: Rect) void {
                view_mod.resample(c.ed.img.pixels, c.ed.img.width, c.ed.img.height, c.p.view, c.dst, c.p.width, c.p.height, b);
            }
        };
        bands.run(.ofSize(p.width, p.height), Ctx{ .ed = ed, .p = p, .dst = dst }, Ctx.band);
    }

    fn deinit(f: *Frames, gpa: std.mem.Allocator) void {
        for (&f.from, &f.plain) |a, b| {
            gpa.free(a);
            gpa.free(b);
        }
    }
};

/// Ease the editor back to the plain capture, then return with that
/// frame on screen; the window stays up (and lets clicks through) for
/// the caller to close.
pub fn out(ed: *Editor) !void {
    var frames = try Frames.init(ed);
    defer frames.deinit(ed.alloc);
    const surfs = ed.win.surfaceList();
    for (surfs, 0..) |s, i| if (s.alive) ed.win.setInputRegion(@intCast(i), &.{}) catch {};
    const start = sys.monoMs();
    while (!allShown(&frames, ed.n_panes)) {
        const k = level(start, sys.monoMs());
        try presentStep(ed, &frames, k);
        _ = try ed.win.nextEventTimeout(ed.win.pollTimeoutMs(8));
        ed.win.queue.clearRetainingCapacity();
    }
    try waitPresented(ed, 150);
}

/// A frame at `k` on every surface free to take one; the last one (k =
/// 256) marks the pane done.
fn presentStep(ed: *Editor, frames: *Frames, k: u32) !void {
    const surfs = ed.win.surfaceList();
    for (0..ed.n_panes) |i| {
        if (frames.shown[i] or i >= surfs.len or surfs[i].frame_pending) continue;
        const px = ed.win.backBufferOf(@intCast(i)) catch {
            frames.shown[i] = true;
            continue;
        };
        if (px.len != frames.from[i].len) {
            frames.shown[i] = true;
            continue;
        }
        mixBands(px, frames.from[i], frames.plain[i], k, ed.panes[i].width);
        try ed.win.presentSurface(@intCast(i));
        if (k >= 256) frames.shown[i] = true;
    }
}

fn allShown(frames: *const Frames, n: u8) bool {
    for (frames.shown[0..n]) |s| if (!s) return false;
    return true;
}

/// Until the compositor showed the last frames (or `max_ms` passed).
fn waitPresented(ed: *Editor, max_ms: i64) !void {
    const deadline = sys.monoMs() + max_ms;
    while (sys.monoMs() < deadline) {
        const pending = for (ed.win.surfaceList()) |s| {
            if (s.alive and s.frame_pending) break true;
        } else false;
        if (!pending) return;
        _ = try ed.win.nextEventTimeout(ed.win.pollTimeoutMs(@intCast(@max(1, deadline - sys.monoMs()))));
        ed.win.queue.clearRetainingCapacity();
    }
}
