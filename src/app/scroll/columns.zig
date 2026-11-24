//! Which columns of a scrolling capture's region scroll (stitch.zig).
//!
//! A region may span content that scrolls and content that does not:
//! two terminal panes side by side (Ghostty, tmux), a page beside a fixed
//! sidebar. Rows hashed across both never line up, because the part that
//! stayed put disagrees with the part that moved at every distance (the
//! capture stopped with "Couldn't match the next part"). So, from two
//! frames:
//!
//! - the columns that moved (changed in at least an eighth of the rows)
//!   are the ones to line up; columns that stayed put add nothing to the
//!   matching (a blank margin) or contradict it (another pane);
//! - when a side holds content that stayed put (a column that varies down
//!   the frame yet did not change), it is not part of what scrolls: the
//!   image keeps the moving part only, up to the first line or change of
//!   colour between them (a pane divider). A side with nothing but
//!   background stays, so a capture is cropped only where something
//!   would otherwise repeat.
//!
//! A frame where only a few rows changed (a blinking cursor, a spinner)
//! has no moving columns: the stitcher then compares whole rows as
//! before.
//!
//! Stable API:
//!   Span                   columns [x0, x1)
//!   Split{ match, keep }   columns to line up, columns to keep
//!   split(gpa, prev, cur, width, hw, top, rows)  null when nothing scrolled

const std = @import("std");

pub const Span = struct {
    x0: u32,
    x1: u32,

    pub fn len(self: Span) u32 {
        return self.x1 - self.x0;
    }
};

pub const Split = struct {
    /// the columns that moved: the ones the frames are lined up by
    match: Span,
    /// the columns of the image (all of them unless a side stayed put)
    keep: Span,
};

/// Rows [top, top + rows) of two frames `width` wide, the first `hw`
/// columns compared (a scroll bar's strip left out): what scrolls, or
/// null when no column moved in an eighth of the rows.
pub fn split(gpa: std.mem.Allocator, prev: []const u32, cur: []const u32, width: u32, hw: u32, top: u32, rows: u32) !?Split {
    const changed = try gpa.alloc(u32, hw);
    defer gpa.free(changed);
    @memset(changed, 0);
    for (top..top + rows) |y| {
        const a = prev[y * width ..][0..hw];
        const b = cur[y * width ..][0..hw];
        for (a, b, changed) |p, q, *c| c.* += @intFromBool(p != q);
    }
    const least = @max(1, rows / 8);
    var x0: u32 = 0;
    while (x0 < hw and changed[x0] < least) x0 += 1;
    if (x0 == hw) return null;
    var x1: u32 = hw;
    while (changed[x1 - 1] < least) x1 -= 1;
    const col: Column = .{ .px = cur, .width = width, .top = top, .rows = rows, .changed = changed };
    return .{
        .match = .{ .x0 = x0, .x1 = x1 },
        .keep = .{ .x0 = col.edge(x0, .left), .x1 = col.edge(x1, .right) },
    };
}

const Side = enum { left, right };

/// How far a pixel's colour is from another's (sum of the channels'
/// differences, 0..765).
fn distance(a: u32, b: u32) u32 {
    var d: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |sh| {
        const x: i32 = @intCast(a >> sh & 0xFF);
        const y: i32 = @intCast(b >> sh & 0xFF);
        d += @abs(x - y);
    }
    return d;
}

/// A column within this of its top pixel all the way down is one colour
/// (a fractional scale blends a background a unit or two off here and
/// there); one with a pixel beyond `ink_min` holds content (text, lines).
const plain_max = 6;
const ink_min = 48;
/// columns of content that stayed put needed to call a side still
const still_cols = 3;

const Column = struct {
    px: []const u32,
    width: u32,
    top: u32,
    rows: u32,
    changed: []const u32,

    fn at(self: Column, x: u32, y: usize) u32 {
        return self.px[y * self.width + x];
    }

    /// The farthest any pixel of the column is from its top one.
    fn spread(self: Column, x: u32) u32 {
        const c = self.at(x, self.top);
        var most: u32 = 0;
        for (self.top..self.top + self.rows) |y| most = @max(most, distance(self.at(x, y), c));
        return most;
    }

    /// Content that did not move: it varies down the frame, unchanged.
    fn stayed(self: Column, x: u32) bool {
        return self.changed[x] == 0 and self.spread(x) > ink_min;
    }

    /// Where the kept columns end on `side` of the moving ones (which
    /// start or end at `from`): the frame's edge unless content that
    /// stayed put lies that way; then the first column of another colour
    /// than the moving part's background (the divider), or that content.
    fn edge(self: Column, from: u32, side: Side) u32 {
        const n: u32 = @intCast(self.changed.len);
        const far: u32 = if (side == .left) 0 else self.width;
        var still: u32 = 0;
        var x = from;
        while (if (side == .left) x > 0 else x < n) : (x = step(x, side)) {
            if (self.stayed(col(x, side))) still += 1;
        }
        if (still < still_cols) return far;
        var bg: ?u32 = null;
        x = from;
        while (if (side == .left) x > 0 else x < n) : (x = step(x, side)) {
            const c = col(x, side);
            if (self.changed[c] > 0) continue;
            const sp = self.spread(c);
            if (sp > ink_min) return x;
            if (sp > plain_max) continue;
            const colour = self.at(c, self.top);
            if (bg) |b| {
                if (distance(colour, b) > plain_max) return x;
            } else bg = colour;
        }
        return x;
    }

    /// The column just inside boundary `x` on `side`.
    fn col(x: u32, side: Side) u32 {
        return if (side == .left) x - 1 else x;
    }

    fn step(x: u32, side: Side) u32 {
        return if (side == .left) x - 1 else x + 1;
    }
};

