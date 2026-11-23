//! Where a scrolling capture's frames come from, and who scrolls:
//!
//! - GNOME: the Shotlet extension's scroll session (gnome/shell1.zig):
//!   it grabs the region, and turns the wheel there itself when asked to;
//! - wlroots and KWin: direct capture of the outputs (capture/direct.zig),
//!   cropped to the region; the wheel through inject_wl.zig when the
//!   compositor offers a way, else the person scrolls.

const std = @import("std");
const capture = @import("../../../app/capture.zig");
const direct = @import("direct.zig");
const dbus = @import("../dbus.zig");
const env_mod = @import("../../../app/env.zig");
const png = @import("../../../gfx/png.zig");
const shellcap = @import("../gnome/shellcap.zig");
const geom = @import("../../../geom.zig");
const shell1 = @import("../gnome/shell1.zig");
const sys = @import("../sys.zig");
const inject = @import("../wlroots/inject.zig");

pub const Source = union(enum) {
    shell: struct { session: shell1.Scroll, auto: bool },
    direct: struct { region: geom.Rect, logical: geom.Rect, wheel: ?inject.Wheel },

    /// Whether frames come after a scroll Shotlet makes (else the person
    /// scrolls).
    pub fn scrolls(self: *const Source) bool {
        return switch (self.*) {
            .shell => |s| s.auto,
            .direct => |d| d.wheel != null,
        };
    }

    pub fn deinit(self: *Source) void {
        switch (self.*) {
            .shell => |*s| s.session.end(),
            .direct => |*d| if (d.wheel) |*w| w.deinit(),
        }
    }

    /// Scroll `clicks` notches (0: none), then the region's frame.
    pub fn grab(self: *Source, gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, clicks: i32) !png.Image {
        return switch (self.*) {
            .shell => |*s| shellFrame(gpa, env, &s.session, clicks),
            .direct => |*d| directFrame(gpa, env, bus, d.region, d.logical, if (d.wheel) |*w| w else null, clicks),
        };
    }
};

fn shellFrame(gpa: std.mem.Allocator, env: env_mod.Env, session: *shell1.Scroll, clicks: i32) !png.Image {
    var idbuf: [64]u8 = undefined;
    const id = try session.step(clicks, &idbuf);
    var pbuf: [1200]u8 = undefined;
    const data = try shellcap.readAndRemove(gpa, try shellcap.piecePath(&pbuf, env.runtime_dir, id, 0));
    defer gpa.free(data);
    return png.decode(gpa, data);
}

fn directFrame(gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, region: geom.Rect, logical: geom.Rect, wheel: ?*inject.Wheel, clicks: i32) !png.Image {
    if (wheel) |w| if (clicks > 0) {
        try w.scroll(logical.x + @divTrunc(logical.w, 2), logical.y + @divTrunc(logical.h, 2), clicks);
        sys.sleepMs(160);
    };
    var cap = switch (try direct.captureAll(gpa, env.runtime_dir, env.session.display, bus)) {
        .captured => |c| c.cap,
        .unavailable => return error.NoDirectCapture,
    };
    defer cap.deinit(gpa);
    return cap.image.crop(gpa, region) catch |err| switch (err) {
        error.OutsideImage => error.RegionOffScreen,
        else => err,
    };
}

/// Start a session for the region (image pixels of `cap`).
pub fn open(gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, cap: *const capture.Capture, region: geom.Rect, shell: bool, auto: bool) !Source {
    const l = geom.imageToLogical(cap.monitors, region) orelse return error.RegionOffScreen;
    if (shell) return .{ .shell = .{ .session = try shell1.Scroll.begin(gpa, bus, l.rect, auto), .auto = auto } };
    const wheel = if (auto) inject.Wheel.open(gpa, env.runtime_dir, env.session.display, geom.layoutBounds(cap.monitors)) catch null else null;
    return .{ .direct = .{ .region = region, .logical = l.rect, .wheel = wheel } };
}
