//! `shotlet trim ROOT ID`: the trim window of a kept recording. Drag the
//! yellow handles on the filmstrip (or click it to move the playhead),
//! play the range, then Save trimmed: a new file next to the original,
//! kept and shown as a new thumbnail. `--range A,B --export` does it
//! without a window (tests, scripts).

const std = @import("std");
const env_mod = @import("../../app/env.zig");
const config = @import("../../app/config.zig");
const history = @import("../../app/history.zig");
const relaunch = @import("../../app/relaunch.zig");
const sys = @import("../../platform/api.zig").sys;
const png = @import("../../gfx/png.zig");
const text = @import("../../gfx/text.zig");
const window = @import("../../platform/api.zig").window;
const keepvid = @import("../../record/keepvid.zig");
const trim = @import("../../record/trim.zig");
const ffmpeg_proc = @import("../../encode/ffmpeg_proc.zig");
const strip_mod = @import("../../record/strip.zig");
const draw = @import("trim_draw.zig");
const frame_mod = @import("../frame.zig");
const theme = @import("../theme.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const Env = env_mod.Env;

const Trim = struct {
    gpa: std.mem.Allocator,
    env: Env,
    root: []const u8,
    id: []const u8,
    info: keepvid.Info,
    strip: ?png.Image,
    /// frame number of each strip picture
    marks: [strip_mod.max]u64 = undefined,
    n_marks: usize = 0,
    st: draw.State,
    dragging: ?draw.Part = null,
    play_t0: i64 = 0,
    play_pos0: i64 = 0,
    pic_buf: []u32 = &.{},
    done: bool = false,
    frame: frame_mod.Frame = .{},
    /// the button pressed (it acts when released over it)
    pressed: press.Press(draw.Part) = .{},
    /// a press on no control: dragging from there moves the window,
    /// which has no title bar
    move: press.Press(void) = .{},

    /// The strip picture nearest to `ms`.
    fn pictureAt(self: *Trim, ms: i64) void {
        const s = self.strip orelse return;
        if (self.n_marks == 0) return;
        const frame: u64 = @intCast(@divTrunc(@max(ms, 0) * self.info.fps, 1000));
        var best: usize = 0;
        for (self.marks[0..self.n_marks], 0..) |m, i| if (m <= frame) {
            best = i;
        };
        const pw = s.width / @as(u32, @intCast(self.n_marks));
        if (self.pic_buf.len != @as(usize, pw) * s.height) {
            self.gpa.free(self.pic_buf);
            self.pic_buf = self.gpa.alloc(u32, @as(usize, pw) * s.height) catch return;
        }
        for (0..s.height) |y| @memcpy(self.pic_buf[y * pw ..][0..pw], s.pixels[y * s.width + best * pw ..][0..pw]);
        self.st.pic = self.pic_buf;
        self.st.pic_w = pw;
        self.st.pic_h = s.height;
    }

    fn seek(self: *Trim, ms: i64) void {
        self.st.pos_ms = std.math.clamp(ms, 0, self.info.duration_ms);
        self.pictureAt(self.st.pos_ms);
    }

    /// A press at logical x, y (`phys`: the same in physical px).
    fn onPress(self: *Trim, x: i32, y: i32, phys: [2]f64) void {
        const p = draw.hit(x, y, &self.st) orelse {
            self.move.down({}, phys[0], phys[1]);
            return;
        };
        switch (p) {
            .play, .cancel, .save => self.pressed.down(p, phys[0], phys[1]),
            .start, .end => self.dragging = p,
            .strip => {
                self.dragging = .strip;
                self.seek(draw.msAt(x, self.info.duration_ms));
            },
        }
    }

    /// A release over logical x, y: a click when on the button pressed.
    fn onRelease(self: *Trim, x: i32, y: i32) void {
        self.dragging = null;
        self.move.cancel();
        const p = self.pressed.up(draw.hit(x, y, &self.st)) orelse return;
        switch (p) {
            .play => self.togglePlay(),
            .cancel => self.done = true,
            .save => self.save(),
            else => {},
        }
    }

    fn onDrag(self: *Trim, x: i32) void {
        const d = self.dragging orelse return;
        const ms = draw.msAt(x, self.info.duration_ms);
        const min_len = 200;
        switch (d) {
            .start => {
                self.st.start_ms = std.math.clamp(ms, 0, self.st.end_ms - min_len);
                self.seek(self.st.start_ms);
            },
            .end => {
                self.st.end_ms = std.math.clamp(ms, self.st.start_ms + min_len, self.info.duration_ms);
                self.seek(self.st.end_ms);
            },
            .strip => self.seek(ms),
            else => {},
        }
    }

    fn togglePlay(self: *Trim) void {
        self.st.playing = !self.st.playing;
        if (!self.st.playing) return;
        if (self.st.pos_ms < self.st.start_ms or self.st.pos_ms >= self.st.end_ms - 50) self.seek(self.st.start_ms);
        self.play_t0 = sys.monoMs();
        self.play_pos0 = self.st.pos_ms;
    }

    fn tick(self: *Trim) void {
        if (!self.st.playing) return;
        const pos = self.play_pos0 + sys.monoMs() - self.play_t0;
        if (pos >= self.st.end_ms) {
            self.st.playing = false;
            self.seek(self.st.end_ms);
            return;
        }
        self.seek(pos);
    }

    fn save(self: *Trim) void {
        self.st.busy = "Saving\u{2026}";
        if (exportRange(self.gpa, self.env, &self.info, .{ .start_ms = self.st.start_ms, .end_ms = self.st.end_ms })) {
            self.done = true;
        } else |err| {
            std.log.warn("trim: failed: {t}", .{err});
            self.st.busy = if (err == error.NoFfmpeg) "Trimming videos needs the ffmpeg program" else "Could not trim";
        }
    }
};

/// Cut, keep the result and show its thumbnail.
pub fn exportRange(gpa: std.mem.Allocator, env: Env, info: *const keepvid.Info, r: trim.Range) !void {
    const envp: @import("../../platform/api.zig").proc.Envp = @ptrCast(env.envp);
    const dst = try trim.outputPath(gpa, info.path);
    defer gpa.free(dst);
    trim.cut(gpa, envp, info.path, dst, r) catch |err| {
        sys.unlink(dst) catch {};
        return err;
    };
    std.log.info("trim: wrote {s} ({d}-{d} ms)", .{ dst, r.start_ms, r.end_ms });
    const first = firstPicture(gpa, envp, dst, info) catch |err| {
        std.log.info("trim: no first picture ({t}); not kept", .{err});
        return;
    };
    defer gpa.free(first);
    const cfg = config.load(gpa, env.home);
    var strip: strip_mod.Strip = .{ .gpa = gpa };
    defer strip.deinit();
    var out = info.*;
    out.path = dst;
    out.duration_ms = r.end_ms - r.start_ms;
    out.frames = @intCast(@divTrunc(out.duration_ms * info.fps, 1000));
    out.strip = "";
    if (keepvid.store(gpa, env, &cfg, .{ .info = out, .first = first, .first_w = info.width, .first_h = info.height, .strip = &strip })) |k| {
        if (cfg.showsThumbnail(true)) relaunch.quickVideo(env, k.root(), k.id.slice());
    }
}

fn firstPicture(gpa: std.mem.Allocator, envp: @import("../../platform/api.zig").proc.Envp, path: []const u8, info: *const keepvid.Info) ![]u32 {
    if (info.format == .mp4) return ffmpeg_proc.frameAt(gpa, envp, path, 0, info.width, info.height);
    const data = try sys.readFileAlloc(gpa, path, 512 * 1024 * 1024);
    defer gpa.free(data);
    var d = try @import("../../encode/gifdec.zig").Decoder.init(gpa, data);
    defer d.deinit();
    const f = (try d.next()) orelse return error.NoFrame;
    return gpa.dupe(u32, f.pixels);
}

/// `trim ROOT ID [--range A,B] [--export]` as parsed.
pub const Options = struct {
    /// milliseconds to keep (default: the whole recording)
    range: ?trim.Range = null,
    /// write the trimmed file without a window (--export)
    headless: bool = false,
};

pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8, opts: Options) !void {
    if (!history.Id.valid(id)) return error.BadId;
    const vi = keepvid.read(gpa, root, id) orelse return error.NotARecording;
    defer gpa.free(vi.buf);
    const range = opts.range orelse trim.Range{ .start_ms = 0, .end_ms = vi.info.duration_ms };
    if (opts.headless) return exportRange(gpa, env, &vi.info, range);
    try runWindow(gpa, env, root, id, vi.info, range);
}

