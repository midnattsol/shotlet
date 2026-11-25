//! Capture-and-edit flow: acquisition (the shell integration, else the
//! platform's capture seam: api.capture.screens), then copy/save/save-as
//! handling around the editor (saving in deliver.zig).

const std = @import("std");
const log = std.log.scoped(.capture);
const platform = @import("../platform/api.zig");
const desktop = platform.desktop;
const shell = platform.shell;
const capture = @import("capture.zig");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/api.zig").sys;
const keep_mod = @import("keep.zig");
const history = @import("history.zig");
const annot = @import("annot.zig");
const modes = @import("modes/mode.zig");
const mode_flow = @import("modes/flow.zig");
const last_area = @import("modes/last_area.zig");
const deliver = @import("deliver.zig");
const refused = @import("refused.zig");
const out = @import("../cli/out.zig");
const handoff = @import("shot/handoff.zig");
const next = @import("shot/next.zig");
const handed = @import("shot/handed.zig");
const Timeline = @import("shot/timeline.zig").Timeline;
const window = @import("../platform/api.zig").window;
const editor_mod = @import("../ui/editor.zig");
const open_tool = @import("../ui/tools/open.zig");
const launch = @import("../ui/tools/launch.zig");
const Env = env_mod.Env;

fn warmupCapture() void {
    platform.capture.warmup();
}

pub fn nowMs() i64 {
    return sys.monoMs();
}

/// Dev sources that skip the portal.
pub const From = struct {
    /// one PNG as the whole capture
    file: ?[]const u8 = null,
    /// comma-separated PNGs, one per monitor, laid out left to right
    monitors: ?[]const u8 = null,
    /// taken by the GNOME Shell extension (not a dev source)
    shell: ?shell.HandedCapture = null,
    /// the capture mode (app/modes/), and its self-timer
    req: modes.Request = .{},
    /// already taken (a window KWin captured); owned by the capture
    image: ?png.Image = null,

    fn any(self: From) bool {
        return self.file != null or self.monitors != null or self.shell != null or self.image != null;
    }
};

pub fn run(gpa: std.mem.Allocator, env: Env, from: From, preset_sel: ?[4]i32, smoke_ms: i64) !void {
    var t = Timeline.start(if (from.shell) |s| s.t0_ms else null);
    // a capture the shell hands over loads meanwhile (shot/handed.zig)
    var handed_cap: handed.Loader = .{};
    handed_cap.start(gpa, env, from.shell);
    defer handed_cap.deinit();
    var bus = try desktop.connectBrief(gpa, env);
    defer bus.deinit();
    t.mark(.session);
    if (!from.any() and handedToShell(gpa, env, &bus, from.req, t.origin)) return;
    // the shell's frozen frame goes whatever happens next, at the latest
    // when this run ends (the editor takes it away sooner: onScreen)
    var frozen: Frozen = .{ .gpa = gpa, .bus = &bus, .id = if (from.shell) |s| s.id else null };
    defer frozen.end();

    // the capture backend's warm-up (Linux: dlopen(libpipewire), ~50-80ms)
    // overlaps the rest of setup
    const warmup_thread = if (from.any()) null else std.Thread.spawn(.{}, warmupCapture, .{}) catch null;
    // (a handed capture needs no portal before the editor is up: onScreen)
    if (from.shell == null) desktop.identify(gpa, &bus);

    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();
    t.mark(.setup);

    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    t.mark(.window);
    // a handed capture that opens the editor: its surfaces (and their
    // buffers) are made while the pieces still decode
    const early = if (from.shell) |sh| opensEditor(from.req.mode) and openEarly(&win, sh) else false;

    if (warmup_thread) |th| th.join();
    // the self-timer, where the GNOME extension did not count down
    if (from.req.delay_s > 0 and !from.any() and !try countDown(&win, &bus, from.req.delay_s)) return;
    var cap = (try acquire(gpa, env, &bus, &cfg, from, &handed_cap)) orelse {
        log.info("capture cancelled", .{});
        return;
    };
    defer cap.deinit(gpa);
    if (from.req.delay_s > 0) win.closeWindow();
    t.mark(.capture);
    var edit = (try editFor(.{ .gpa = gpa, .env = env, .bus = &bus, .cfg = &cfg, .win = &win }, &cap, from)) orelse return;
    defer gpa.free(edit.windows);

    if (!early) try openEditor(&win, &cap, perMonitor(&cap));
    t.mark(.surfaces);
    log.info("startup: capture={d}ms total={d}ms", .{ t.at.get(.capture) - t.at.get(.shotlet), t.at.get(.surfaces) - t.at.get(.shotlet) });
    edit.timeline = &t;
    edit.on_screen = .{ .ctx = &frozen, .f = Frozen.onScreen };
    try editAndFinish(gpa, env, &bus, &cfg, &win, &cap, preset_sel, smoke_ms, null, edit);
}

