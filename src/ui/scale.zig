//! Logical to physical pixels, one way for every surface (a capture's
//! logical layout against its image pixels is src/geom.zig). A surface's
//! scale is `scale120` (120 = 100%); lengths are designed in logical
//! pixels and drawn at `k` = scale120 / 120 physical pixels each.
//!
//! Stable API:
//!   of(scale120) f64          the factor k
//!   px(v, k) i32              round(v * k), for an int or float length
//!   rect(r, k) Rect           a logical rect in physical pixels, by its
//!                             edges (neighbours share edges: no seams)
//!   toLogical(v, k) i32       a physical coordinate (pointer) in logical
//!                             pixels, floored: the logical pixel it is in
//!   ff(v) f64                 an integer as f64

const std = @import("std");
const Rect = @import("../geom.zig").Rect;

/// The factor from logical to physical pixels.
pub fn of(scale120: u32) f64 {
    return @as(f64, @floatFromInt(@max(scale120, 1))) / 120.0;
}

/// An integer (any int type) or float as f64.
pub inline fn ff(v: anytype) f64 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => @floatFromInt(v),
        .float, .comptime_float => v,
        else => @compileError("scale.ff: a number, not " ++ @typeName(@TypeOf(v))),
    };
}

/// The logical length `v` (int or float) in physical pixels, rounded.
pub inline fn px(v: anytype, k: f64) i32 {
    return toI32(@round(ff(v) * k));
}

/// The logical rect `r` in physical pixels, by its edges: two rects that
/// touch in logical pixels touch in physical ones too.
pub fn rect(r: Rect, k: f64) Rect {
    return .fromEdges(px(r.x, k), px(r.y, k), px(r.right(), k), px(r.bottom(), k));
}

/// The physical coordinate `v` (a pointer position) in logical pixels:
/// the logical pixel it falls in (floored, also below zero).
pub fn toLogical(v: f64, k: f64) i32 {
    return toI32(@floor(v / k));
}

fn toI32(v: f64) i32 {
    if (!(v > -1e9)) return -1_000_000_000;
    if (v > 1e9) return 1_000_000_000;
    return @intFromFloat(v);
}

const testing = std.testing;

test "px rounds ints and floats alike" {
    try testing.expectEqual(@as(i32, 15), px(10, 1.5));
    try testing.expectEqual(@as(i32, 15), px(@as(f64, 10), 1.5));
    try testing.expectEqual(@as(i32, 2), px(@as(u32, 1), 1.75)); // 1.75 -> 2
    try testing.expectEqual(@as(i32, 3), px(2.5, 1)); // halves away from zero
    try testing.expectEqual(@as(i32, -3), px(-2.5, 1));
    try testing.expectEqual(@as(f64, 1.25), of(150));
    try testing.expectEqual(@as(f64, 1), of(0) * 120); // never zero
}

test "rects scale by their edges, so neighbours never part" {
    const k = 1.25;
    const a: Rect = .{ .x = 0, .y = 0, .w = 13, .h = 7 };
    const b: Rect = .{ .x = 13, .y = 7, .w = 13, .h = 7 };
    const sa = rect(a, k);
    const sb = rect(b, k);
    try testing.expectEqual(sa.right(), sb.x);
    try testing.expectEqual(sa.bottom(), sb.y);
    // sizes may differ by a pixel, edges never
    try testing.expect(@abs(sa.w - sb.w) <= 1);
}

test "physical coordinates map to the logical pixel they are in" {
    try testing.expectEqual(@as(i32, 0), toLogical(1.9, 2));
    try testing.expectEqual(@as(i32, 1), toLogical(2, 2));
    try testing.expectEqual(@as(i32, -1), toLogical(-0.5, 2));
    try testing.expectEqual(@as(i32, 8), toLogical(10, 1.25));
    try testing.expectEqual(@as(i32, 7), toLogical(9.9, 1.25));
    try testing.expectEqual(@as(f64, 3), ff(@as(i32, 3)));
    try testing.expectEqual(@as(f64, 0.5), ff(0.5));
}
