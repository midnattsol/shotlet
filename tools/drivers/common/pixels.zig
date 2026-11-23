//! Colour matching on 0xAARRGGBB pictures for the drivers' `find`,
//! `findpng` and `runs` commands.

const std = @import("std");

/// Within `t` per channel of `c`.
pub fn near(p: u32, c: u32, t: u32) bool {
    inline for (.{ 0, 8, 16 }) |sh| {
        const a: i32 = @intCast((p >> sh) & 0xFF);
        const b: i32 = @intCast((c >> sh) & 0xFF);
        if (@abs(a - b) > t) return false;
    }
    return true;
}

/// Paint every pixel outside `region` (x0, y0, x1, y1) with `~rgb`, so a
/// search for `rgb` never matches there.
pub fn maskOutside(px: []u32, w: u32, region: [4]u32, rgb: u32) void {
    for (px, 0..) |*p, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        if (x < region[0] or y < region[1] or x >= region[2] or y >= region[3]) p.* = ~rgb;
    }
}

/// Bounding box (x0, y0, x1, y1) of the first blob, in reading order, at
/// least `min_w` wide, of pixels within `tol` (per channel) of `rgb`: e.g.
/// a dialog's accent coloured default button.
pub fn findBlob(gpa: std.mem.Allocator, px: []const u32, w: u32, h: u32, rgb: u32, tol: u32, min_w: u32) ![4]u32 {
    var seen = try gpa.alloc(bool, px.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    for (px, 0..) |p, start| {
        if (seen[start] or !near(p, rgb, tol)) continue;
        try stack.append(gpa, start);
        seen[start] = true;
        var box = [4]u32{ w, h, 0, 0 };
        while (stack.pop()) |i| {
            const x: u32 = @intCast(i % w);
            const y: u32 = @intCast(i / w);
            box = .{ @min(box[0], x), @min(box[1], y), @max(box[2], x), @max(box[3], y) };
            const nbrs = [4]?usize{
                if (x > 0) i - 1 else null,
                if (x + 1 < w) i + 1 else null,
                if (y > 0) i - w else null,
                if (y + 1 < h) i + w else null,
            };
            for (nbrs) |n| if (n) |j| if (!seen[j] and near(px[j], rgb, tol)) {
                seen[j] = true;
                try stack.append(gpa, j);
            };
        }
        if (box[2] - box[0] + 1 >= min_w) return box;
    }
    return error.NotFound;
}

/// How many vertical runs of pixels near `want` column `x` has.
pub fn columnRuns(px: []const u32, w: u32, h: u32, x: u32, want: u32, tol: u32) u32 {
    var runs: u32 = 0;
    var inside = false;
    for (0..h) |y| {
        const hit = near(px[y * w + x], want, tol);
        if (hit and !inside) runs += 1;
        inside = hit;
    }
    return runs;
}

test "blobs, masks and runs" {
    // 4x3: a 2x2 red square at (1,0) and a lone red pixel at (3,2)
    const r: u32 = 0xFFFF2020;
    const k: u32 = 0xFF000000;
    var px = [_]u32{ k, r, r, k, k, r, r, k, k, k, k, r };
    const gpa = std.testing.allocator;
    try std.testing.expectEqual([4]u32{ 1, 0, 2, 1 }, try findBlob(gpa, &px, 4, 3, 0xFF2020, 8, 1));
    try std.testing.expectError(error.NotFound, findBlob(gpa, &px, 4, 3, 0xFF2020, 8, 3));
    try std.testing.expectEqual(@as(u32, 1), columnRuns(&px, 4, 3, 1, 0xFF2020, 8));
    maskOutside(&px, 4, .{ 3, 0, 4, 3 }, 0xFF2020);
    try std.testing.expectEqual([4]u32{ 3, 2, 3, 2 }, try findBlob(gpa, &px, 4, 3, 0xFF2020, 8, 1));
}