/// What the editor opens with after the capture (null: no editor).
fn editFor(c: mode_flow.Ctx, cap: *capture.Capture, from: From) !?mode_flow.Edit {
    var edit = switch (try mode_flow.afterCapture(c, cap, from.req)) {
        .done => return null,
        .edit => |e| e,
    };
    // where the windows were, for clicking one (an area to pick)
    if (edit.modes) edit.windows = platform.capture.windows(c.gpa, c.env, c.bus, cap, if (from.shell) |s| s.id else null);
    edit.from_shell = from.shell != null;
    if (edit.modes) edit.window_ok = platform.capture.canCaptureWindow(c.bus);
    return edit;
}

/// The GNOME integration's frozen frame of a handed capture, given back
/// once (api.shell.unfreeze): when the editor shows the capture, else
/// when the run ends.
const Frozen = struct {
    gpa: std.mem.Allocator,
    bus: *desktop.Bus,
    id: ?[]const u8,

    fn release(f: *Frozen) ?shell.FrozenInput {
        const id = f.id orelse return null;
        f.id = null;
        const input = shell.unfreeze(f.bus, id);
        // what run() put off for a handed capture
        desktop.identify(f.gpa, f.bus);
        return input;
    }

    fn end(f: *Frozen) void {
        _ = f.release();
    }

    /// The editor's first frames are on screen (ui/editor/opening.zig).
    fn onScreen(ctx: *anyopaque) ?shell.FrozenInput {
        const f: *Frozen = @ptrCast(@alignCast(ctx));
        return f.release();
    }
};

/// With the GNOME Shell extension, the shell takes the screenshot (no
/// prompt) and starts another shotlet on it. True when it took over (or
/// declined): this process has nothing left to do.
/// The self-timer's countdown, in the desktop's light/dark mode and accent.
fn countDown(win: *window.Window, bus: *desktop.Bus, seconds: u8) !bool {
    const theme = @import("../ui/theme.zig");
    return @import("../ui/countdown.zig").run(win, seconds, theme.of(theme.readPrefs(bus, 300)));
}

fn handedToShell(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, req: modes.Request, t0: i64) bool {
    if (!shell.applies() or !shell.active(bus)) return false;
    launch.handOff(env);
    switch (shell.requestCapture(gpa, bus, req)) {
        .started => {
            log.info("capture handed to the GNOME integration ({d}ms)", .{nowMs() - t0});
            return true;
        },
        .declined => return true,
        .unavailable => {
            // a copy the integration does not answer: said once a run,
            // and a scrolling capture would only be refused again
            if (refused.tell(gpa, env, bus) and req.mode == .scroll) out.exit(.failure);
            return false;
        },
    }
}

fn opensEditor(m: modes.Mode) bool {
    return m == .area or m == .previous;
}

/// The editor's surfaces for a handed capture, from its layout alone,
/// as openEditor makes them for the capture; false when the layout says
/// too little (they are made later then).
fn openEarly(win: *window.Window, sh: shell.HandedCapture) bool {
    const l = handed.layoutOf(sh.monitors) orelse return false;
    const ok = if (l.monitors > 1) win.openOutputs("Shotlet") else win.openOnOutputAt("Shotlet", l.x, l.y);
    ok catch return false;
    return true;
}

/// One fullscreen surface per monitor when the layout is known.
fn perMonitor(cap: *const capture.Capture) bool {
    return cap.monitors.len > 1 and for (cap.monitors) |m| {
        if (m.logical == null) break false;
    } else true;
}

