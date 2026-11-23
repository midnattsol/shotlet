//! Direct capture: the desktop's own screenshot interface, no consent
//! dialog, no PipeWire. Tried before the portal (app/shot.zig):
//!
//! - wlroots compositors (sway, labwc, Hyprland, river...):
//!   ext-image-copy-capture-v1 with output capture sources when offered,
//!   else zwlr_screencopy_v1 (what grim uses). Every output into wl_shm
//!   buffers, so no GPU is needed.
//! - KDE KWin: org.kde.KWin.ScreenShot2.CaptureScreen per output. KWin only
//!   answers apps whose installed .desktop file lists the interface in
//!   X-KDE-DBUS-Restricted-Interfaces, matched by the executable: the Exec
//!   of the installed file must be the binary that runs (install.sh).
//!
//! Each output's picture is turned upright (its transform) and placed by
//! its logical rectangle (xdg_output), then stitched like the portal's
//! streams.

const std = @import("std");
const log = std.log.scoped(.capture);
const capture = @import("../../../app/capture.zig");
const geom = @import("../../../geom.zig");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const kde = @import("../kde.zig");
const kwin = @import("../kde/screenshot2.zig");

pub const Method = enum {
    ext_image_copy_capture,
    wlr_screencopy,
    kwin_screenshot,

    pub fn label(self: Method) []const u8 {
        return switch (self) {
            .ext_image_copy_capture => "ext-image-copy-capture",
            .wlr_screencopy => "wlr-screencopy",
            .kwin_screenshot => "KWin ScreenShot2",
        };
    }
};

pub const Result = union(enum) {
    captured: struct { cap: capture.Capture, method: Method },
    /// no direct interface here (or KWin refused this binary): use the portal
    unavailable: []const u8,
};

const max_outputs = @import("../../api/window.zig").max_outputs;
const Output = wl.output.Output;

const ext_source_mgr = wl.ext_output_image_capture_source_manager_v1;
const ext_source = wl.ext_image_capture_source_v1;
const ext_copy_mgr = wl.ext_image_copy_capture_manager_v1;
const ext_session = wl.ext_image_copy_capture_session_v1;
const ext_frame = wl.ext_image_copy_capture_frame_v1;
const screencopy_frame = wl.zwlr_screencopy_frame_v1;

/// A buffer to capture into: its pool's memory holds the pixels.
const Shm = struct {
    pool: wl.shm.Pool,
    buffer: u32,

    fn init(c: *wl.Connection, shm: u32, format: u32, w: u32, h: u32, stride: u32) !Shm {
        var pool: wl.shm.Pool = try .create(c, shm, @as(usize, stride) * h);
        errdefer pool.deinit(c);
        const buffer = try pool.buffer(c, 0, w, h, stride, format);
        pool.drop(c);
        return .{ .pool = pool, .buffer = buffer };
    }

    fn deinit(self: *Shm, c: *wl.Connection) void {
        c.request(self.buffer, wl.wl_buffer.destroy, &.{}) catch {};
        self.pool.deinit(c);
    }
};