// --- tests: two panes side by side

const testing = std.testing;
const bg_colour: u32 = 0xFF202020;
const divider: u32 = 0xFF808080;

/// Text-like content: line `line` of a pane, at column `x`.
fn ink(line: u32, x: u32, seed: u32) u32 {
    const h = std.hash.Wyhash.hash(seed, std.mem.asBytes(&[2]u32{ line, x / 6 }));
    return if (h % 3 == 0) 0xFFE0E0E0 else bg_colour;
}

/// A frame of two panes `w` wide (a divider at `cut`): the left pane
/// scrolled by `off` rows, the right one still; text in the left pane
/// up to column `text_w`, background after it. Every ninth row of the
/// screen the background is a unit off, as a fractional scale blends
/// it, and stays so as the text scrolls.
fn panes(buf: []u32, w: u32, h: u32, cut: u32, text_w: u32, off: u32) void {
    for (0..h) |yi| for (0..w) |xi| {
        const y: u32 = @intCast(yi);
        const x: u32 = @intCast(xi);
        const p = if (x == cut)
            divider
        else if (x > cut)
            (if (x > cut + 4) ink(y / 3, x, 2) else bg_colour)
        else if (x < text_w) ink((y + off) / 3, x, 1) else bg_colour;
        buf[yi * w + xi] = if (p == bg_colour and y % 9 == 0) bg_colour + 1 else p;
    };
}

test "two panes: the moving one is lined up and kept, up to the divider" {
    const gpa = testing.allocator;
    const w = 200;
    const h = 90;
    var a: [w * h]u32 = undefined;
    var b: [w * h]u32 = undefined;
    panes(&a, w, h, 120, 80, 0);
    panes(&b, w, h, 120, 80, 21);
    const s = (try split(gpa, &a, &b, w, w, 0, h)).?;
    try testing.expect(s.match.x0 < 6 and s.match.x1 > 70 and s.match.x1 <= 80);
    try testing.expectEqual(Span{ .x0 = 0, .x1 = 120 }, s.keep);
}

test "one pane with a blank margin: every column is kept" {
    const gpa = testing.allocator;
    const w = 120;
    const h = 90;
    var a: [w * h]u32 = undefined;
    var b: [w * h]u32 = undefined;
    // no second pane: the divider and what lies right of it are past w
    panes(&a, w, h, 500, 70, 0);
    panes(&b, w, h, 500, 70, 9);
    const s = (try split(gpa, &a, &b, w, w, 0, h)).?;
    try testing.expectEqual(Span{ .x0 = 0, .x1 = w }, s.keep);
    try testing.expect(s.match.x1 <= 70);
}

test "a few rows changing (a cursor, a spinner) is not a scroll" {
    const gpa = testing.allocator;
    const w = 100;
    const h = 96;
    var a: [w * h]u32 = undefined;
    var b: [w * h]u32 = undefined;
    panes(&a, w, h, 500, 80, 0);
    b = a;
    for (80..90) |y| for (10..20) |x| {
        b[y * w + x] = 0xFFFFFFFF;
    };
    try testing.expectEqual(@as(?Split, null), try split(gpa, &a, &b, w, w, 0, h));
    try testing.expectEqual(@as(?Split, null), try split(gpa, &a, &a, w, w, 0, h));
}

test "the stitcher keeps the scrolling pane only, and carries on through it" {
    const Stitcher = @import("stitch.zig").Stitcher;
    const gpa = testing.allocator;
    const w = 200;
    const h = 90;
    var buf: [w * h]u32 = undefined;
    panes(&buf, w, h, 120, 80, 0);
    var st = try Stitcher.init(gpa, .{ .pixels = &buf, .width = w, .height = h }, 20_000);
    defer st.deinit();
    for (1..6) |i| {
        panes(&buf, w, h, 120, 80, @intCast(i * 21));
        const r = try st.push(.{ .pixels = &buf, .width = w, .height = h });
        try testing.expectEqual(@as(u32, 21), r.appended);
    }
    const out = try st.result();
    defer gpa.free(out.pixels);
    try testing.expectEqual(@as(u32, 120), out.width);
    try testing.expectEqual(@as(u32, h + 5 * 21), out.height);
    // row y of the image is row y of the left pane's text (the
    // background a unit off on some rows, as on screen)
    for (0..out.height) |y| for (0..80) |x| {
        const want = ink(@intCast(y / 3), @intCast(x), 1) != bg_colour;
        try testing.expectEqual(want, out.pixels[y * 120 + x] == 0xFFE0E0E0);
    };
}
