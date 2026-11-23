//! The recorded area (a geom.Rect in the compositor's logical layout;
//! geom.toFramePixels maps it onto a stream's pixels): the monitor that
//! holds it, and the encoded size (even for H.264, scaled down to the
//! maximum width for GIFs).

const std = @import("std");
const Rect = @import("../geom.zig").Rect;

/// H.264 4:2:0 wants even sizes: drop the odd last row or column.
pub fn evenSize(w: u32, h: u32) [2]u32 {
    return .{ @max(2, w & ~@as(u32, 1)), @max(2, h & ~@as(u32, 1)) };
}

/// A GIF no wider than `max_w` (0: no limit), keeping the shape.
pub fn gifSize(w: u32, h: u32, max_w: u32) [2]u32 {
    if (max_w == 0 or w <= max_w) return .{ w, h };
    const nh: u32 = @intCast(@max(1, (@as(u64, h) * max_w + w / 2) / w));
    return .{ max_w, nh };
}

/// The monitor (index into `mons`) holding most of `region`.
pub fn bestMonitor(region: Rect, mons: []const Rect) ?usize {
    var best: ?usize = null;
    var best_area: i64 = 0;
    for (mons, 0..) |m, i| {
        const a = if (region.intersect(m)) |r| r.area() else 0;
        if (a > best_area) {
            best_area = a;
            best = i;
        }
    }
    return best;
}

test "sizes for the encoders" {
    try std.testing.expectEqual([2]u32{ 640, 358 }, evenSize(641, 359));
    try std.testing.expectEqual([2]u32{ 2, 2 }, evenSize(1, 1));
    try std.testing.expectEqual([2]u32{ 800, 450 }, gifSize(1600, 900, 800));
    try std.testing.expectEqual([2]u32{ 300, 200 }, gifSize(300, 200, 800));
}

test "a region picks its monitor" {
    const mons = [_]Rect{ .{ .x = 0, .y = 0, .w = 1600, .h = 900 }, .{ .x = 1600, .y = 0, .w = 1280, .h = 720 } };
    try std.testing.expectEqual(@as(?usize, 1), bestMonitor(.{ .x = 1500, .y = 10, .w = 400, .h = 100 }, &mons));
}
