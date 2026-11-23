//! The editor's first frames. The capture goes out first, plain, as it
//! is (no dim, no chrome: what the fade-in starts from anyway), on every
//! surface; once the compositor has those frames the caller hears it
//! (the GNOME integration's own frozen frame can go). Only then are the
//! layer and each pane's caches made, on a worker thread, while the
//! event loop keeps answering the compositor; input meanwhile waits in
//! the queue, in order. The editor proper (the fade-in, the toolbar)
//! starts once they are made.
//!
//! A capture reopened with shapes on it skips the plain frames: its
//! caches are made at once and its first frame is a full one.

const std = @import("std");
const log = std.log.scoped(.editor);
const editor = @import("../editor.zig");
const view_mod = @import("../view.zig");
const bands = @import("../bands.zig");
const caches = @import("caches.zig");
const events = @import("events.zig");
const session = @import("session.zig");
const theme = @import("../theme.zig");
const sys = @import("../../platform/api.zig").sys;
const window = @import("../../platform/api.zig").window;
const Timeline = @import("../../app/shot/timeline.zig").Timeline;

const Editor = editor.Editor;
const Rect = @import("../shapes.zig").Rect;

/// Someone to tell once the capture is on screen; it may answer with
/// what the pointer and keyboard did before (the GNOME integration's
/// frozen frame held them), which the editor then takes up.
pub const Hook = struct {
    ctx: *anyopaque,
    f: *const fn (*anyopaque) ?FrozenInput,
};

pub const FrozenInput = @import("../../platform/api.zig").shell.FrozenInput;

pub const Phase = enum { first, preparing, ready };

pub const Opening = struct {
    /// the steps' times (app/shot/timeline.zig), when the caller keeps one
    timeline: ?*Timeline = null,
    /// told once the plain frames are on screen
    on_screen: ?Hook = null,
    phase: Phase = .first,
    started_ms: i64 = 0,
    /// per surface: its plain frame went out
    shown: [editor.max_panes]bool = @splat(false),
    worker: ?std.Thread = null,
    prepared: std.atomic.Value(bool) = .init(false),
    failed: ?anyerror = null,
    /// the desktop's appearance, asked while the caches are made
    prefs: ?theme.Prefs = null,
    /// what was done on the shell's frozen frame (the caller's answer)
    input: ?FrozenInput = null,

    fn mark(o: *Opening, s: @import("../../app/shot/timeline.zig").Step) void {
        if (o.timeline) |t| t.mark(s);
    }
};

/// One step of the opening, called by the event loop before anything
/// else; true while the editor is not ready (the loop handles no input
/// and draws nothing of its own meanwhile).
pub fn step(ed: *Editor) !bool {
    const o = &ed.opening;
    switch (o.phase) {
        .ready => return false,
        .first => try firstFrames(ed),
        .preparing => try waitPrepared(ed),
    }
    return o.phase != .ready;
}

/// The editor drew a full frame on every surface: the opening's last
/// step (logged with the timeline).
pub fn readyShown(ed: *Editor) void {
    const o = &ed.opening;
    const t = o.timeline orelse return;
    if (t.since(.ready) != null) return;
    t.mark(.ready);
    log.info("ready {d} ms after the editor started", .{sys.monoMs() - o.started_ms});
    t.report();
}

/// The plain capture on every surface free to take it; once all have
/// it, the caller is told and the caches start.
fn firstFrames(ed: *Editor) !void {
    const o = &ed.opening;
    if (o.started_ms == 0) o.started_ms = sys.monoMs();
    try takeSizes(ed);
    if (!ed.running) return;
    if (ed.doc.shapes.items.len > 0) return prepareNow(ed);
    if (!try plainFrames(ed) or !anyShown(ed)) return pump(ed, 4);
    o.mark(.first_frame);
    log.info("first frame on every surface {d} ms after the editor started", .{sys.monoMs() - o.started_ms});
    // the compositor has them once it answers
    try ed.win.roundtrip();
    o.mark(.on_screen);
    o.phase = .preparing;
    o.worker = std.Thread.spawn(.{}, prepareAll, .{ed}) catch null;
    if (o.worker == null) prepareAll(ed);
}

