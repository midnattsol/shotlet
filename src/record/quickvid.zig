//! `shotlet quick-video ROOT ID`: the floating thumbnail of a finished
//! recording, in the bottom-left corner like the screenshot thumbnail
//! (a layer-shell surface, or a "shotlet:quick" window the GNOME Shell
//! extension places). Hovering plays the filmstrip; Copy puts the file on
//! the clipboard (text/uri-list, and the video itself as video/mp4 or
//! image/gif); Save as… copies it elsewhere; the scissors open the trim
//! window; dragging it drops the file into another app. It fades in and
//! stays until closed: a recording is not glanced at like a screenshot.

const std = @import("std");
const log = std.log.scoped(.quick_video);
const uri_mod = @import("../uri.zig");
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("../app/env.zig");
const history = @import("../app/history.zig");
const relaunch = @import("../app/relaunch.zig");
const sys = @import("../platform/api.zig").sys;
const png = @import("../gfx/png.zig");
const text = @import("../gfx/text.zig");
const window = @import("../platform/api.zig").window;
const fui = @import("../ui/floatui.zig");
const floatwin = @import("../ui/floatwin.zig");
const motion = @import("../ui/motion.zig");
const press = @import("../ui/press.zig");
const scale = @import("../ui/scale.zig");
const theme = @import("../ui/theme.zig");
const notice_mod = @import("../ui/notice.zig");
const Notice = notice_mod.Notice;
const focus = @import("../ui/focus.zig");
const deliver = @import("../app/deliver.zig");
const card = @import("../ui/recui/vidcard.zig");
const keepvid = @import("keepvid.zig");
const files = @import("files.zig");
const Env = env_mod.Env;

const frame_ms = 160;

