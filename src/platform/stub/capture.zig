//! The capture seam of the contract: every monitor frozen (asking for
//! permission where the platform does), the windows' frames for
//! click-a-window, window capture, frames for a scrolling capture, and
//! the permissions captures keep.

const std = @import("std");
const types = @import("../api/capture.zig");
const desktop = @import("desktop.zig");
const capture = @import("../../app/capture.zig");
const config = @import("../../app/config.zig");
const mode = @import("../../app/modes/mode.zig");
const geom = @import("../../geom.zig");
const png = @import("../../gfx/png.zig");
const Env = @import("../../app/env.zig").Env;

pub const Path = types.Path;
pub const ScrollSupport = types.ScrollSupport;
pub const PermissionsCli = types.PermissionsCli;

/// Remember how the last capture went.
pub fn remember(home: []const u8, p: Path) void {
    _ = .{ home, p };
}
/// How the last capture went, if known.
pub fn lastPath(home: []const u8) ?Path {
    _ = home;
    return null;
}
/// Load what the first capture needs ahead, on a thread of the caller's.
pub fn warmup() void {}

/// Every monitor, frozen. Null when the person cancelled.
pub fn screens(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, cfg: *config.Config) error{Unavailable}!?capture.Capture {
    _ = .{ gpa, env, bus, cfg };
    return error.Unavailable;
}

pub const max_windows = 64;
/// The windows' frames when `cap` was taken (image pixels, owned).
pub fn windows(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, cap: *const capture.Capture, shell_id: ?[]const u8) []geom.Rect {
    _ = .{ gpa, env, bus, cap, shell_id };
    return &.{};
}
/// Whether a window's own pixels can be captured here.
pub fn canCaptureWindow(bus: *desktop.Bus) bool {
    _ = bus;
    return false;
}
/// Window capture without the shell integration: true when it handled it.
pub fn captureWindow(gpa: std.mem.Allocator, env: Env, req: mode.Request) error{Unavailable}!bool {
    _ = .{ gpa, env, req };
    return false;
}

/// Frames of a region for a scrolling capture, and who scrolls.
pub const ScrollSource = union(enum) {
    none,

    /// Whether frames come after a scroll Shotlet makes.
    pub fn scrolls(self: *const ScrollSource) bool {
        _ = self;
        return false;
    }
    pub fn deinit(self: *ScrollSource) void {
        _ = self;
    }
    /// Scroll `clicks` notches (0: none), then the region's frame.
    pub fn grab(self: *ScrollSource, gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, clicks: i32) error{Unavailable}!png.Image {
        _ = .{ self, gpa, env, bus, clicks };
        return error.Unavailable;
    }
};
/// Whether a scrolling capture can run here (before a region is picked).
pub fn scrollSupport(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus) ScrollSupport {
    _ = .{ gpa, env, bus };
    return .unsupported;
}
pub fn openScroll(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus, cap: *const capture.Capture, region: geom.Rect, shell: bool, auto: bool) error{Unavailable}!ScrollSource {
    _ = .{ gpa, env, bus, cap, region, shell, auto };
    return error.Unavailable;
}

pub const ResetOutcome = struct {};
/// Forget the permissions captures keep; with `dry_run` only find them.
pub fn resetPermissions(arena: std.mem.Allocator, env: Env, bus: ?*desktop.Bus, dry_run: bool) ResetOutcome {
    _ = .{ arena, env, bus, dry_run };
    return .{};
}
/// A short line about a reset.
pub fn resetSummary(o: ResetOutcome, buf: []u8) []const u8 {
    _ = .{ o, buf };
    return "";
}
/// `shotlet permissions [reset [--dry-run]]`.
pub fn permissionsCli(gpa: std.mem.Allocator, env: Env, cmd: PermissionsCli) error{Unavailable}!void {
    _ = .{ gpa, env, cmd };
    return error.Unavailable;
}
