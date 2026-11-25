//! The recorded area's encoded size (even for H.264, scaled down to the
//! maximum width for GIFs). The area itself is a geom.Rect in the
//! compositor's logical layout: geom.bestMonitor finds its monitor,
//! geom.toFramePixels maps it onto a stream's pixels.

const std = @import("std");

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

test "sizes for the encoders" {
    try std.testing.expectEqual([2]u32{ 640, 358 }, evenSize(641, 359));
    try std.testing.expectEqual([2]u32{ 2, 2 }, evenSize(1, 1));
    try std.testing.expectEqual([2]u32{ 800, 450 }, gifSize(1600, 900, 800));
    try std.testing.expectEqual([2]u32{ 300, 200 }, gifSize(300, 200, 800));
}
