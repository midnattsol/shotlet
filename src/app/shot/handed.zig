//! A capture the GNOME integration handed over, loaded on a thread of
//! its own from the very start of the run: the shell may still be
//! writing its pieces (its frozen frame is up meanwhile), so waiting for
//! and decoding them overlaps connecting to the session, loading the
//! settings and fonts and opening the display. The frozen frame is
//! given back (api.shell.unfreeze) once Shotlet shows the capture, or
//! as soon as it knows it never will.

const std = @import("std");
const log = std.log.scoped(.capture);
const platform = @import("../../platform/api.zig");
const capture = @import("../capture.zig");
const env_mod = @import("../env.zig");
const sys = platform.sys;
const shell = platform.shell;

const Env = env_mod.Env;

/// What the editor's surfaces need of a handed capture's layout
/// ("x,y,w,h,scale;..."): how many monitors, where the first one is.
pub const Layout = struct { monitors: usize, x: i32, y: i32 };

pub fn layoutOf(monitors: []const u8) ?Layout {
    var l: Layout = .{ .monitors = 0, .x = 0, .y = 0 };
    var it = std.mem.tokenizeScalar(u8, monitors, ';');
    while (it.next()) |item| {
        if (l.monitors == 0) {
            var f = std.mem.splitScalar(u8, item, ',');
            l.x = std.fmt.parseInt(i32, f.next() orelse return null, 10) catch return null;
            l.y = std.fmt.parseInt(i32, f.next() orelse return null, 10) catch return null;
        }
        l.monitors += 1;
    }
    return if (l.monitors == 0) null else l;
}

test "the layout's monitors and the first one's place" {
    try std.testing.expectEqual(Layout{ .monitors = 2, .x = 0, .y = 0 }, layoutOf("0,0,1728,1080,2;1728,0,2560,1440,1.5").?);
    try std.testing.expectEqual(Layout{ .monitors = 1, .x = -1712, .y = 5 }, layoutOf("-1712,5,1712,963,1.4953;").?);
    try std.testing.expect(layoutOf("") == null);
    try std.testing.expect(layoutOf("x,0,1,1,1") == null);
}

pub const Loader = struct {
    gpa: std.mem.Allocator = undefined,
    env: Env = undefined,
    args: shell.HandedCapture = .{ .id = "" },
    thread: ?std.Thread = null,
    result: anyerror!capture.Capture = error.NotStarted,
    /// how long waiting for, decoding and stitching the pieces took
    took_ms: i64 = 0,
    taken: bool = false,

    /// Start loading `args` (when there is a handed capture).
    pub fn start(self: *Loader, gpa: std.mem.Allocator, env: Env, args: ?shell.HandedCapture) void {
        const a = args orelse return;
        self.* = .{ .gpa = gpa, .env = env, .args = a };
        self.thread = std.Thread.spawn(.{}, work, .{self}) catch null;
        if (self.thread == null) self.work();
    }

    fn work(self: *Loader) void {
        const t = sys.monoMs();
        self.result = shell.loadHanded(self.gpa, self.env, self.args);
        self.took_ms = sys.monoMs() - t;
    }

    /// The capture, once loaded (owned by the caller from then on).
    pub fn take(self: *Loader) !capture.Capture {
        if (self.thread) |th| th.join();
        self.thread = null;
        self.taken = true;
        const cap = try self.result;
        log.info("capture detail: monitors={d} through the GNOME integration (wait+decode+stitch {d}ms)", .{ cap.monitors.len, self.took_ms });
        return cap;
    }

    /// The run ends: a capture never taken is freed (after its thread).
    pub fn deinit(self: *Loader) void {
        if (self.thread) |th| th.join();
        self.thread = null;
        if (self.taken) return;
        if (self.result) |*cap| cap.deinit(self.gpa) else |_| {}
    }
};
