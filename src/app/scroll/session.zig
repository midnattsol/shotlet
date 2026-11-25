//! One scrolling capture, from the first frame to the tall image: frames
//! are grabbed (after a scroll when Shotlet turns the wheel) and stitched
//! while the control (ui/scroll_hud.zig) shows the image growing. Every
//! stop has a reason (stop.zig), logged and shown in plain words:
//!
//! - natural (the end of the page, the height limit, Stop): the image is
//!   complete; the control says why for a moment, then the editor opens;
//! - short (the page didn't move, the next part didn't line up, the
//!   frames stopped coming): it pauses with Continue, Finish and Cancel.
//!   Continue picks up from where it stopped, keeping what is stitched:
//!   it tries the wheel again, lets the person scroll back until the
//!   parts line up, or starts the frame source over.
//!
//! A frame takes a while (the shell paints and encodes the region, then
//! it is decoded), and stitching it takes a while more: all of it runs on
//! a worker thread (offload.zig) while the control keeps answering its
//! input and the compositor's pings (else GNOME offers to force quit
//! Shotlet), and makes its preview of the image beside the next frame.

const std = @import("std");
const log = std.log.scoped(.scrolling_capture);
const capture = @import("../capture.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/api.zig").sys;
const geom = @import("../../geom.zig");
const flow = @import("../modes/flow.zig");
const hud_mod = @import("../../ui/scroll_hud.zig");
const stitch = @import("stitch.zig");
const stop = @import("stop.zig");
const offload = @import("offload.zig");
const pace_mod = @import("pace.zig");
const platform_capture = @import("../../platform/api.zig").capture;

/// What (re)opens the frame source.
pub const Opener = struct {
    cap: *const capture.Capture,
    region: geom.Rect,
    shell: bool,
    auto: bool,
};