const Quick = struct {
    gpa: std.mem.Allocator,
    env: Env,
    win: window.Window,
    root: []const u8,
    id: []const u8,
    info: keepvid.Info,
    thumb: png.Image,
    strip: ?png.Image,
    strip_n: u32 = 0,
    /// the desktop's appearance (motion.enabled follows it too)
    th: theme.Theme,
    hover: ?card.Control = null,
    /// the left button held on a control (a click is its release there)
    press: press.Press(card.Control) = .{},
    /// fading in from the first frame, out once closed
    life: motion.Life = .{},
    /// "Copied", "Saved · Show in Files" over the card for a while
    notice: Notice = .{},
    play_from: i64 = 0,
    dirty: bool = true,
    drag: fui.DragOut = .{},
    done: bool = false,
    /// a layer surface (keyboard only while the pointer is over it)
    layer: bool = false,

    fn factor(self: *const Quick) f64 {
        return scale.of(self.win.scale120);
    }

    /// What is under a pointer at x, y (buffer pixels).
    fn hitAt(self: *const Quick, x: f64, y: f64) ?card.Control {
        const k = self.factor();
        return card.hitWith(&self.notice, scale.toLogical(x, k), scale.toLogical(y, k), sys.monoMs());
    }

    /// The picture to show now: a strip picture while hovered.
    fn picture(self: *const Quick, now: i64) struct { px: []const u32, w: u32, h: u32 } {
        if (self.hover != null and self.strip_n > 1) if (self.strip) |s| {
            const pw = s.width / self.strip_n;
            const i: u32 = @intCast(@mod(@divTrunc(now - self.play_from, frame_ms), self.strip_n));
            return .{ .px = stripPic(s, pw, i, &pic_buf), .w = pw, .h = s.height };
        };
        return .{ .px = self.thumb.pixels, .w = self.thumb.width, .h = self.thumb.height };
    }

    var pic_buf: [strip_max_px]u32 = undefined;
    const strip_max_px = 256 * 256;

    fn stripPic(s: png.Image, pw: u32, i: u32, buf: *[strip_max_px]u32) []const u32 {
        const n = @min(@as(usize, pw) * s.height, buf.len);
        for (0..s.height) |y| {
            if ((y + 1) * pw > n) break;
            @memcpy(buf[y * pw ..][0..pw], s.pixels[y * s.width + i * pw ..][0..pw]);
        }
        return buf[0..n];
    }

    fn render(self: *Quick) !void {
        const now = sys.monoMs();
        if (self.hover != null and self.strip_n > 1) self.dirty = true;
        if (!self.dirty or !floatwin.canDraw(&self.win)) return;
        self.dirty = false;
        const px = try self.win.backBuffer();
        @memset(px, 0);
        const pic = self.picture(now);
        self.life.start(now);
        var alpha = self.life.alpha(now);
        if (self.drag.active) alpha = @min(alpha, 0.5);
        card.paint(self.gpa, px, self.win.width, self.win.height, self.factor(), &.{
            .pic = pic.px,
            .pic_w = pic.w,
            .pic_h = pic.h,
            .duration_ms = self.info.duration_ms,
            .gif = self.info.format == .gif,
            .hover = self.hover,
            .hovered = self.hover != null,
            .notice = &self.notice,
            .now = now,
            .alpha = alpha,
            .th = self.th,
        });
        try floatwin.presentStraight(&self.win, px);
    }

    fn say(self: *Quick, s: []const u8) void {
        self.notice.show(s, sys.monoMs(), notice_mod.word_ms);
        self.dirty = true;
    }

    fn onEvent(self: *Quick, ev: window.InputEvent) void {
        switch (ev) {
            .resize, .frame_done => self.dirty = true,
            .close => self.done = true,
            .pointer_motion => |m| {
                if (self.layer) self.win.setLayerKeyboard(0, if (self.win.pointer_in) .on_demand else .none) catch {};
                const h = self.hitAt(m.x, m.y);
                if (h != null and self.hover == null) self.play_from = sys.monoMs();
                if (h != self.hover) self.dirty = true;
                self.hover = h;
                if (self.press.held() == .body and !self.drag.active and self.press.dragged(m.x, m.y, self.factor())) {
                    self.press.cancel();
                    self.startDrag() catch |err| log.warn("drag failed: {t}", .{err});
                }
                self.win.setCursor(self.cursor()) catch {};
            },
            .pointer_button => |b| if (b.button == .left) {
                const h = self.hitAt(b.x, b.y);
                if (b.pressed) {
                    self.press.down(h, b.x, b.y);
                } else if (self.press.up(h)) |t| self.act(t);
                self.win.setCursor(self.cursor()) catch {};
            },
            // as on the screenshot thumbnail (quick/input.zig): only while
            // the pointer is over a layer surface
            .key => |k| if (!self.layer or self.win.pointer_in) self.onKey(k),
            else => {},
        }
    }

    /// Enter or Space opens the "Saved" link while it shows; Esc closes.
    fn onKey(self: *Quick, k: window.Key) void {
        if (self.notice.opensOn(k, sys.monoMs())) return self.act(.notice);
        if (focus.action(k, .none) == .close) self.act(.close);
    }

    /// The hand over the picture, which drags the file out (closed while
    /// pressed); the pointing hand over the "Saved" link; the arrow over
    /// the buttons.
    fn cursor(self: *const Quick) window.Cursor {
        if (self.hover == .notice) return .pointer;
        if (self.hover != .body) return .arrow;
        return window.Cursor.hand(self.press.held() == .body);
    }

    fn act(self: *Quick, c: card.Control) void {
        self.actInner(c) catch |err| {
            log.warn("{t} failed: {t}", .{ c, err });
            self.say("Failed");
        };
    }

    fn actInner(self: *Quick, c: card.Control) !void {
        switch (c) {
            .close => self.life.leave(sys.monoMs()),
            .copy => {
                try files.copyToClipboard(self.gpa, &self.win, self.info.path);
                log.info("copied {s}", .{self.info.path});
                self.say("Copied");
            },
            .save_as => {
                var bus = try desktop.connect(self.gpa, self.env);
                defer bus.deinit();
                const saved = (try files.saveAs(self.gpa, self.env, &bus, self.info.path)) orelse return;
                defer self.gpa.free(saved);
                log.info("saved to {s}", .{saved});
                self.notice.showSaved(saved, sys.monoMs());
                self.dirty = true;
            },
            // the file manager takes over: the card goes (it stays, and a
            // problem card says why, when none answered)
            .notice => {
                const path = self.notice.file(sys.monoMs()) orelse return;
                var bus: ?desktop.Bus = desktop.connect(self.gpa, self.env) catch null;
                defer if (bus) |*b| b.deinit();
                if (deliver.showInFiles(self.gpa, self.env, if (bus) |*b| b else null, path, "quick video")) self.life.leave(sys.monoMs());
            },
            .trim => {
                relaunch.trim(self.env, self.root, self.id);
                self.done = true;
            },
            .body => {},
        }
    }

    fn startDrag(self: *Quick) !void {
        const uri = try uri_mod.fileUriList(self.gpa, self.info.path);
        errdefer self.gpa.free(uri);
        const poster = try history.readFile(self.gpa, self.root, self.id, .thumb);
        try self.drag.start(&self.win, poster, uri, null);
        self.dirty = true;
        log.info("dragging {s}", .{self.info.path});
    }

    /// A finished drag closes the thumbnail; a cancelled one keeps it.
    fn checkDrag(self: *Quick) void {
        switch (self.drag.poll(&self.win) orelse return) {
            .finished => self.done = true,
            .cancelled => self.dirty = true,
        }
    }

    fn tick(self: *Quick) void {
        const now = sys.monoMs();
        if (self.life.busy(now)) self.dirty = true;
        if (self.life.gone(now)) self.done = true;
        if (self.hover == .notice) self.notice.hold(now);
        if (self.notice.expire(now)) {
            self.dirty = true;
            if (self.hover == .notice) {
                self.hover = .body;
                self.win.setCursor(self.cursor()) catch {};
            }
        }
    }

    fn open(self: *Quick) !void {
        self.layer = try floatwin.open(&self.win, .{
            .size = card.windowSize(),
            .anchor = .{ .bottom = true, .left = true },
            .margin = .{ 0, 0, 8, 8 },
            .namespace = "shotlet-quick-video",
        });
        const p = card.pad;
        try self.win.setInputRegion(0, &.{.{ .x = p, .y = p, .w = card.card_w, .h = card.card_h }});
    }
};