const Client = struct {
    gpa: std.mem.Allocator,
    conn: wl.Connection,
    registry: u32 = 0,
    shm: u32 = 0,
    xdg_mgr: u32 = 0,
    ext_source_mgr: u32 = 0,
    ext_copy_mgr: u32 = 0,
    screencopy: u32 = 0,
    screencopy_version: u32 = 0,
    outputs: [max_outputs]Output = undefined,
    n_outputs: usize = 0,

    fn roundtrip(self: *Client) !void {
        try self.conn.roundtrip(self, handle);
    }

    fn handle(self: *Client, ev: wl.Event) !void {
        try ev.checkDisplayError();
        if (try wl.Global.of(self.registry, ev)) |g| return self.onGlobal(g);
        var r = ev.reader();
        for (self.outputs[0..self.n_outputs]) |*o| {
            if (o.id != 0 and ev.object == o.id) _ = try o.onOutput(ev.opcode, &r);
            if (o.xdg != 0 and ev.object == o.xdg) _ = try o.onXdg(ev.opcode, &r);
        }
    }

    /// A registry global: outputs are noted, the capture interfaces bound.
    fn onGlobal(self: *Client, g: wl.Global) !void {
        const c = &self.conn;
        const reg = self.registry;
        if (g.is("wl_output")) {
            if (self.n_outputs < max_outputs) {
                self.outputs[self.n_outputs] = .ofGlobal(g);
                self.n_outputs += 1;
            }
        } else if (g.is("wl_shm")) {
            self.shm = (try c.bindGlobal(reg, g, 1)).id;
        } else if (g.is("zxdg_output_manager_v1")) {
            self.xdg_mgr = (try c.bindGlobal(reg, g, 3)).id;
        } else if (g.is("ext_output_image_capture_source_manager_v1")) {
            self.ext_source_mgr = (try c.bindGlobal(reg, g, 1)).id;
        } else if (g.is("ext_image_copy_capture_manager_v1")) {
            self.ext_copy_mgr = (try c.bindGlobal(reg, g, 1)).id;
        } else if (g.is("zwlr_screencopy_manager_v1")) {
            const b = try c.bindGlobal(reg, g, 3);
            self.screencopy = b.id;
            self.screencopy_version = b.version;
        }
    }

    /// The next event of `obj`, handling the others meanwhile.
    fn next(self: *Client, obj: u32, deadline: i64) !wl.Event {
        return self.conn.waitFor(obj, deadline, self, handle);
    }

    fn shmBuffer(self: *Client, format: u32, w: u32, h: u32, stride: u32) !Shm {
        return .init(&self.conn, self.shm, format, w, h, stride);
    }

    /// Binds the registry and every output, with its xdg_output, and
    /// waits until their geometry is known.
    fn discoverOutputs(cl: *Client) !void {
        cl.registry = try cl.conn.getRegistry();
        try cl.roundtrip();
        for (cl.outputs[0..cl.n_outputs]) |*o| {
            try o.bind(&cl.conn, cl.registry);
            try o.getXdg(&cl.conn, cl.xdg_mgr);
        }
        try cl.roundtrip();
        try cl.roundtrip();
    }

    /// The best interface the compositor offers; KWin's when none.
    fn method(cl: *const Client) Method {
        return if (cl.ext_source_mgr != 0 and cl.ext_copy_mgr != 0 and cl.shm != 0)
            .ext_image_copy_capture
        else if (cl.screencopy != 0 and cl.shm != 0)
            .wlr_screencopy
        else
            .kwin_screenshot;
    }

    /// One output's picture; null when KWin refused this binary.
    fn grab(cl: *Client, o: *const Output, m: Method, bus: *dbus.Connection) !?Frame {
        return switch (m) {
            .ext_image_copy_capture => cl.grabExt(o) catch |err| {
                // a compositor may offer both and fail one: try screencopy
                if (cl.screencopy == 0) return err;
                log.info("direct capture: ext-image-copy-capture failed ({t}); wlr-screencopy", .{err});
                return try cl.grabScreencopy(o);
            },
            .wlr_screencopy => try cl.grabScreencopy(o),
            .kwin_screenshot => try kwin.screen(cl.gpa, bus, o.name()),
        };
    }

    /// One output with ext-image-copy-capture-v1.
    fn grabExt(self: *Client, o: *const Output) !Frame {
        const c = &self.conn;
        const deadline = sys.monoMs() + 5000;
        const source = c.newId();
        try c.request(self.ext_source_mgr, ext_source_mgr.create_source, &.{ .{ .new_id = source }, .{ .object = o.id } });
        defer c.request(source, ext_source.destroy, &.{}) catch {};
        const session = c.newId();
        try c.request(self.ext_copy_mgr, ext_copy_mgr.create_session, &.{ .{ .new_id = session }, .{ .object = source }, .{ .uint = 0 } });
        defer c.request(session, ext_session.destroy, &.{}) catch {};
        var w: u32 = 0;
        var h: u32 = 0;
        var format: ?u32 = null;
        while (true) {
            const ev = try self.next(session, deadline);
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                ext_session.ev_buffer_size => {
                    w = try r.uint();
                    h = try r.uint();
                },
                ext_session.ev_shm_format => format = preferFormat(format, try r.uint()),
                ext_session.ev_stopped => return error.CaptureStopped,
                ext_session.ev_done => break,
                else => {},
            }
        }
        const fmt = format orelse return error.NoShmFormat;
        if (w == 0 or h == 0) return error.BadBufferSize;
        var shm = try self.shmBuffer(fmt, w, h, w * 4);
        defer shm.deinit(c);
        const frame = c.newId();
        try c.request(session, ext_session.create_frame, &.{.{ .new_id = frame }});
        defer c.request(frame, ext_frame.destroy, &.{}) catch {};
        try c.request(frame, ext_frame.attach_buffer, &.{.{ .object = shm.buffer }});
        try c.request(frame, ext_frame.damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = @intCast(w) }, .{ .int = @intCast(h) } });
        try c.request(frame, ext_frame.capture, &.{});
        var transform: u32 = 0;
        while (true) {
            const ev = try self.next(frame, deadline);
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                ext_frame.ev_transform => transform = try r.uint() & 7,
                ext_frame.ev_failed => return error.CaptureFailed,
                ext_frame.ev_ready => break,
                else => {},
            }
        }
        return toFrame(self.gpa, shm.pool.mem, fmt, w, h, w * 4, false, transform);
    }

    /// One output with zwlr_screencopy_v1.
    fn grabScreencopy(self: *Client, o: *const Output) !Frame {
        const c = &self.conn;
        const deadline = sys.monoMs() + 5000;
        const frame = c.newId();
        try c.request(self.screencopy, wl.zwlr_screencopy_manager_v1.capture_output, &.{ .{ .new_id = frame }, .{ .int = 0 }, .{ .object = o.id } });
        defer c.request(frame, screencopy_frame.destroy, &.{}) catch {};
        // format, width, height, stride of the best shm buffer offered
        var best: ?[4]u32 = null;
        var shm: ?Shm = null;
        defer if (shm) |*s| s.deinit(c);
        var flags: u32 = 0;
        while (true) {
            const ev = try self.next(frame, deadline);
            var r: wl.ArgReader = .{ .data = ev.body };
            switch (ev.opcode) {
                screencopy_frame.ev_buffer => {
                    const b = [4]u32{ try r.uint(), try r.uint(), try r.uint(), try r.uint() };
                    const pick = preferFormat(if (best) |x| x[0] else null, b[0]);
                    if (pick != null and pick.? == b[0]) best = b;
                    // before v3 there is no buffer_done: copy right away
                    if (self.screencopy_version < 3 and shm == null) try self.copyInto(frame, &shm, best orelse return error.NoShmFormat);
                },
                screencopy_frame.ev_buffer_done => try self.copyInto(frame, &shm, best orelse return error.NoShmFormat),
                screencopy_frame.ev_flags => flags = try r.uint(),
                screencopy_frame.ev_failed => return error.CaptureFailed,
                screencopy_frame.ev_ready => {
                    const b = best.?;
                    return toFrame(self.gpa, shm.?.pool.mem, b[0], b[1], b[2], b[3], flags & screencopy_frame.flag_y_invert != 0, o.transform);
                },
                else => {},
            }
        }
    }

    fn copyInto(self: *Client, frame: u32, shm: *?Shm, b: [4]u32) !void {
        if (shm.* != null) return;
        shm.* = try self.shmBuffer(b[0], b[1], b[2], b[3]);
        try self.conn.request(frame, screencopy_frame.copy, &.{.{ .object = shm.*.?.buffer }});
        try self.conn.flush();
    }
};

