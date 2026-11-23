//! The right-click menu of a thumbnail card (the quick access cards, the
//! quick video card): rows of words over the dimmed picture, centred,
//! the one under the pointer lit. Logical px; the card draws it at its
//! scale `k`.

const std = @import("std");
const fui = @import("floatui.zig");
const text = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const scale = @import("scale.zig");
const Rect = @import("shapes.zig").Rect;
const Canvas = fui.Canvas;

/// a row's height
pub const row_h = 20;
/// the rows' inset from the card's sides
const inset = 8;

pub const Item = struct {
    label: []const u8,
    /// unavailable: drawn dimmed
    dim: bool = false,
};

/// The top of `n` rows centred in a card `card_h` tall.
pub fn top(n: usize, card_h: i32) i32 {
    return @divTrunc(card_h - @as(i32, @intCast(n)) * row_h, 2);
}

/// The row of `n` at y (from the card's top), null between and around
/// them.
pub fn rowAt(n: usize, card_h: i32, y: i32) ?usize {
    const t = top(n, card_h);
    if (y < t) return null;
    const row: usize = @intCast(@divFloor(y - t, row_h));
    return if (row < n) row else null;
}

/// Draw the menu over the whole card `cv` (`card_w` logical px wide).
pub fn draw(cv: *Canvas, items: []const Item, hot: ?usize, card_w: i32, k: f64, th: theme.Theme) void {
    cv.fillRect(0, 0, @intCast(cv.w), @intCast(cv.h), th.scrim(.pill));
    const card_h: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(cv.h)) / k));
    const t = top(items.len, card_h);
    const fs = 12.5 * k;
    for (items, 0..) |item, j| {
        const row = scale.rect(.{ .x = inset, .y = t + @as(i32, @intCast(j)) * row_h, .w = card_w - 2 * inset, .h = row_h }, k);
        if (hot == j and !item.dim) cv.fillRoundRectAA(row.x, row.y, row.w, row.h, 5 * k, theme.withAlpha(th.on_scrim, 0x40));
        text.draw(cv, row.x + scale.px(10, k), row.y + @divTrunc(row.h - text.height(fs), 2), fs, if (item.dim) th.on_scrim_dim else th.on_scrim, item.label);
    }
}

const testing = std.testing;

test "rows are centred and hit one by one" {
    // 7 rows in a 150 px card: 140 px from 5
    try testing.expectEqual(@as(i32, 5), top(7, 150));
    try testing.expectEqual(@as(?usize, null), rowAt(7, 150, 4));
    try testing.expectEqual(@as(?usize, 0), rowAt(7, 150, 5));
    try testing.expectEqual(@as(?usize, 2), rowAt(7, 150, 5 + 2 * row_h + 3));
    try testing.expectEqual(@as(?usize, 6), rowAt(7, 150, 144));
    try testing.expectEqual(@as(?usize, null), rowAt(7, 150, 145));
    // five rows: 25 px above and below
    try testing.expectEqual(@as(i32, 25), top(5, 150));
}

test "the hot row is lit, a dim one never" {
    const th = theme.Theme.get(true, null);
    var buf: [240 * 150]u32 = undefined;
    var cv = Canvas.init(&buf, 240, 150);
    const items = [_]Item{ .{ .label = "Copy" }, .{ .label = "Annotate", .dim = true } };
    const y0: usize = @intCast(top(2, 150) + 2);
    @memset(&buf, 0xFF808080);
    draw(&cv, &items, null, 240, 1, th);
    const plain = buf[y0 * 240 + 12];
    @memset(&buf, 0xFF808080);
    draw(&cv, &items, 0, 240, 1, th);
    try testing.expect(buf[y0 * 240 + 12] != plain);
    const dim_px = buf[(y0 + row_h) * 240 + 12];
    @memset(&buf, 0xFF808080);
    draw(&cv, &items, 1, 240, 1, th);
    try testing.expectEqual(dim_px, buf[(y0 + row_h) * 240 + 12]);
}