/// The editor's fullscreen surfaces: one per monitor when the capture has
/// several; for a capture of one monitor (a portal that shares one, like
/// xdg-desktop-portal-wlr), on that monitor rather than wherever the
/// compositor puts a new window.
fn openEditor(win: anytype, cap: *const capture.Capture, per_monitor: bool) !void {
    defer log.debug("editor: {d} surfaces", .{win.n_surfaces});
    if (per_monitor) return win.openOutputs("Shotlet");
    if (cap.monitors.len == 1) if (cap.monitors[0].logical) |l| {
        return win.openOnOutputAt("Shotlet", l.x, l.y);
    };
    try win.open("Shotlet", .{ .fullscreen = true });
}

/// A kept capture opened again in the editor ("Annotate").
const Reopen = struct {
    kept: keep_mod.Kept,
    doc: *const annot.Doc,
};

/// The editor, then whatever its result asks for: copy, save, save as;
/// keeping the capture for quick access and the history. The mode
/// strip's Scroll picks a region on this same capture (its editor gone
/// first) and opens the tall image in a new editor.
pub fn editAndFinish(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, cfg: *config.Config, win: anytype, cap: *capture.Capture, preset_sel: ?[4]i32, smoke_ms: i64, reopen: ?Reopen, edit: mode_flow.Edit) !void {
    var then = try editOnce(gpa, env, bus, cfg, win, cap, preset_sel, smoke_ms, reopen, edit);
    while (then == .scroll) {
        const ctx: mode_flow.Ctx = .{ .gpa = gpa, .env = env, .bus = bus, .cfg = cfg, .win = win };
        const tall = (try next.scroll(ctx, cap)) orelse return;
        try openEditor(win, cap, perMonitor(cap));
        then = try editOnce(gpa, env, bus, cfg, win, cap, null, 0, null, tall);
    }
}

/// What follows an editor: nothing more, or a scrolling capture of its
/// capture.
const Then = enum { done, scroll };

fn editOnce(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, cfg: *config.Config, win: anytype, cap: *capture.Capture, preset_sel: ?[4]i32, smoke_ms: i64, reopen: ?Reopen, edit: mode_flow.Edit) !Then {
    var ed = editor_mod.Editor.init(gpa, win, &cap.image);
    ed.tools.env = env;
    ed.monitors = cap.monitors;
    configureEditor(&ed, bus, cfg, smoke_ms);
    const stateflag = @import("stateflag.zig");
    ed.loupe.hint.due = !stateflag.isSet(env.home, .zoom_hint);
    ed.show_hint = !stateflag.isSet(env.home, .editor_hint);
    ed.presetSelection(preset_sel);
    if (edit.sel) |r| ed.doc.sel = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    ed.keep_alpha = edit.keep_alpha;
    if (edit.note.len > 0) ed.tools.toast.show(.done, edit.note.text(), 3000);
    ed.opening.timeline = edit.timeline;
    ed.opening.on_screen = edit.on_screen;
    const ctx: mode_flow.Ctx = .{ .gpa = gpa, .env = env, .bus = bus, .cfg = cfg, .win = win };
    ed.capmode = .{ .on = edit.modes, .windows = edit.windows, .window_ok = edit.window_ok, .screen_in_place = edit.modes and mode_flow.screenOpensEditor(ctx) };
    defer ed.deinit();
    if (reopen) |r| try restoreReopened(gpa, &ed, r);
    while (true) {
        const result = try ed.run();
        if (reopen == null) @import("editor_prefs.zig").remember(gpa, env, cfg, &ed);
        defer if (result.png_data) |d| gpa.free(d);
        if (reopen == null and (result.action == .copied or result.action == .save or result.action == .save_as)) if (ed.doc.sel) |r|
            last_area.remember(gpa, env.home, cap, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });

        const f: Finish = .{ .gpa = gpa, .env = env, .bus = bus, .cfg = cfg, .win = win, .ed = &ed, .replace = if (reopen) |r| r.kept else null };
        switch (result.action) {
            // the mode strip's other capture modes (shot/next.zig)
            .new_capture => next.restart(ctx, &ed),
            .screen => try next.screen(ctx, &ed, cap),
            .record => try next.record(ctx, &ed, cap, edit.from_shell),
            .scroll => {
                next.leave(&ed, win);
                return .scroll;
            },
            .cancel, .copied => try f.closed(result.action == .copied),
            .save, .save_as => if (!try f.saved(result.action == .save, result.png_data.?)) {
                // the file chooser (over the editor) was cancelled or the
                // file could not be written: back to the editor,
                // annotations intact, rather than losing the work
                ed.running = true;
                ed.action = .cancel;
                continue;
            },
        }
        return .done;
    }
}