fn runWindow(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8, info: keepvid.Info, range: trim.Range) !void {
    text.init(gpa);
    defer text.deinit();
    const th = theme.load(gpa, env, 300);
    var t: Trim = .{ .gpa = gpa, .env = env, .root = root, .id = id, .info = info, .strip = null, .st = .{ .duration_ms = info.duration_ms, .start_ms = range.start_ms, .end_ms = range.end_ms, .pos_ms = range.start_ms, .th = th } };
    defer gpa.free(t.pic_buf);
    defer t.frame.deinit(gpa);
    var pbuf: [1200]u8 = undefined;
    if (sys.readFileAlloc(gpa, try history.entryPath(&pbuf, root, id, "strip.png"), 64 * 1024 * 1024)) |data| {
        defer gpa.free(data);
        t.strip = png.decode(gpa, data) catch null;
    } else |_| {}
    defer if (t.strip) |*s| s.deinit(gpa);
    var it = std.mem.splitScalar(u8, info.strip, ',');
    while (it.next()) |m| {
        if (t.n_marks == t.marks.len) break;
        t.marks[t.n_marks] = std.fmt.parseInt(u64, m, 10) catch continue;
        t.n_marks += 1;
    }
    if (t.strip) |s| {
        t.st.strip_px = s.pixels;
        t.st.strip_w = s.width;
        t.st.strip_h = s.height;
    }
    t.seek(range.start_ms);
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    const size = frame_mod.outer(draw.width, draw.height);
    try win.open("Trim recording", .{ .fullscreen = false, .transparent = true, .width = size[0], .height = size[1] });
    win.setCursor(.arrow) catch {};
    std.log.info("trim: {s} ({d} ms)", .{ info.path, info.duration_ms });
    var dirty = true;
    while (!t.done) {
        if (try win.nextEventTimeout(win.pollTimeoutMs(if (t.st.playing) 30 else 200))) |ev| {
            try onEvent(&t, &win, ev);
            dirty = true;
        }
        while (win.queue.items.len > 0) try onEvent(&t, &win, try win.nextEvent());
        t.tick();
        if (dirty or t.st.playing) dirty = !try paint(&t, &win);
    }
}

