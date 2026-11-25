//! Big buffer work split in bands of rows, a thread each: refilling a
//! 4K pane's view, composing a whole 4K frame, blending one (the
//! editor's fade). The bands write disjoint rows; whatever they read
//! must not change meanwhile. Small work runs here, on the caller's
//! thread.

const std = @import("std");
const parallel = @import("../parallel.zig");
const Rect = @import("../geom.zig").Rect;

/// Below this many pixels one thread does it.
pub const min_area: i64 = 1 << 20;
const max_threads = 8;

/// `f(ctx, band)` over bands of `r` covering it exactly.
pub fn run(r: Rect, ctx: anytype, comptime f: fn (@TypeOf(ctx), Rect) void) void {
    if (r.isEmpty()) return;
    const cpus = std.Thread.getCpuCount() catch 1;
    const n: usize = if (r.area() < min_area) 1 else @min(max_threads, cpus, @as(usize, @intCast(r.h)));
    var g: parallel.Group(max_threads) = .{};
    for (1..n) |i| g.go(f, .{ ctx, bandOf(r, i, n) });
    f(ctx, bandOf(r, 0, n));
    g.wait();
}

/// Band `i` of `n` of `r`.
pub fn bandOf(r: Rect, i: usize, n: usize) Rect {
    const h: usize = @intCast(r.h);
    const y0 = r.y + @as(i32, @intCast(h * i / n));
    const y1 = r.y + @as(i32, @intCast(h * (i + 1) / n));
    return Rect.fromEdges(r.x, y0, r.right(), y1);
}

test "the bands cover the rect exactly, once" {
    const r: Rect = .{ .x = 3, .y = 5, .w = 2000, .h = 1001 };
    var seen: [1001]u8 = @splat(0);
    const Ctx = struct {
        seen: *[1001]u8,
        // (the bands' rows are disjoint: no lock)
        fn mark(c: *@This(), b: Rect) void {
            var y = b.y;
            while (y < b.bottom()) : (y += 1) c.seen[@intCast(y - 5)] += 1;
        }
    };
    var c: Ctx = .{ .seen = &seen };
    run(r, &c, Ctx.mark);
    for (seen) |v| try std.testing.expectEqual(@as(u8, 1), v);
    for (0..7) |i| try std.testing.expectEqual(@as(i32, 2000), bandOf(r, i, 7).w);
}