fn loadPng(gpa: std.mem.Allocator, root: []const u8, id: []const u8, f: history.File) !png.Image {
    const data = try history.readFile(gpa, root, id, f);
    defer gpa.free(data);
    return png.decode(gpa, data);
}

pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
    if (!history.Id.valid(id)) return error.BadId;
    const vi = keepvid.read(gpa, root, id) orelse return error.NotARecording;
    defer gpa.free(vi.buf);
    var thumb = try loadPng(gpa, root, id, .thumb);
    defer thumb.deinit(gpa);
    var strip: ?png.Image = loadPng(gpa, root, id, .strip) catch null;
    defer if (strip) |*s| s.deinit(gpa);
    var n_pics: u32 = 0;
    if (vi.info.strip.len > 0) n_pics = @intCast(std.mem.count(u8, vi.info.strip, ",") + 1);
    text.init(gpa);
    defer text.deinit();
    var q: Quick = .{
        .gpa = gpa,
        .env = env,
        .th = theme.load(gpa, env, 500),
        .win = try window.Window.init(gpa, env),
        .root = root,
        .id = id,
        .info = vi.info,
        .thumb = thumb,
        .strip = strip,
        .strip_n = n_pics,
    };
    defer q.win.deinit();
    try q.open();
    log.info("showing {s} ({d} ms)", .{ id, vi.info.duration_ms });
    while (!q.done) {
        try q.win.flush();
        var fds = [_]sys.pollfd{.{ .fd = q.win.pollFd(), .events = sys.POLL.IN, .revents = 0 }};
        _ = try sys.poll(&fds, q.win.pollTimeoutMs(if (q.hover != null or q.life.busy(sys.monoMs())) 16 else 200));
        while (try q.win.nextEventTimeout(0)) |ev| q.onEvent(ev);
        q.checkDrag();
        q.tick();
        try q.render();
    }
    q.win.closeWindow();
    if (q.win.hasClipboard()) try q.win.serveClipboard();
}