/// The editor's settings from the config and the desktop's light/dark
/// preference, accent and reduced motion.
fn configureEditor(ed: *editor_mod.Editor, bus: *desktop.Bus, cfg: *const config.Config, smoke_ms: i64) void {
    const theme = @import("../ui/theme.zig");
    // the desktop's appearance is asked once the capture is on screen
    // (ui/editor/opening.zig): the first frames show nothing it colours
    theme.watch(bus) catch {};
    ed.bus = bus;
    if (smoke_ms > 0) ed.smoke_deadline_ms = nowMs() + smoke_ms;
    ed.cfg_thickness = cfg.default_thickness;
    ed.color_idx = cfg.default_color;
    ed.binds = cfg.binds;
    ed.loupe.mode = cfg.loupe;
    ed.loupe.zoom = cfg.loupe_zoom;
    ed.beautify = .{
        .enabled = cfg.beautify_always,
        .bg = cfg.beautify_background,
        .padding = cfg.beautify_padding,
        .rounded = cfg.beautify_corners,
        .shadow = cfg.beautify_shadow,
    };
    ed.beautify_always = cfg.beautify_always;
}

/// A reopened capture: the shapes as they were, still editable.
fn restoreReopened(gpa: std.mem.Allocator, ed: *editor_mod.Editor, r: Reopen) !void {
    ed.show_hint = false;
    ed.loupe.hint.due = false;
    ed.beautify = r.doc.beautify;
    ed.doc.sel = r.doc.sel orelse ed.doc.imageRect();
    for (r.doc.shapes.items) |*s| {
        var c = try s.clone(gpa);
        ed.doc.shapes.append(gpa, c) catch |err| {
            c.deinit(gpa);
            return err;
        };
    }
}

/// What happens after the editor closed with a result.
const Finish = struct {
    gpa: std.mem.Allocator,
    env: Env,
    bus: *desktop.Bus,
    cfg: *config.Config,
    win: *window.Window,
    ed: *editor_mod.Editor,
    /// the history entry a reopened capture updates
    replace: ?keep_mod.Kept,

    /// Cancel or Copy: the window closes; a copy is kept and served.
    fn closed(f: Finish, copied: bool) !void {
        // the clipboard's copy may be dropped while the editor fades
        const data: ?[]u8 = if (!copied) null else if (f.win.clipboardPng()) |d| f.gpa.dupe(u8, d) catch null else null;
        defer if (data) |d| f.gpa.free(d);
        f.close(data, "");
        if (f.win.hasClipboard()) try f.win.serveClipboard();
    }

    /// Save (`quick`: to the screenshots folder) or Save As, then copy
    /// and notify as deliver.zig says. False when the file chooser was
    /// cancelled or writing failed (the editor says why). Save writes
    /// before the editor closes, so a failure keeps it.
    fn saved(f: Finish, quick: bool, data: []const u8) !bool {
        const path = f.write(quick, data) orelse return false;
        defer f.gpa.free(path);
        f.close(data, path);
        if (f.win.hasClipboard()) try f.win.serveClipboard();
        return true;
    }

    /// The file written (owned); null when the chooser was cancelled or
    /// writing failed, which the editor (still open) shows.
    fn write(f: Finish, quick: bool, data: []const u8) ?[]u8 {
        const c: deliver.Ctx = .{
            .gpa = f.gpa,
            .env = f.env,
            .cfg = f.cfg,
            .bus = f.bus,
            .win = f.win,
            .over = f.win,
            .thumbnail_shows = f.cfg.showsThumbnail(true),
            .who = "editor",
        };
        return deliver.savePng(c, data, if (quick) .folder else .ask) catch |err| {
            log.warn("could not save: {t}", .{err});
            var buf: [160]u8 = undefined;
            f.ed.tools.toast.show(.problem, deliver.failureText(&buf, err), 6000);
            f.ed.needs_render = true;
            return null;
        };
    }

    /// The editor fades out and closes; `data` (what was copied or
    /// saved) is kept for the history and the thumbnail meanwhile.
    fn close(f: Finish, data: ?[]const u8, saved_path: []const u8) void {
        const ed = f.ed;
        // annotating a pin: it shows the result (or comes back as it was)
        _ = launch.backToPin(data);
        const what: ?keep_mod.What = if (data) |d| .{ .image_png = d, .source = ed.img, .doc = &ed.doc, .beautify = ed.beautify, .saved = saved_path, .replace = f.replace, .at = open_tool.selectionCentre(ed) } else null;
        handoff.close(.{ .gpa = f.gpa, .env = f.env, .cfg = f.cfg, .win = f.win, .ed = ed }, what, f.cfg.showsThumbnail(saved_path.len > 0));
        ed.releaseCaches(); // serving may outlive the session; drop ~140MB
    }
};

