//! An embedded synthetic TrueType font and the parser fuzz tests built on
//! it (plus system fonts as extra seeds, when installed).

const std = @import("std");
const testutil = @import("../../testutil.zig");
const Font = @import("font.zig").Font;
const sfnt_truetype = @import("sfnt.zig").sfnt_truetype;

const Buf = std.ArrayList(u8);

fn u16be(l: *Buf, gpa: std.mem.Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try l.appendSlice(gpa, &b);
}

fn u32be(l: *Buf, gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try l.appendSlice(gpa, &b);
}

/// Build a tiny valid TrueType font: .notdef, a simple glyph for 'A' (a
/// square with one quadratic corner) and a composite for 'B' (two scaled
/// copies of 'A'), plus U+1F600 mapped to 'A' through cmap format 12.
fn buildTestFont(gpa: std.mem.Allocator) ![]u8 {
    var tables: [8]Buf = @splat(.empty);
    defer for (&tables) |*t| t.deinit(gpa);
    const tags = [8]*const [4]u8{ "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name" };

    try writeCmap(&tables[0], gpa);
    const loca = try writeGlyf(&tables[1], gpa);
    try writeMetrics(&tables[2], &tables[3], &tables[4], gpa);
    for (loca) |v| try u32be(&tables[5], gpa, v);
    const maxp = &tables[6];
    try u32be(maxp, gpa, 0x00005000);
    try u16be(maxp, gpa, 3);
    try u16be(&tables[7], gpa, 0);
    return assemble(gpa, &tables, &tags);
}

/// cmap: (3,1) format 4 + (3,10) format 12
fn writeCmap(cmap: *Buf, gpa: std.mem.Allocator) !void {
    try u16be(cmap, gpa, 0);
    try u16be(cmap, gpa, 2);
    try u16be(cmap, gpa, 3);
    try u16be(cmap, gpa, 1);
    try u32be(cmap, gpa, 20);
    try u16be(cmap, gpa, 3);
    try u16be(cmap, gpa, 10);
    try u32be(cmap, gpa, 20 + 32);
    // format 4: segments ['A','B'] -> 1,2 and the 0xFFFF terminator
    try u16be(cmap, gpa, 4);
    try u16be(cmap, gpa, 32);
    try u16be(cmap, gpa, 0);
    try u16be(cmap, gpa, 4); // segCountX2
    try u16be(cmap, gpa, 4);
    try u16be(cmap, gpa, 1);
    try u16be(cmap, gpa, 0);
    try u16be(cmap, gpa, 'B'); // endCode
    try u16be(cmap, gpa, 0xFFFF);
    try u16be(cmap, gpa, 0); // pad
    try u16be(cmap, gpa, 'A'); // startCode
    try u16be(cmap, gpa, 0xFFFF);
    try u16be(cmap, gpa, @bitCast(@as(i16, 1 - 'A'))); // delta
    try u16be(cmap, gpa, 1);
    try u16be(cmap, gpa, 0); // rangeOffset
    try u16be(cmap, gpa, 0);
    // format 12: 'A'..'B' -> 1, U+1F600 -> 1
    try u16be(cmap, gpa, 12);
    try u16be(cmap, gpa, 0);
    try u32be(cmap, gpa, 16 + 2 * 12);
    try u32be(cmap, gpa, 0);
    try u32be(cmap, gpa, 2);
    for ([_][3]u32{ .{ 'A', 'B', 1 }, .{ 0x1F600, 0x1F600, 1 } }) |g| {
        for (g) |v| try u32be(cmap, gpa, v);
    }
}

/// glyf: glyph 0 empty, glyph 1 simple, glyph 2 composite. Returns loca.
fn writeGlyf(glyf: *Buf, gpa: std.mem.Allocator) ![4]u32 {
    var loca: [4]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    try u16be(glyf, gpa, 1); // one contour
    for ([_]u16{ 0, 0, 600, 700 }) |v| try u16be(glyf, gpa, v); // bbox
    try u16be(glyf, gpa, 4); // endPts[0]: 5 points
    try u16be(glyf, gpa, 0); // no instructions
    const flags = [_]u8{ 1, 1, 0, 1, 1 }; // point 2 off-curve
    try glyf.appendSlice(gpa, &flags);
    const xs = [_]i16{ 50, 500, 50, 0, -500 };
    const ys = [_]i16{ 50, 0, 300, 300, -100 };
    for (xs) |v| try u16be(glyf, gpa, @bitCast(v));
    for (ys) |v| try u16be(glyf, gpa, @bitCast(v));
    while (glyf.items.len % 4 != 0) try glyf.append(gpa, 0);
    loca[2] = @intCast(glyf.items.len);
    try u16be(glyf, gpa, @bitCast(@as(i16, -1)));
    for ([_]u16{ 0, 0, 600, 700 }) |v| try u16be(glyf, gpa, v);
    // component 1: words + xy + scale + more components
    try u16be(glyf, gpa, 0x0001 | 0x0002 | 0x0008 | 0x0020);
    try u16be(glyf, gpa, 1);
    try u16be(glyf, gpa, 0);
    try u16be(glyf, gpa, 0);
    try u16be(glyf, gpa, 0x2000); // scale 0.5
    // component 2: bytes + xy + 2x2
    try u16be(glyf, gpa, 0x0002 | 0x0080);
    try u16be(glyf, gpa, 1);
    try glyf.appendSlice(gpa, &.{ 100, 50 });
    for ([_]u16{ 0x2000, 0, 0x0800, 0x2000 }) |v| try u16be(glyf, gpa, v);
    while (glyf.items.len % 4 != 0) try glyf.append(gpa, 0);
    loca[3] = @intCast(glyf.items.len);
    return loca;
}

