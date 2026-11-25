//! The scroll distance when no distance lines the rows up exactly
//! (stitch.zig asks after its exact match fails).
//!
//! On a fractional scale (1.5) a scroll moves the content by logical
//! pixels: an odd number of them is a half physical pixel, and the app
//! paints the page anew at that offset, so edges, thin lines and text
//! blend into neighbouring rows and no row of the new frame equals one
//! of the old (a mixed 2 + 1.5 layout or a single 1.5 monitor; at
//! integer scales the exact match is enough). Rows are compared by their
//! profile instead: the mean of each of `blocks` runs of columns, which
//! such blends barely move. The distance whose overlap differs least
//! wins when it differs little and clearly less than distances do in
//! general (so a page that changed, or a blank one, does not match).

const std = @import("std");

/// columns runs per row
pub const blocks = 64;

/// Best cost (profile units: 4x the mean r+g+b of a block, 0..3060)
/// accepted at most, and at most this share of the median cost.
const max_cost = 48.0;
const max_share = 0.15;
/// rows compared per distance at most (evenly spread)
const sampled_rows = 192;

/// The profiles of `height` rows of `pixels` (`width` wide, the first
/// `hw` columns): `blocks` values per row into `out`.
pub fn profiles(pixels: []const u32, width: u32, hw: u32, height: u32, out: []u16) void {
    const n = @min(hw, width);
    for (0..height) |y| {
        const row = pixels[y * width ..][0..n];
        for (0..blocks) |b| {
            const x0 = n * b / blocks;
            const x1 = @max(x0 + 1, n * (b + 1) / blocks);
            var sum: u64 = 0;
            for (row[@min(x0, n - 1)..@min(x1, n)]) |p| sum += (p >> 16 & 0xFF) + (p >> 8 & 0xFF) + (p & 0xFF);
            out[y * blocks + b] = @intCast(sum * 4 / (x1 - x0));
        }
    }
}

/// A cost low enough to line up: little, and clearly less than distances
/// cost in general.
fn fits(c: f64, median: f64) bool {
    return c <= max_cost and c < median * max_share;
}

/// How differently `cur`'s rows lie under `prev`'s shifted by d (mean
/// absolute profile difference over the overlap, sampled).
fn cost(prev: []const u16, cur: []const u16, rows: usize, d: usize) f64 {
    const overlap = rows - d;
    const step = @max(1, overlap / sampled_rows);
    var sum: u64 = 0;
    var n: u64 = 0;
    var i: usize = 0;
    while (i < overlap) : (i += step) {
        const a = cur[i * blocks ..][0..blocks];
        const b = prev[(i + d) * blocks ..][0..blocks];
        for (a, b) |x, y| sum += @abs(@as(i32, x) - y);
        n += blocks;
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(@max(1, n)));
}

/// The distance d at which `cur`'s rows lie nearly as `prev`'s shifted
/// up by d (profiles of `rows` rows each); null when none fits or the
/// best is the farthest one looked at, 0 when nearly nothing moved. Among
/// near-equal costs (repeated content), the one nearest `expected`.
pub fn findOffset(gpa: std.mem.Allocator, prev: []const u16, cur: []const u16, rows: usize, expected: ?u32) !?u32 {
    const min_overlap = @max(4, rows / 10);
    if (rows <= min_overlap + 1) return null;
    const last = rows - min_overlap;
    const costs = try gpa.alloc(f64, last);
    defer gpa.free(costs);
    var best: usize = 1;
    for (1..last + 1) |d| {
        costs[d - 1] = cost(prev, cur, rows, d);
        if (costs[d - 1] < costs[best - 1]) best = d;
    }
    const best_cost = costs[best - 1];
    const sorted = try gpa.dupe(f64, costs);
    defer gpa.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const median = sorted[sorted.len / 2];
    // as low a cost without moving at all: the content stayed put and
    // something small changed (an overscroll glow, a blinking caret)
    const still = cost(prev, cur, rows, 0);
    if (fits(still, median) and still <= best_cost + @max(2.0, still * 0.25)) return 0;
    if (!fits(best_cost, median)) return null;
    // the least cost at the search's limit: the content may have moved
    // farther, the cost still falling towards it
    if (best == last) return null;
    const tol = @max(2.0, best_cost * 0.25);
    const e = expected orelse return @intCast(best);
    // as near the previous step as a cost about as low allows
    var pick = best;
    for (1..last) |d| {
        if (costs[d - 1] > best_cost + tol) continue;
        if (@abs(@as(i64, @intCast(d)) - e) < @abs(@as(i64, @intCast(pick)) - e)) pick = d;
    }
    return @intCast(pick);
}

// --- tests: a page painted at a half-pixel offset

const testing = std.testing;

/// A page of bands with a thin dark line in each, painted with its top
/// at `top2` half rows (so an odd `top2` blends every edge into two
/// rows), `w` x `h`.
fn halfPixelFrame(buf: []u32, w: u32, h: u32, top2: u32) void {
    for (0..h) |yi| {
        // the page between y and y + 1, in half rows: two samples
        const y2 = @as(u32, @intCast(yi)) * 2 + top2;
        for (0..w) |xi| {
            const x: u32 = @intCast(xi);
            const a = pageAt(y2, x);
            const b = pageAt(y2 + 1, x);
            buf[yi * w + xi] = 0xFF000000 | avg(a, b);
        }
    }
}