pub const Session = struct {
    c: flow.Ctx,
    hud: *hud_mod.Hud,
    opener: Opener,
    max_height: u32,
    src: ?platform_capture.ScrollSource = null,
    st: ?stitch.Stitcher = null,
    watch: stop.Watch,
    /// wheel notches per step, from how far a notch moved (pace.zig)
    pace: pace_mod.Pace = .{},
    /// after Continue from no_match: the person scrolls back (no wheel)
    /// until the parts line up again
    realign: bool = false,
    /// a warning is up (the person scrolled past what lines up)
    warned: bool = false,
    /// what the person asked for on the control while a frame came
    asked: ?hud_mod.Action = null,
    /// the image grew since the control's preview was made
    preview_due: bool = false,
    /// why it ended by itself, for the editor to say
    note: stop.Note = .{},

    pub fn init(c: flow.Ctx, hud: *hud_mod.Hud, opener: Opener, max_height: u32) !Session {
        var self: Session = .{ .c = c, .hud = hud, .opener = opener, .max_height = max_height, .watch = .{ .auto = false } };
        const src = try self.open();
        self.watch.auto = src.scrolls();
        log.info("{s}, {s}", .{ @tagName(src.*), if (src.scrolls()) "Shotlet scrolls" else "the person scrolls" });
        return self;
    }

    pub fn deinit(self: *Session) void {
        if (self.src) |*s| s.deinit();
        self.src = null;
    }

    fn open(self: *Session) !*platform_capture.ScrollSource {
        const o = self.opener;
        self.src = try platform_capture.openScroll(self.c.gpa, self.c.env, self.c.bus, o.cap, o.region, o.shell, o.auto);
        return &self.src.?;
    }

    /// The source over again (its session timed out, it failed).
    fn reopen(self: *Session) !*platform_capture.ScrollSource {
        self.deinit();
        return self.open();
    }

    /// Shotlet turns the wheel now.
    fn wheel(self: *const Session) bool {
        return !self.realign and self.opener.auto and if (self.src) |*s| s.scrolls() else false;
    }

    fn rowOf(ctx: *const anyopaque, y: u32) []const u32 {
        const st: *const stitch.Stitcher = @ptrCast(@alignCast(ctx));
        return st.row(y);
    }

    fn total(self: *const Session) u32 {
        return if (self.st) |*s| s.totalHeight() else 0;
    }

    /// A frame; when the source fails, once more from a new source (the
    /// extension ends a session left idle).
    fn grab(self: *Session, clicks: i32) !png.Image {
        if (self.src) |*s| {
            if (self.grabOn(s, clicks)) |f| return f else |err| log.info("no frame ({t}), starting the source again", .{err});
        }
        const s = try self.reopen();
        return self.grabOn(s, 0);
    }

    /// One frame of `src` on a worker thread; the control answers
    /// meanwhile.
    fn grabOn(self: *Session, src: *platform_capture.ScrollSource, clicks: i32) !png.Image {
        return offload.run(self, grabFrame, .{ src, self.c, clicks });
    }

    fn grabFrame(src: *platform_capture.ScrollSource, c: flow.Ctx, clicks: i32) !png.Image {
        return src.grab(c.gpa, c.env, c.bus, clicks);
    }

    fn startStitch(gpa: std.mem.Allocator, first: png.Image, max_height: u32) !stitch.Stitcher {
        return stitch.Stitcher.init(gpa, frameOf(first), max_height);
    }

    /// Stitch frame `f` in on a worker thread; the control's preview is
    /// due when the image grew.
    fn push(self: *Session, f: png.Image) !stitch.Push {
        self.preview_due = false;
        const r = try offload.run(self, stitch.Stitcher.push, .{ &self.st.?, frameOf(f) });
        self.preview_due = r == .appended or r == .full;
        return r;
    }

    /// The control's preview of the image so far, when it is due.
    fn updatePreview(self: *Session) void {
        if (!self.preview_due) return;
        self.preview_due = false;
        const st = &self.st.?;
        if (hud_mod.Preview.make(self.c.gpa, self.hud.previewRect(), .{ .ctx = st, .width = st.outWidth(), .height = st.totalHeight(), .row = rowOf })) |p| self.hud.setPreview(p);
    }

    /// The control for up to `ms`: drawn, its input read (an action is
    /// kept for the capture loop). Called beside the worker: a due preview
    /// reads the stitcher, which no worker has then (push clears it).
    pub fn pump(self: *Session, ms: i32) !void {
        self.updatePreview();
        try self.hud.draw();
        if (try self.hud.poll(ms)) |a| {
            if (self.asked == null) self.asked = a;
        }
    }

    /// `ms` without a frame, the control answering.
    fn wait(self: *Session, ms: i64) !void {
        const until_ms = sys.monoMs() + ms;
        while (sys.monoMs() < until_ms) try self.pump(@intCast(@max(1, @min(10, until_ms - sys.monoMs()))));
    }

    /// The region once nothing moves in it any more (the picker's fade,
    /// a repaint under load), at most about two seconds on. A blinking
    /// cursor or a spinner does not count as moving (stitch.still).
    fn settled(self: *Session) !png.Image {
        return self.settledFrom(try self.grab(0));
    }

    /// settled, from a frame already taken (now its own to free).
    fn settledFrom(self: *Session, first: png.Image) !png.Image {
        var a = first;
        errdefer a.deinit(self.c.gpa);
        for (0..12) |_| {
            try self.wait(60);
            const b = try self.grab(0);
            const same = a.width == b.width and a.height == b.height and
                try stitch.still(self.c.gpa, frameOf(a), frameOf(b));
            a.deinit(self.c.gpa);
            a = b;
            if (same) break;
        }
        return a;
    }

    fn frameOf(i: png.Image) stitch.Frame {
        return .{ .pixels = i.pixels, .width = i.width, .height = i.height };
    }

    /// The tall image; null when cancelled.
    pub fn collect(self: *Session) !?png.Image {
        var first = try self.settled();
        defer first.deinit(self.c.gpa);
        self.watch.min_move = first.height / 8;
        self.st = try offload.run(self, startStitch, .{ self.c.gpa, first, self.max_height });
        defer self.st.?.deinit();
        self.preview_due = true;
        self.showRunning();
        _ = (try self.until()) orelse return null;
        const out = try self.st.?.result();
        log.info("{d}x{d}", .{ out.width, out.height });
        return .{ .width = out.width, .height = out.height, .pixels = @constCast(out.pixels) };
    }

    /// Scroll, pause and continue until the capture is complete: why it
    /// ended, or null when cancelled.
    fn until(self: *Session) !?stop.Reason {
        while (true) {
            const why = (try self.scrolling()) orelse return cancelled();
            var buf: [96]u8 = undefined;
            const msg = why.message(&buf, self.max_height);
            log.info("stopped: {t} ({s}) at {d} px", .{ why, msg, self.total() });
            if (why.natural()) {
                if (why != .user_stopped) {
                    if (try self.cancelAsked()) return cancelled();
                    self.note.set(msg);
                }
                return why;
            }
            switch (try self.paused(msg)) {
                .finish => {
                    log.info("finished after {t}", .{why});
                    return why;
                },
                .cancel => return cancelled(),
                .@"continue" => self.carryOn(why),
            }
        }
    }

    fn cancelled() ?stop.Reason {
        log.info("cancelled", .{});
        return null;
    }

    /// Frames until something stops it; null when cancelled.
    fn scrolling(self: *Session) !?stop.Reason {
        while (true) {
            try self.hud.draw();
            const asked = self.asked;
            self.asked = null;
            if (asked orelse try self.hud.poll(if (self.wheel()) 1 else 120)) |a| switch (a) {
                .finish => return .user_stopped,
                .cancel => return null,
                .@"continue" => {},
            };
            if (try self.step()) |why| return why;
        }
    }

    /// Paused: wait for Continue, Finish or Cancel.
    fn paused(self: *Session, msg: []const u8) !hud_mod.Action {
        // (a click meant for the running control is not an answer here)
        self.asked = null;
        self.hud.showMessage(.paused, msg, self.total());
        while (true) {
            try self.hud.draw();
            if (try self.hud.poll(100)) |a| return a;
        }
    }

    /// A natural stop opens the editor at once, which says why (`note`):
    /// only what was already asked of the control can still cancel.
    fn cancelAsked(self: *Session) !bool {
        const a = self.asked orelse (try self.hud.poll(1)) orelse return false;
        return a == .cancel;
    }

    /// Continue after a short stop, keeping what is stitched.
    fn carryOn(self: *Session, why: stop.Reason) void {
        log.info("continuing after {t}", .{why});
        self.watch.restart();
        switch (why) {
            .didnt_move => self.pace.restart(),
            .no_match => if (self.opener.auto) {
                self.realign = true;
            },
            .lost => if (self.reopen()) |_| {} else |err| log.warn("{t}", .{err}),
            else => {},
        }
        self.watch.auto = self.wheel();
        self.showRunning();
    }

    fn showRunning(self: *Session) void {
        const h = self.total();
        if (self.realign) return self.hud.show(.warning, "Scroll back up a little", "It carries on once the parts line up", h);
        if (self.wheel()) return self.hud.show(.running, "Scrolling\u{2026}", "", h);
        const moved = self.watch.moved;
        self.hud.show(.running, if (moved) "Keep scrolling" else "Scroll the page now", "Stop when you reach the end", h);
    }

    /// One frame: why it stops, or null to go on.
    fn step(self: *Session) !?stop.Reason {
        const clicks: i32 = if (self.wheel()) self.pace.clicks else 0;
        var f = self.grab(clicks) catch |err| {
            log.warn("no frame: {t}", .{err});
            return .lost;
        };
        defer f.deinit(self.c.gpa);
        const st = &self.st.?;
        var r = self.push(f) catch |err| {
            log.warn("{t}", .{err});
            return .lost;
        };
        if (self.watch.lookAgain(r, clicks)) r = self.recheck(r) catch return .lost;
        switch (self.watch.feed(r, clicks)) {
            .go => {},
            .slower => {
                log.info("moved too far ({d} notches)", .{clicks});
                self.pace.tooFar();
            },
            .warn => |why| if (!self.warned and !self.realign) {
                self.warned = true;
                var buf: [96]u8 = undefined;
                const msg = why.message(&buf, self.max_height);
                log.info("warning: {t} ({s})", .{ why, msg });
                self.hud.showMessage(.warning, msg, st.totalHeight());
            },
            .stop => |why| return why,
        }
        if (r == .appended) self.appended(r.appended, f.height);
        return null;
    }

    /// The region again, without scrolling: what it does now (`was` when
    /// it still has not moved).
    fn recheck(self: *Session, was: stitch.Push) !stitch.Push {
        try self.wait(150);
        var f = try self.grab(0);
        if (was == .unchanged and self.st.?.isLast(frameOf(f))) {
            f.deinit(self.c.gpa);
            return was;
        }
        f = try self.settledFrom(f);
        defer f.deinit(self.c.gpa);
        const r = try self.push(f);
        return if (r == .unchanged) was else r;
    }

    fn appended(self: *Session, d: u32, h: u32) void {
        if (self.warned or self.realign) log.info("lined up again", .{});
        self.warned = false;
        if (self.realign) {
            // lined up again: back to the wheel, carefully
            self.realign = false;
            self.pace.clicks = 1;
            self.watch.auto = self.wheel();
        } else if (self.wheel()) self.pace.moved(d, h);
        self.showRunning();
    }
};