/// head (1000 upem, long loca), hhea (800/-200, 3 metrics) and hmtx.
fn writeMetrics(head: *Buf, hhea: *Buf, hmtx: *Buf, gpa: std.mem.Allocator) !void {
    try head.appendNTimes(gpa, 0, 54);
    std.mem.writeInt(u16, head.items[18..20], 1000, .big);
    std.mem.writeInt(i16, head.items[50..52], 1, .big); // long loca
    try hhea.appendNTimes(gpa, 0, 36);
    std.mem.writeInt(i16, hhea.items[4..6], 800, .big);
    std.mem.writeInt(i16, hhea.items[6..8], -200, .big);
    std.mem.writeInt(u16, hhea.items[34..36], 3, .big);
    for (0..3) |_| {
        try u16be(hmtx, gpa, 650);
        try u16be(hmtx, gpa, 0);
    }
}

/// Lay out the sfnt header, table directory and 4-aligned tables.
fn assemble(gpa: std.mem.Allocator, tables: []const Buf, tags: []const *const [4]u8) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);
    try u32be(&out, gpa, sfnt_truetype);
    try u16be(&out, gpa, @intCast(tables.len));
    try out.appendNTimes(gpa, 0, 6);
    var off: u32 = @intCast(12 + 16 * tables.len);
    for (tables, tags) |t, tag| {
        try out.appendSlice(gpa, tag);
        try u32be(&out, gpa, 0);
        try u32be(&out, gpa, off);
        try u32be(&out, gpa, @intCast(t.items.len));
        off += @intCast((t.items.len + 3) / 4 * 4);
    }
    for (tables) |t| {
        try out.appendSlice(gpa, t.items);
        while (out.items.len % 4 != 0) try out.append(gpa, 0);
    }
    return out.toOwnedSlice(gpa);
}

test "embedded test font: simple, composite and format 12 glyphs" {
    const gpa = std.testing.allocator;
    const data = try buildTestFont(gpa);
    defer gpa.free(data);
    var font = try Font.parse(gpa, data, 0);
    defer font.deinit();
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 2), font.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex(0x1F600));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex('C'));
    const g = try font.rasterize(1, 20);
    try std.testing.expect(g.w >= 8 and g.h >= 8);
    const c = try font.rasterize(2, 20);
    try std.testing.expect(c.w > 0);
}

/// Parse and rasterize mutated copies of `seed`: every outcome must be an
/// error or a glyph, never a panic, hang or leak.
fn fuzzFont(gpa: std.mem.Allocator, seed: []const u8, iterations: usize, rng_seed: u64, max_glyphs: u16) !void {
    var prng = std.Random.DefaultPrng.init(rng_seed);
    const r = prng.random();
    const buf = try gpa.alloc(u8, seed.len);
    defer gpa.free(buf);
    const extremes = [_]u32{ 0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x7FFFFFFF, 0xFFFFFFFF, 0x10000 };
    for (0..iterations) |_| {
        @memcpy(buf, seed);
        var len = seed.len;
        const n_mut = r.intRangeAtMost(u8, 1, 12);
        for (0..n_mut) |_| {
            // half the mutations land in the header and table directory
            const span = if (r.boolean()) @min(len, 512) else len;
            if (span < 4) break;
            const at = r.uintLessThan(usize, span - 3);
            switch (r.intRangeAtMost(u8, 0, 3)) {
                0 => buf[at] = r.int(u8),
                1 => buf[at] ^= @as(u8, 1) << r.int(u3),
                2 => std.mem.writeInt(u32, buf[at..][0..4], extremes[r.uintLessThan(usize, extremes.len)], .big),
                else => std.mem.writeInt(u16, buf[at..][0..2], @truncate(extremes[r.uintLessThan(usize, extremes.len)]), .big),
            }
            if (r.intRangeAtMost(u8, 0, 30) == 0) len = r.intRangeAtMost(usize, 0, len);
        }
        var font = Font.parse(gpa, buf[0..len], r.intRangeAtMost(u32, 0, 1)) catch continue;
        defer font.deinit();
        for ([_]u21{ 'A', 'g', 0xE9, 0x20AC, 0x6F22, 0x1F600, 0x10FFFF }) |cp| {
            _ = try font.rasterize(font.glyphIndex(cp), 17);
        }
        var gid: u16 = 0;
        while (gid < @min(font.num_glyphs, max_glyphs)) : (gid += 1) {
            _ = try font.rasterize(gid, 9);
        }
        _ = try font.rasterize(r.int(u16), 31);
    }
}

test "font parser survives mutated fonts" {
    const gpa = std.testing.allocator;
    const embedded = try buildTestFont(gpa);
    defer gpa.free(embedded);
    try fuzzFont(gpa, embedded, 3000, 1, 8);

    const fonts = testutil.fonts;
    const seeds = [_]struct { path: []const u8, iters: usize, glyphs: u16 }{
        .{ .path = fonts.noto_lycian, .iters = 400, .glyphs = 64 },
        .{ .path = fonts.standard_symbols, .iters = 150, .glyphs = 256 },
        .{ .path = fonts.dingbats, .iters = 100, .glyphs = 256 },
        .{ .path = fonts.dejavu_sans, .iters = 40, .glyphs = 200 },
    };
    for (seeds, 0..) |s, i| {
        const data = (try testutil.optionalFile(s.path, 2 * 1024 * 1024)) orelse continue;
        defer gpa.free(data);
        try fuzzFont(gpa, data, s.iters, 10 + i, s.glyphs);
    }
}