/// The page's colour at half row `y2`, column `x`.
fn pageAt(y2: u32, x: u32) u32 {
    const band = y2 / 2 / 25;
    const line = (y2 / 2) % 25 == 12 and (x + band * 13) % 64 < 20;
    if (line) return 0x101010;
    const r = (band * 67) % 200 + 30;
    const g = (band * 131) % 200 + 30;
    const b = (band * 29) % 200 + 30;
    return r << 16 | g << 8 | b;
}

fn avg(a: u32, b: u32) u32 {
    var out: u32 = 0;
    for ([_]u5{ 0, 8, 16 }) |s| out |= (((a >> s & 0xFF) + (b >> s & 0xFF)) / 2) << s;
    return out;
}

fn profilesOf(gpa: std.mem.Allocator, px: []const u32, w: u32, h: u32) ![]u16 {
    const out = try gpa.alloc(u16, @as(usize, h) * blocks);
    profiles(px, w, w, h, out);
    return out;
}

test "a scroll of half a pixel more or less lines up by profile" {
    const gpa = testing.allocator;
    const w = 256;
    const h = 200;
    var a: [w * h]u32 = undefined;
    var b: [w * h]u32 = undefined;
    halfPixelFrame(&a, w, h, 0);
    // scrolled by 61.5 rows: no row of b is a row of a
    halfPixelFrame(&b, w, h, 123);
    const pa = try profilesOf(gpa, &a, w, h);
    defer gpa.free(pa);
    const pb = try profilesOf(gpa, &b, w, h);
    defer gpa.free(pb);
    const d = (try findOffset(gpa, pa, pb, h, null)).?;
    try testing.expect(d == 61 or d == 62);
}

test "a move past the farthest distance looked at does not match there" {
    const gpa = testing.allocator;
    const rows = 200;
    const last = rows - rows / 10;
    const moved = last + 10;
    const pa = try gpa.alloc(u16, rows * blocks);
    defer gpa.free(pa);
    const pb = try gpa.alloc(u16, rows * blocks);
    defer gpa.free(pb);
    // rows unlike each other, but for a slow shade across the overlap:
    // the nearer to `moved`, the less it costs
    for (pa, 0..) |*v, i| v.* = @intCast(std.hash.Wyhash.hash(1, std.mem.asBytes(&i)) % 3000);
    for (pb, 0..) |*v, i| v.* = @intCast(std.hash.Wyhash.hash(2, std.mem.asBytes(&i)) % 3000);
    for (pa[(last - 10) * blocks ..], 0..) |*v, i| v.* = @intCast(1000 + (last - 10) + i / blocks);
    for (pb[0 .. 30 * blocks], 0..) |*v, i| v.* = @intCast(1000 + moved + i / blocks);
    try testing.expectEqual(@as(?u32, null), try findOffset(gpa, pa, pb, rows, null));
    try testing.expectEqual(@as(?u32, null), try findOffset(gpa, pa, pb, rows, last));
}

test "a page that changed altogether, or a blank one, does not line up" {
    const gpa = testing.allocator;
    const w = 128;
    const h = 120;
    var a: [w * h]u32 = undefined;
    var b: [w * h]u32 = undefined;
    halfPixelFrame(&a, w, h, 0);
    for (&b, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @truncate(std.hash.Wyhash.hash(i / w, "other")));
    const pa = try profilesOf(gpa, &a, w, h);
    defer gpa.free(pa);
    const pb = try profilesOf(gpa, &b, w, h);
    defer gpa.free(pb);
    try testing.expectEqual(@as(?u32, null), try findOffset(gpa, pa, pb, h, null));
    @memset(&a, 0xFFFFFFFF);
    const blank = try profilesOf(gpa, &a, w, h);
    defer gpa.free(blank);
    try testing.expectEqual(@as(?u32, null), try findOffset(gpa, blank, blank, h, null));
}

test "the stitcher carries on through half-pixel scrolls" {
    const Stitcher = @import("stitch.zig").Stitcher;
    const gpa = testing.allocator;
    const w = 256;
    const h = 200;
    var buf: [w * h]u32 = undefined;
    halfPixelFrame(&buf, w, h, 0);
    var st = try Stitcher.init(gpa, .{ .pixels = &buf, .width = w, .height = h }, 20_000);
    defer st.deinit();
    // four scrolls of 41.5 rows (83 half rows), as three notches of an
    // odd logical distance at 1.5
    var top2: u32 = 0;
    for (0..4) |_| {
        top2 += 83;
        halfPixelFrame(&buf, w, h, top2);
        const r = try st.push(.{ .pixels = &buf, .width = w, .height = h });
        try testing.expect(r == .appended);
        try testing.expect(r.appended == 41 or r.appended == 42);
    }
    // the image grew by the page's movement, within a row
    try testing.expect(@abs(@as(i64, st.totalHeight()) - (h + 166)) <= 2);
}

test "a frame that did not move but changed a little is still" {
    const gpa = testing.allocator;
    const w = 256;
    const h = 200;
    var a: [w * h]u32 = undefined;
    var b: [w * h]u32 = undefined;
    halfPixelFrame(&a, w, h, 40);
    b = a;
    // a glow over the bottom rows (GTK's overshoot at the end of a page)
    for (b[(h - 10) * w ..]) |*p| p.* = 0xFF000000 | avg(p.* & 0xFFFFFF, 0xFFFFFF);
    const pa = try profilesOf(gpa, &a, w, h);
    defer gpa.free(pa);
    const pb = try profilesOf(gpa, &b, w, h);
    defer gpa.free(pb);
    try testing.expectEqual(@as(?u32, 0), try findOffset(gpa, pa, pb, h, 1));
}