/// `shotlet edit ROOT ID`: open a kept capture in the editor again, with
/// its annotations; Copy or Save update the same entry.
pub fn runEdit(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
    if (!history.Id.valid(id)) return error.BadId;
    var path_buf: [1200]u8 = undefined;
    const src_data = try sys.readFileAlloc(gpa, try history.entryPath(&path_buf, root, id, "source.png"), 256 * 1024 * 1024);
    defer gpa.free(src_data);
    const doc_data = try sys.readFileAlloc(gpa, try history.entryPath(&path_buf, root, id, "doc"), 64 * 1024 * 1024);
    defer gpa.free(doc_data);
    var doc = try annot.parse(gpa, doc_data);
    defer doc.deinit(gpa);
    var img = try png.decode(gpa, src_data);
    var cap = capture.Capture.single(gpa, img) catch |err| {
        img.deinit(gpa);
        return err;
    };
    defer cap.deinit(gpa);

    var bus = try desktop.connect(gpa, env);
    defer bus.deinit();
    var cfg = config.load(gpa, env.home);
    const text = @import("../gfx/text.zig");
    text.init(gpa);
    defer text.deinit();
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    try win.open("Shotlet", .{ .fullscreen = true });
    log.info("editing {s} again", .{id});
    var kept: keep_mod.Kept = .{ .id = history.Id.fromSlice(id).? };
    if (root.len > kept.root_buf.len) return error.PathTooLong;
    @memcpy(kept.root_buf[0..root.len], root);
    kept.root_len = root.len;
    try editAndFinish(gpa, env, &bus, &cfg, &win, &cap, null, 0, .{ .kept = kept, .doc = &doc }, .{});
}

/// Get the image to edit. Null means the person cancelled a dialog: the
/// caller exits quietly, with no fallback and no further dialogs.
pub fn acquire(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, cfg: *config.Config, from: From, handed_cap: ?*handed.Loader) !?capture.Capture {
    if (from.shell != null) {
        const cap = try handed_cap.?.take();
        platform.capture.remember(env.home, .shell);
        return cap;
    }
    if (from.any()) return try fromGiven(gpa, from);
    return platform.capture.screens(gpa, env, bus, cfg);
}

/// A capture that is already taken: by KWin, or a dev source.
fn fromGiven(gpa: std.mem.Allocator, from: From) !capture.Capture {
    if (from.image) |img| return try capture.Capture.single(gpa, img);
    if (from.monitors) |list| return try fromMonitorFiles(gpa, list);
    const data = try sys.readFileAlloc(gpa, from.file.?, 256 * 1024 * 1024);
    defer gpa.free(data);
    var img = try png.decode(gpa, data);
    errdefer img.deinit(gpa);
    return try capture.Capture.single(gpa, img);
}

/// Dev: stitch one PNG per monitor, placed left to right in a logical
/// layout of their pixel sizes (as monitors at scale 1 would be).
fn fromMonitorFiles(gpa: std.mem.Allocator, list: []const u8) !capture.Capture {
    var imgs: [8]png.Image = undefined;
    var parts: [8]capture.Part = undefined;
    var n: usize = 0;
    defer for (imgs[0..n]) |*im| im.deinit(gpa);
    var x: i32 = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |path| {
        if (n == imgs.len) return error.TooManyMonitors;
        const data = try sys.readFileAlloc(gpa, path, 256 * 1024 * 1024);
        defer gpa.free(data);
        imgs[n] = try png.decode(gpa, data);
        const im = &imgs[n];
        parts[n] = .{ .pixels = im.pixels, .width = im.width, .height = im.height, .logical = .{ .x = x, .y = 0, .w = @intCast(im.width), .h = @intCast(im.height) } };
        x += @intCast(im.width);
        n += 1;
    }
    return capture.stitch(gpa, parts[0..n]);
}