/// What the pointer and keyboard did while the shell's frozen frame was
/// up, ahead of everything queued since (the queue holds only what came
/// after it): Escape cancels; a press (and
/// its release) at the desktop point it happened.
fn takeUp(ed: *Editor, in: FrozenInput) !void {
    if (in.escaped) {
        log.info("Escape on the frozen frame: closed", .{});
        ed.action = .cancel;
        ed.running = false;
        return;
    }
    if (!in.pressed) return;
    const q = &ed.win.queue;
    const down = buttonAt(ed, in.x, in.y, true) orelse return;
    try q.insert(ed.win.alloc, 0, down);
    if (in.released) if (buttonAt(ed, in.rx, in.ry, false)) |up| try q.insert(ed.win.alloc, 1, up);
}

/// A left button event at desktop point (x, y) (logical pixels) on the
/// surface showing it, in that surface's buffer pixels.
pub fn buttonAt(ed: *const Editor, x: i32, y: i32, pressed: bool) ?window.InputEvent {
    for (ed.win.surfaceList(), 0..) |s, i| {
        if (!s.alive or s.out_w == 0 or s.logical_w == 0) continue;
        if (x < s.x or y < s.y or x >= s.x + @as(i32, @intCast(s.out_w)) or y >= s.y + @as(i32, @intCast(s.out_h))) continue;
        const kx = @as(f64, @floatFromInt(s.width)) / @as(f64, @floatFromInt(s.logical_w));
        const ky = @as(f64, @floatFromInt(s.height)) / @as(f64, @floatFromInt(s.logical_h));
        const bx = @as(f64, @floatFromInt(x - s.x)) * kx;
        const by = @as(f64, @floatFromInt(y - s.y)) * ky;
        return .{ .pointer_button = .{ .button = .left, .pressed = pressed, .x = bx, .y = by, .surface = @intCast(i) } };
    }
    return null;
}

/// The plain capture on every surface ready for it, drawn side by side
/// (a thread each), then presented; false while some surface is not.
fn plainFrames(ed: *Editor) !bool {
    const o = &ed.opening;
    const surfs = ed.win.surfaceList();
    var all = true;
    var due: [editor.max_panes]?[]u32 = @splat(null);
    for (surfs, 0..) |s, i| {
        if (!s.alive or i >= editor.max_panes or o.shown[i]) continue;
        const p = &ed.panes[i];
        if (!p.alive or p.width != s.width or p.height != s.height or s.frame_pending) {
            all = false;
            continue;
        }
        due[i] = try ed.win.backBufferOf(@intCast(i));
    }
    var threads: [editor.max_panes]?std.Thread = @splat(null);
    for (due, 0..) |px, i| if (px) |b| {
        threads[i] = std.Thread.spawn(.{}, drawPlain, .{ ed, &ed.panes[i], b }) catch null;
        if (threads[i] == null) drawPlain(ed, &ed.panes[i], b);
    };
    for (threads) |t| if (t) |th| th.join();
    for (due, 0..) |px, i| if (px != null) {
        try ed.win.presentSurface(@intCast(i));
        o.shown[i] = true;
    };
    return all;
}

fn anyShown(ed: *const Editor) bool {
    for (ed.opening.shown) |s| if (s) return true;
    return false;
}

/// Handle the surfaces' sizes (and a close) from the queue; the rest of
/// it stays, in order, for the editor proper.
fn takeSizes(ed: *Editor) !void {
    const q = &ed.win.queue;
    var i: usize = 0;
    while (i < q.items.len) {
        switch (q.items[i]) {
            .resize, .close => try events.handle(ed, q.orderedRemove(i)),
            else => i += 1,
        }
    }
}