const pixels = @import("direct/pixels.zig");
pub const Frame = pixels.Frame;
pub const fmt_argb8888 = pixels.fmt_argb8888;
pub const fmt_xrgb8888 = pixels.fmt_xrgb8888;
pub const fmt_abgr8888 = pixels.fmt_abgr8888;
pub const fmt_xbgr8888 = pixels.fmt_xbgr8888;
pub const fmt_argb2101010 = pixels.fmt_argb2101010;
pub const fmt_xrgb2101010 = pixels.fmt_xrgb2101010;
pub const fmt_abgr2101010 = pixels.fmt_abgr2101010;
pub const fmt_xbgr2101010 = pixels.fmt_xbgr2101010;
pub const convert = pixels.convert;
const preferFormat = pixels.preferFormat;
const toFrame = pixels.toFrame;

comptime {
    _ = pixels;
}

/// Capture every output directly. `bus` is used for KWin.
pub fn captureAll(gpa: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, bus: *dbus.Connection) !Result {
    var cl: Client = .{ .gpa = gpa, .conn = try wl.Connection.connect(gpa, runtime_dir, display) };
    defer cl.conn.deinit();
    try cl.discoverOutputs();
    if (cl.n_outputs == 0) return .{ .unavailable = "no outputs" };
    const method = cl.method();

    var frames: [max_outputs]Frame = undefined;
    var n: usize = 0;
    defer for (frames[0..n]) |f| gpa.free(f.pixels);
    var parts: [max_outputs]capture.Part = undefined;
    for (cl.outputs[0..cl.n_outputs]) |*o| {
        frames[n] = (try cl.grab(o, method, bus)) orelse return .{ .unavailable = kwin.refused };
        parts[n] = .{ .pixels = frames[n].pixels, .width = frames[n].width, .height = frames[n].height, .logical = logicalOf(o) };
        log.debug("direct capture: {s} {d}x{d} at {any}", .{ o.name(), frames[n].width, frames[n].height, parts[n].logical });
        n += 1;
    }
    log.info("direct capture: {d} outputs with {s}", .{ n, method.label() });
    return .{ .captured = .{ .cap = try capture.stitch(gpa, parts[0..n]), .method = method } };
}

/// The direct interface a capture would use now, without capturing;
/// null when there is none (the portal then). KWin counts when it is on
/// the bus, though it may still refuse this binary.
pub fn probe(gpa: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, bus: *dbus.Connection) ?Method {
    var cl: Client = .{ .gpa = gpa, .conn = wl.Connection.connect(gpa, runtime_dir, display) catch return null };
    defer cl.conn.deinit();
    cl.registry = cl.conn.getRegistry() catch return null;
    cl.roundtrip() catch return null;
    const m = cl.method();
    if (m != .kwin_screenshot) return m;
    return if (kde.kwinRunning(bus)) m else null;
}

/// Where an output's picture goes in the stitched capture (at least 1x1).
fn logicalOf(o: *const Output) geom.Rect {
    const r = o.logicalRect();
    return .{ .x = r.x, .y = r.y, .w = @max(1, r.w), .h = @max(1, r.h) };
}
