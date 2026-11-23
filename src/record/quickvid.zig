//! `shotlet quick-video ROOT ID`: the floating thumbnail of a finished
//! recording, in the bottom-left corner like the screenshot thumbnail
//! (a layer-shell surface, or a "shotlet:quick" window the GNOME Shell
//! extension places). Hovering plays the filmstrip; Copy puts the file on
//! the clipboard (text/uri-list, and the video itself as video/mp4 or
//! image/gif); Save as… copies it elsewhere; the scissors open the trim
//! window; dragging it drops the file into another app. It fades in and
//! stays until closed: a recording is not glanced at like a screenshot.

const std = @import("std");
const transfer = @import("../ui/transfer.zig");
const desktop = @import("../platform/api.zig").desktop;
const env_mod = @import("../app/env.zig");
const history = @import("../app/history.zig");
const keep = @import("../app/keep.zig");
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
    notice: []const u8 = "",
    notice_until: i64 = 0,
    play_from: i64 = 0,
    dirty: bool = true,
    drag: fui.DragOut = .{},
    done: bool = false,

    fn factor(self: *const Quick) f64 {
        return scale.of(self.win.scale120);
    }

    /// What is under a pointer at x, y (buffer pixels).
    fn hitAt(self: *const Quick, x: f64, y: f64) ?card.Control {
        const k = self.factor();
        return card.hit(scale.toLogical(x, k), scale.toLogical(y, k));
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
            .notice = if (now < self.notice_until) self.notice else "",
            .alpha = alpha,
            .th = self.th,
        });
        try floatwin.presentStraight(&self.win, px);
    }

    fn say(self: *Quick, s: []const u8) void {
        self.notice = s;
        self.notice_until = sys.monoMs() + 1200;
        self.dirty = true;
    }

    fn onEvent(self: *Quick, ev: window.InputEvent) void {
        switch (ev) {
            .resize, .frame_done => self.dirty = true,
            .close => self.done = true,
            .pointer_motion => |m| {
                const h = self.hitAt(m.x, m.y);
                if (h != null and self.hover == null) self.play_from = sys.monoMs();
                if (h != self.hover) self.dirty = true;
                self.hover = h;
                if (self.press.held() == .body and !self.drag.active and self.press.dragged(m.x, m.y, self.factor())) {
                    self.press.cancel();
                    self.startDrag() catch |err| std.log.warn("quick video: drag failed: {t}", .{err});
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
            else => {},
        }
    }

    /// The hand over the picture, which drags the file out (closed while
    /// pressed); the arrow over the buttons.
    fn cursor(self: *const Quick) window.Cursor {
        if (self.hover != .body) return .arrow;
        return window.Cursor.hand(self.press.held() == .body);
    }

    fn act(self: *Quick, c: card.Control) void {
        self.actInner(c) catch |err| {
            std.log.warn("quick video: {t} failed: {t}", .{ c, err });
            self.say("Failed");
        };
    }

    fn actInner(self: *Quick, c: card.Control) !void {
        switch (c) {
            .close => self.life.leave(sys.monoMs()),
            .copy => {
                try files.copyToClipboard(self.gpa, &self.win, self.info.path);
                std.log.info("quick video: copied {s}", .{self.info.path});
                self.say("Copied");
            },
            .save_as => {
                var bus = try desktop.connect(self.gpa, self.env);
                defer bus.deinit();
                const saved = (try files.saveAs(self.gpa, self.env, &bus, self.info.path)) orelse return;
                defer self.gpa.free(saved);
                std.log.info("quick video: saved to {s}", .{saved});
                self.say("Saved");
            },
            .trim => {
                var rb: [1100]u8 = undefined;
                var ib: [40]u8 = undefined;
                const r = try std.fmt.bufPrintSentinel(&rb, "{s}", .{self.root}, 0);
                const i = try std.fmt.bufPrintSentinel(&ib, "{s}", .{self.id}, 0);
                keep.spawnSelf(self.env, &.{ "trim", r.ptr, i.ptr });
                self.done = true;
            },
            .body => {},
        }
    }

    fn startDrag(self: *Quick) !void {
        const uri = try transfer.fileUriList(self.gpa, self.info.path);
        errdefer self.gpa.free(uri);
        var pbuf: [1200]u8 = undefined;
        const poster = try sys.readFileAlloc(self.gpa, try history.entryPath(&pbuf, self.root, self.id, "thumb.png"), 64 * 1024 * 1024);
        try self.drag.start(&self.win, poster, uri, null);
        self.dirty = true;
        std.log.info("quick video: dragging {s}", .{self.info.path});
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
        if (self.notice_until != 0 and now >= self.notice_until) {
            self.notice_until = 0;
            self.dirty = true;
        }
    }

    fn open(self: *Quick) !void {
        _ = try floatwin.open(&self.win, .{
            .size = card.windowSize(),
            .anchor = .{ .bottom = true, .left = true },
            .margin = .{ 0, 0, 8, 8 },
            .namespace = "shotlet-quick-video",
        });
        const p = card.pad;
        try self.win.setInputRegion(0, &.{.{ .x = p, .y = p, .w = card.card_w, .h = card.card_h }});
    }
};

fn loadPng(gpa: std.mem.Allocator, root: []const u8, id: []const u8, name: []const u8) !png.Image {
    var pbuf: [1200]u8 = undefined;
    const data = try sys.readFileAlloc(gpa, try history.entryPath(&pbuf, root, id, name), 64 * 1024 * 1024);
    defer gpa.free(data);
    return png.decode(gpa, data);
}

pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8) !void {
    if (!history.Id.valid(id)) return error.BadId;
    const vi = keepvid.read(gpa, root, id) orelse return error.NotARecording;
    defer gpa.free(vi.buf);
    var thumb = try loadPng(gpa, root, id, "thumb.png");
    defer thumb.deinit(gpa);
    var strip: ?png.Image = loadPng(gpa, root, id, "strip.png") catch null;
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
    std.log.info("quick video: showing {s} ({d} ms)", .{ id, vi.info.duration_ms });
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