/// The capture as pane `p` shows it, nothing else, into `px` (what the
/// pane's view will be: view_mod.resample of the image), in bands.
fn drawPlain(ed: *const Editor, p: *const editor.Pane, px: []u32) void {
    const Ctx = struct {
        ed: *const Editor,
        p: *const editor.Pane,
        px: []u32,
        fn band(c: @This(), b: Rect) void {
            const img = c.ed.img;
            view_mod.resample(img.pixels, img.width, img.height, c.p.view, c.px, c.p.width, c.p.height, b);
        }
    };
    bands.run(.ofSize(p.width, p.height), Ctx{ .ed = ed, .p = p, .px = px }, Ctx.band);
}

/// Every pane's caches (on the worker), a thread each. Nothing is drawn
/// yet, so the image is the layer.
fn prepareAll(ed: *Editor) void {
    const o = &ed.opening;
    const Fill = struct {
        fn run(e: *const Editor, p: *editor.Pane, err: *?anyerror) void {
            caches.fillPane(e, p) catch |x| {
                err.* = x;
            };
        }
    };
    var threads: [editor.max_panes]?std.Thread = @splat(null);
    var errs: [editor.max_panes]?anyerror = @splat(null);
    for (0..ed.n_panes) |i| {
        threads[i] = std.Thread.spawn(.{}, Fill.run, .{ ed, &ed.panes[i], &errs[i] }) catch null;
        if (threads[i] == null) Fill.run(ed, &ed.panes[i], &errs[i]);
    }
    // meanwhile, the session's calls (the event loop only answers the
    // compositor till then): the caller (the shell's frozen frame goes,
    // what was pressed on it comes back), the desktop's appearance; both
    // taken up once prepared
    if (o.on_screen) |h| o.input = h.f(h.ctx);
    if (ed.bus) |b| o.prefs = theme.readPrefs(b, 1500);
    for (threads[0..ed.n_panes], errs[0..ed.n_panes]) |t, e| {
        if (t) |th| th.join();
        if (e) |err| o.failed = err;
    }
    o.prepared.store(true, .release);
}

/// The caches made on this thread (no plain frames: shapes to show).
fn prepareNow(ed: *Editor) !void {
    const o = &ed.opening;
    if (ed.bus) |b| session.setPrefs(ed, theme.readPrefs(b, 1500));
    for (0..ed.n_panes) |i| try caches.preparePane(ed, @intCast(i));
    o.phase = .ready;
    ed.needs_render = true;
}

/// Keep answering the compositor until the worker is done; then the
/// editor proper starts with whatever input came meanwhile.
fn waitPrepared(ed: *Editor) !void {
    const o = &ed.opening;
    if (!o.prepared.load(.acquire)) return pump(ed, 2);
    if (o.worker) |th| th.join();
    o.worker = null;
    if (o.failed) |err| return err;
    o.phase = .ready;
    if (o.input) |in| try takeUp(ed, in);
    if (o.prefs) |pr| session.setPrefs(ed, pr);
    for (ed.panes[0..ed.n_panes]) |*p| if (p.alive) {
        p.content_dirty.add(.ofSize(p.width, p.height));
        p.gen +%= 1;
    };
    ed.needs_render = true;
    // the plain frames' callbacks may be held back while the shell's
    // frozen frame covered them: the full frames go out now
    for (0..ed.n_panes) |i| ed.win.skipFrameWait(@intCast(i));
}

/// Wait up to `ms` on the display connection, dispatching what comes
/// (input stays queued).
fn pump(ed: *Editor, ms: i32) !void {
    try ed.win.dispatchFor(ms);
}

/// The worker is joined before the editor goes away.
pub fn deinit(ed: *Editor) void {
    if (ed.opening.worker) |th| th.join();
    ed.opening.worker = null;
}