/// The ends of the kept range drag sideways; elsewhere the arrow.
fn cursorOf(hover: ?draw.Part) window.Cursor {
    const h = hover orelse return .arrow;
    return switch (h) {
        .start, .end => .resize_ew,
        .play, .cancel, .save, .strip => .arrow,
    };
}

/// A pointer position on the window (physical px) in the content's
/// logical pixels.
fn contentPoint(win: *const window.Window, x: f64, y: f64) [2]i32 {
    const F = frame_mod.Frame;
    const k = scale.of(win.scale120);
    return .{ scale.toLogical(F.toContent(win, x), k), scale.toLogical(F.toContent(win, y), k) };
}

fn onEvent(t: *Trim, win: *window.Window, ev: window.InputEvent) !void {
    switch (ev) {
        .close => t.done = true,
        .pointer_motion => |m| {
            const p = contentPoint(win, m.x, m.y);
            t.onDrag(p[0]);
            if (t.move.dragged(m.x, m.y, scale.of(win.scale120))) {
                t.move.cancel();
                try win.startMove();
            }
            t.st.hover = if (t.dragging == null) draw.hit(p[0], p[1], &t.st) else t.dragging;
            win.setCursor(cursorOf(t.st.hover)) catch {};
        },
        .pointer_button => |b| if (b.button == .left) {
            const p = contentPoint(win, b.x, b.y);
            if (b.pressed) t.onPress(p[0], p[1], .{ b.x, b.y }) else t.onRelease(p[0], p[1]);
        },
        .key => |key| if (key.pressed) switch (key.code) {
            .escape => t.done = true,
            .space => t.togglePlay(),
            .enter => t.save(),
            else => {},
        },
        else => {},
    }
}

/// Draw a frame; false when the window was not ready for one.
fn paint(t: *Trim, win: *window.Window) !bool {
    if (win.frame_pending or win.width == 0) return false;
    var cv = try t.frame.begin(t.gpa, win);
    draw.paint(t.gpa, &cv, scale.of(win.scale120), &t.st);
    try t.frame.present(win, draw.edge(t.st.th));
    return true;
}
