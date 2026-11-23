//! ui/material.zig's tests.

const std = @import("std");
const render = @import("../gfx/render.zig");
const theme = @import("theme.zig");
const material = @import("material.zig");
const Rect = @import("shapes.zig").Rect;

const testing = std.testing;
const sh: theme.Shadow = .{ .color = 0x80000000, .blur = 8, .dy = 2 };

test "the shadow surrounds the rect, never shows inside it, and is cached" {
    const gpa = testing.allocator;
    var cache: material.ShadowCache = .{};
    defer cache.release(gpa);
    const r: Rect = .{ .x = 20, .y = 20, .w = 40, .h = 30 };
    const fr = material.shadowFootprint(r, sh, 1);
    try testing.expectEqual(@as(i32, 12), fr.x);
    try testing.expectEqual(@as(i32, 56), fr.w);
    const m = cache.get(gpa, r, 6, sh, 1).?;
    const fw: usize = @intCast(fr.w);
    // the middle of the rect: none; just below it (offset down): some
    try testing.expectEqual(@as(u8, 0), m[@as(usize, @intCast(r.y - fr.y + 15)) * fw + @as(usize, @intCast(r.x - fr.x + 20))]);
    try testing.expect(m[@as(usize, @intCast(r.bottom() - fr.y + 1)) * fw + @as(usize, @intCast(r.x - fr.x + 20))] > 20);
    // the same surface again: the same mask, not rebuilt
    try testing.expectEqual(m.ptr, cache.get(gpa, r, 6, sh, 1).?.ptr);
}

test "shadows blend onto opaque and see-through surfaces alike" {
    const gpa = testing.allocator;
    var cache: material.ShadowCache = .{};
    defer cache.release(gpa);
    var px: [80 * 80]u32 = @splat(0xFFFFFFFF);
    var cv = render.Canvas.init(&px, 80, 80);
    const r: Rect = .{ .x = 20, .y = 20, .w = 40, .h = 30 };
    material.shadow(gpa, &cv, r, 6, sh, 1, 1, &cache);
    const below = px[52 * 80 + 40];
    try testing.expect(below & 0xFF < 0xFF and below >> 24 == 0xFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px[35 * 80 + 40]);
    var clear: [80 * 80]u32 = @splat(0);
    material.shadowStraight(gpa, &clear, 80, 80, r, 6, sh, 1, 1, &cache);
    try testing.expect(clear[52 * 80 + 40] >> 24 > 0);
    try testing.expectEqual(@as(u32, 0), clear[35 * 80 + 40]);
    // off the edges: clipped, never a crash
    material.shadow(gpa, &cv, .{ .x = -30, .y = 70, .w = 40, .h = 30 }, 6, sh, 1, 0.5, &cache);
    material.shadowStraight(gpa, &clear, 80, 80, .{ .x = 70, .y = -20, .w = 40, .h = 30 }, 6, sh, 1, 1, &cache);
}

test "rounded blits and the hairline keep to the rounded rect" {
    var px: [20 * 20]u32 = @splat(0xFF000000);
    var cv = render.Canvas.init(&px, 20, 20);
    const src: [20 * 20]u32 = @splat(0xFFFFFFFF);
    const r: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 };
    material.blitRoundRect(&cv, &src, r, 6);
    try testing.expectEqual(@as(u32, 0xFF000000), px[0]); // the corner is cut
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10 * 20 + 10]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10]); // the straight top edge
    @memset(&px, 0xFF000000);
    material.hairline(&cv, r, 6, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), px[10]);
    try testing.expectEqual(@as(u32, 0xFF000000), px[10 * 20 + 10]);
    try testing.expectEqual(@as(u32, 0xFF000000), px[0]);
}

test "frost of a flat colour is that colour tinted; glass draws without a cache" {
    const gpa = testing.allocator;
    const behind: [40 * 40]u32 = @splat(0xFF808080);
    var out: [20 * 20]u32 = undefined;
    const src: Rect = .{ .x = 0, .y = 0, .w = 40, .h = 40 };
    const r: Rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    try material.frost(gpa, &behind, src, r, 6, 0x80FF0000, &out);
    for (out) |p| try testing.expectEqual(render.Canvas.blendPixel(0xFF808080, 0x80FF0000), p);
    var px: [60 * 60]u32 = @splat(0xFF808080);
    var cv = render.Canvas.init(&px, 60, 60);
    const th = theme.Theme.get(true, null);
    material.glass(gpa, &cv, .{ .x = 10, .y = 10, .w = 40, .h = 30 }, 10, th, 1);
    try testing.expect(px[25 * 60 + 30] != 0xFF808080);
    try testing.expectEqual(@as(u32, 0xFF808080), px[5 * 60 + 5]);
}

test "a snapshot fades what was drawn after it" {
    const gpa = testing.allocator;
    var px: [4 * 4]u32 = @splat(0xFF000000);
    var cv = render.Canvas.init(&px, 4, 4);
    const snap = material.Snapshot.take(gpa, &cv, .{ .x = 0, .y = 0, .w = 4, .h = 4 }).?;
    cv.fillRect(0, 0, 4, 4, 0xFFFFFFFF);
    snap.restore(gpa, &cv, 0.5);
    const g = px[5] & 0xFF;
    try testing.expect(g >= 0x7F and g <= 0x80);
}
