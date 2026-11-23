//! Checks an option's or argument's value against its kind, and reads
//! the composite ones (X,Y,W,H and A,B): the one place they are parsed.

const std = @import("std");
const Kind = @import("spec.zig").Kind;

/// The largest width or height a rect takes.
pub const max_side = 1 << 15;

/// Null when `v` is fine; else what it should look like.
pub fn check(arena: std.mem.Allocator, kind: Kind, choices: []const []const u8, min: i64, max: i64, v: []const u8) !?[]const u8 {
    return switch (kind) {
        .string, .file => null,
        .int => checkInt(arena, min, max, v),
        .choice => checkChoice(arena, choices, v),
        .rect => if (rect(v) != null) null else std.fmt.comptimePrint("expected X,Y,W,H (whole numbers, W and H from 1 to {d})", .{max_side}),
        .pair => checkPair(arena, min, max, v),
    };
}

fn checkInt(arena: std.mem.Allocator, min: i64, max: i64, v: []const u8) !?[]const u8 {
    const n = std.fmt.parseInt(i64, v, 10) catch null;
    if (n != null and n.? >= min and n.? <= max) return null;
    return try std.fmt.allocPrint(arena, "expected a whole number from {d} to {d}", .{ min, max });
}

fn checkChoice(arena: std.mem.Allocator, choices: []const []const u8, v: []const u8) !?[]const u8 {
    for (choices) |c| if (std.mem.eql(u8, c, v)) return null;
    const list = try std.mem.join(arena, ", ", choices);
    return try std.fmt.allocPrint(arena, "expected one of: {s}", .{list});
}

fn checkPair(arena: std.mem.Allocator, min: i64, max: i64, v: []const u8) !?[]const u8 {
    if (pair(i64, v)) |p| if (p[0] >= min and p[0] <= max and p[1] >= min and p[1] <= max) return null;
    return try std.fmt.allocPrint(arena, "expected A,B (two whole numbers from {d} to {d})", .{ min, max });
}

/// "X,Y,W,H": four integers, W and H from 1 to `max_side`.
pub fn rect(v: []const u8) ?[4]i32 {
    var it = std.mem.splitScalar(u8, v, ',');
    var vals: [4]i32 = undefined;
    for (&vals) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    for (vals[2..]) |side| if (side <= 0 or side > max_side) return null;
    return vals;
}

/// "A,B": two integers that fit `T`.
pub fn pair(comptime T: type, v: []const u8) ?[2]T {
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse return null;
    const a = std.fmt.parseInt(T, v[0..comma], 10) catch return null;
    const b = std.fmt.parseInt(T, v[comma + 1 ..], 10) catch return null;
    return .{ a, b };
}

test "values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .int, &.{}, 0, 60, "10"));
    try std.testing.expectEqualStrings("expected a whole number from 0 to 60", (try check(a, .int, &.{}, 0, 60, "61")).?);
    try std.testing.expect((try check(a, .int, &.{}, 0, 60, "x")) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .choice, &.{ "bash", "zsh" }, 0, 0, "zsh"));
    try std.testing.expectEqualStrings("expected one of: bash, zsh", (try check(a, .choice, &.{ "bash", "zsh" }, 0, 0, "csh")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .rect, &.{}, 0, 0, "-10,20,300,200"));
    try std.testing.expect((try check(a, .rect, &.{}, 0, 0, "10,20,0,200")) != null);
    try std.testing.expect((try check(a, .rect, &.{}, 0, 0, "10,20,30")) != null);
    try std.testing.expect((try check(a, .rect, &.{}, 0, 0, "0,0,40000,10")) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), try check(a, .pair, &.{}, -5, 5, "-5,5"));
    try std.testing.expectEqualStrings("expected A,B (two whole numbers from 0 to 9)", (try check(a, .pair, &.{}, 0, 9, "1,10")).?);
    try std.testing.expect((try check(a, .pair, &.{}, 0, 9, "1,2,3")) != null);
    try std.testing.expect((try check(a, .pair, &.{}, 0, 9, "1")) != null);
}

test "rects and pairs read" {
    try std.testing.expectEqual([4]i32{ 100, -20, 300, 200 }, rect("100,-20,300,200").?);
    try std.testing.expectEqual(@as(?[4]i32, null), rect("1,2,0,4"));
    try std.testing.expectEqual(@as(?[4]i32, null), rect("1,2,3"));
    try std.testing.expectEqual(@as(?[4]i32, null), rect("1,2,3,4,5"));
    try std.testing.expectEqual([2]i32{ -20, 300 }, pair(i32, "-20,300").?);
    try std.testing.expectEqual(@as(?[2]i32, null), pair(i32, "1,2,3"));
    try std.testing.expectEqual([2]i64{ 1000, 2500 }, pair(i64, "1000,2500").?);
}
