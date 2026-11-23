//! Turning the wheel for a scrolling capture on wlroots compositors
//! (zwlr_virtual_pointer_v1) and on KWin when it lets Shotlet use its
//! fake input (org_kde_kwin_fake_input, offered only to clients KWin
//! trusts). Used only while the scrolling capture runs: the pointer goes
//! to the middle of the region and the wheel turns there; destroyed with
//! the session. Without either, the person scrolls by hand.

const std = @import("std");
const wl = @import("../wayland.zig");
const sys = @import("../sys.zig");
const geom = @import("../../../app/modes/geom.zig");

const vp_mgr = wl.zwlr_virtual_pointer_manager_v1;
const vp = wl.zwlr_virtual_pointer_v1;
const fake = wl.org_kde_kwin_fake_input;

pub const Wheel = struct {
    conn: wl.Connection,
    seat: u32 = 0,
    vp_mgr: u32 = 0,
    fake: u32 = 0,
    fake_version: u32 = 0,
    pointer: u32 = 0,
    registry: u32 = 0,
    /// the layout's bounding box (logical), for absolute motion
    box: geom.Rect,

    /// Null when the compositor offers no way to scroll for us.
    pub fn open(gpa: std.mem.Allocator, runtime_dir: []const u8, display: []const u8, box: geom.Rect) !?Wheel {
        var self: Wheel = .{ .conn = try wl.Connection.connect(gpa, runtime_dir, display), .box = box };
        errdefer self.conn.deinit();
        self.registry = try self.conn.getRegistry();
        try self.conn.roundtrip(&self, onEvent);
        if (self.vp_mgr != 0 and self.seat != 0) {
            self.pointer = self.conn.newId();
            try self.conn.request(self.vp_mgr, vp_mgr.create_virtual_pointer, &.{ .{ .object = self.seat }, .{ .new_id = self.pointer } });
        } else if (self.fake != 0 and self.fake_version >= 3) {
            try self.conn.request(self.fake, fake.authenticate, &.{ .{ .string = "Shotlet" }, .{ .string = "scrolling capture" } });
        } else {
            self.conn.deinit();
            return null;
        }
        try self.conn.flush();
        return self;
    }

    /// Registry globals: the seat and the two ways to scroll.
    fn onEvent(self: *Wheel, ev: wl.Event) !void {
        try ev.checkDisplayError();
        const g = try wl.Global.of(self.registry, ev) orelse return;
        const c = &self.conn;
        if (g.is("wl_seat") and self.seat == 0) {
            self.seat = (try c.bindGlobal(self.registry, g, 1)).id;
        } else if (g.is("zwlr_virtual_pointer_manager_v1")) {
            self.vp_mgr = (try c.bindGlobal(self.registry, g, 1)).id;
        } else if (g.is("org_kde_kwin_fake_input")) {
            const b = try c.bindGlobal(self.registry, g, 4);
            self.fake = b.id;
            self.fake_version = b.version;
        }
    }

    pub fn deinit(self: *Wheel) void {
        if (self.pointer != 0) self.conn.request(self.pointer, vp.destroy, &.{}) catch {};
        self.conn.flush() catch {};
        self.conn.deinit();
    }

    /// Point at (x, y) (logical) and turn the wheel `clicks` notches down.
    pub fn scroll(self: *Wheel, x: i32, y: i32, clicks: i32) !void {
        const t: u32 = @truncate(@as(u64, @intCast(sys.monoMs())));
        const v: f64 = @floatFromInt(clicks * 15);
        if (self.pointer != 0) {
            try self.conn.request(self.pointer, vp.motion_absolute, &.{
                .{ .uint = t },
                .{ .uint = @intCast(@max(0, x - self.box.x)) },
                .{ .uint = @intCast(@max(0, y - self.box.y)) },
                .{ .uint = @intCast(self.box.w) },
                .{ .uint = @intCast(self.box.h) },
            });
            try self.conn.request(self.pointer, vp.frame, &.{});
            try self.conn.request(self.pointer, vp.axis_source, &.{.{ .uint = 0 }});
            try self.conn.request(self.pointer, vp.axis_discrete, &.{ .{ .uint = t }, .{ .uint = 0 }, .{ .fixed = v }, .{ .int = clicks } });
            try self.conn.request(self.pointer, vp.frame, &.{});
        } else {
            try self.conn.request(self.fake, fake.pointer_motion_absolute, &.{ .{ .fixed = @floatFromInt(x) }, .{ .fixed = @floatFromInt(y) } });
            try self.conn.request(self.fake, fake.axis, &.{ .{ .uint = 0 }, .{ .fixed = v } });
        }
        try self.conn.flush();
    }
};
