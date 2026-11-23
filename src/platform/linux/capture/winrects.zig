//! Where the windows were when the screen was captured, for clicking a
//! window during area selection (ui/editor/winpick.zig): their frames,
//! topmost first, in the capture's image pixels. Taken for the frozen
//! frame, never live:
//!
//! - GNOME with the Shotlet extension: it notes them in the very frame it
//!   captures; CaptureWindows(ID) hands them to the shotlet started on
//!   that capture (once, Shotlet's executable only).
//! - KWin: a one-off KWin script (winrects/kwin.zig), right after the
//!   capture, through KWin's scripting interface (no permission needed).
//! - anywhere else nothing tells a client where windows are: none, and the
//!   editor simply offers no window clicks.

const std = @import("std");
const capture = @import("../../../app/capture.zig");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const gnome = @import("../gnome.zig");
const shell1 = @import("../gnome/shell1.zig");
const kde = @import("../kde.zig");
const geom = @import("../../../app/modes/geom.zig");
const env_mod = @import("../../../app/env.zig");
const kwin = @import("../kde/winrects.zig");

/// In image pixels, as the editor takes them.
pub const Rect = @import("../../../ui/shapes.zig").Rect;

/// The most windows kept (the topmost ones).
pub const max_windows = 64;

/// The windows of capture `cap` (owned, maybe empty). `shell_id`: the
/// GNOME extension's capture id when it took the capture.
pub fn fetch(gpa: std.mem.Allocator, env: env_mod.Env, bus: *dbus.Connection, cap: *const capture.Capture, shell_id: ?[]const u8) []Rect {
    var logical: [max_windows * 4]i32 = undefined;
    const t0 = sys.monoMs();
    const flat = if (shell_id) |id| shell1.captureWindows(bus, id, &logical) else if (kde.kwinRunning(bus)) kwin.fetch(gpa, env, bus, &logical) else return &.{};
    const out = toImage(gpa, cap.monitors, flat) catch return &.{};
    std.log.info("windows: {d} where the capture was taken ({d}ms)", .{ out.len, sys.monoMs() - t0 });
    return out;
}

/// Whether a window capture (`shotlet window`) can pick a window here:
/// with the GNOME extension or on KWin (else it falls back to an area).
pub fn windowCapture(bus: *dbus.Connection) bool {
    return gnome.integrationActive(bus) or kde.kwinRunning(bus);
}

/// Logical frames to image rectangles: each over every monitor it shows
/// on (a window across two is one rectangle), off-screen ones dropped.
pub fn toImage(gpa: std.mem.Allocator, mons: []const capture.Monitor, flat: []const i32) ![]Rect {
    var list: std.ArrayList(Rect) = .empty;
    errdefer list.deinit(gpa);
    var i: usize = 0;
    while (i + 4 <= flat.len) : (i += 4) {
        const l: geom.Rect = .{ .x = flat[i], .y = flat[i + 1], .w = flat[i + 2], .h = flat[i + 3] };
        if (l.w <= 0 or l.h <= 0) continue;
        const r = spanImage(mons, l) orelse continue;
        if (r.w < 8 or r.h < 8) continue;
        try list.append(gpa, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    }
    return list.toOwnedSlice(gpa);
}

/// The union of `l`'s part on each monitor, in image pixels.
fn spanImage(mons: []const capture.Monitor, l: geom.Rect) ?geom.Rect {
    var acc: ?geom.Rect = null;
    for (mons) |m| {
        const ml = m.logical orelse continue;
        const lm: geom.Rect = .{ .x = ml.x, .y = ml.y, .w = @intCast(ml.w), .h = @intCast(ml.h) };
        const part = geom.Rect.intersect(l, lm) orelse continue;
        const px = geom.logicalToImage(&.{m}, part) orelse continue;
        acc = if (acc) |a| unite(a, px) else px;
    }
    return acc;
}

fn unite(a: geom.Rect, b: geom.Rect) geom.Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
}

const testing = std.testing;

test "window frames land in image pixels, across monitors and scales" {
    const mons = [_]capture.Monitor{
        .{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1280, .h = 720 } },
        .{ .x = 2560, .y = 0, .w = 1280, .h = 720, .logical = .{ .x = 1280, .y = 0, .w = 1280, .h = 720 } },
    };
    const flat = [_]i32{
        100, 50, 400, 300, // on the 2x monitor
        1180, 0, 200, 100, // across both
        5000, 5000, 100, 100, // nowhere
        10, 10, 2, 2, // too small to click
    };
    const out = try toImage(testing.allocator, &mons, &flat);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(Rect{ .x = 200, .y = 100, .w = 800, .h = 600 }, out[0]);
    try testing.expectEqual(Rect{ .x = 2360, .y = 0, .w = 300, .h = 200 }, out[1]);
}

test "a layout without logical positions gives no windows" {
    const mons = [_]capture.Monitor{.{ .x = 0, .y = 0, .w = 800, .h = 600 }};
    const out = try toImage(testing.allocator, &mons, &.{ 0, 0, 100, 100 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}
