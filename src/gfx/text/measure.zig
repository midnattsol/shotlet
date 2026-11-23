//! Text metrics: line widths, line height and ascent, and text cut with
//! an ellipsis to fit a width.

const std = @import("std");
const ttf = @import("../ttf.zig");
const bidi = @import("../bidi.zig");
const render = @import("../render.zig");
const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const utf8 = @import("../utf8.zig");

const Canvas = render.Canvas;
const Style = state_mod.Style;
const bitmapScale = state_mod.bitmapScale;

pub fn width(size_px: f64, s: []const u8) i32 {
    return widthStyled(size_px, .regular, s);
}

pub fn widthStyled(size_px: f64, style: Style, s: []const u8) i32 {
    return widthDir(size_px, style, s, .auto);
}

pub fn widthDir(size_px: f64, style: Style, s: []const u8, dir: bidi.Direction) i32 {
    return widthRange(size_px, style, s, 0, s.len, dir);
}

/// Width of the line made of bytes [la, lb) of paragraph `s`.
pub fn widthRange(size_px: f64, style: Style, s: []const u8, la: usize, lb: usize, dir: bidi.Direction) i32 {
    const st = if (state_mod.state) |*p| p else return Canvas.textWidth(bitmapScale(size_px), s[@min(la, s.len)..@min(lb, s.len)]);
    if (!(size_px > 0 and size_px <= ttf.max_size_px)) return 0;
    layout.ensureShaped(st, size_px, style, s, dir) catch return 0;
    const total = layout.rangeAdvance(st, la, lb);
    if (!(total < 1e9)) return std.math.maxInt(i32) / 2;
    return @intFromFloat(@ceil(total));
}

pub fn height(size_px: f64) i32 {
    return heightStyled(size_px, .regular);
}

pub fn heightStyled(size_px: f64, style: Style) i32 {
    const st = if (state_mod.state) |*p| p else return Canvas.textHeight(bitmapScale(size_px));
    const h = st.slots[st.styleSlot(style)].font.lineHeightPx(size_px);
    if (!(h >= 0 and h < 1e6)) return 0;
    return @intFromFloat(@ceil(h));
}

/// Distance from the top of a line to its baseline.
pub fn ascent(size_px: f64) i32 {
    const st = if (state_mod.state) |*p| p else return Canvas.textHeight(bitmapScale(size_px));
    const a = st.slots[st.regular].font.ascentPx(size_px);
    if (!(a >= 0 and a < 1e6)) return 0;
    return @intFromFloat(@round(a));
}

/// Which end of the text an ellipsis replaces.
pub const Elide = enum {
    /// "A long na…": keep the start (names, titles)
    end,
    /// "…/long/path": keep the tail (paths)
    start,
};

const ellipsis = "\u{2026}";

/// `s`, or `s` cut at a character boundary with "…" so it fits `max_w`
/// pixels, measured at `size` in `style`: the style it is drawn in (a
/// semibold title measured as regular would overflow). Writes into `buf`
/// when cutting; "…" alone when nothing else fits.
pub fn ellipsize(buf: []u8, size_px: f64, style: Style, s: []const u8, max_w: i32, side: Elide) []const u8 {
    if (widthStyled(size_px, style, s) <= max_w) return s;
    if (buf.len < ellipsis.len) return ellipsis;
    const room = buf.len - ellipsis.len;
    switch (side) {
        .end => {
            var n = utf8.truncate(s, room).len;
            while (n > 0) : (n = utf8.prevBoundary(s, n)) {
                const out = join(buf, s[0..n], ellipsis);
                if (widthStyled(size_px, style, out) <= max_w) return out;
            }
        },
        .start => {
            var a = s.len - @min(s.len, room);
            while (a < s.len and (s[a] & 0xC0) == 0x80) a += 1;
            while (a < s.len) : (a = utf8.nextBoundary(s, a)) {
                const out = join(buf, ellipsis, s[a..]);
                if (widthStyled(size_px, style, out) <= max_w) return out;
            }
        },
    }
    return ellipsis;
}

fn join(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "ellipsize cuts at either end with an ellipsis, measured in the drawn style" {
    const t = std.testing;
    state_mod.init(t.allocator);
    defer state_mod.deinit();
    var buf: [64]u8 = undefined;
    const s = "Saved \u{00B7} screenshot-2026-11-23.png";
    const full = widthStyled(14, .semibold, s);
    // fits: unchanged, no copy
    try t.expectEqual(s.ptr, ellipsize(&buf, 14, .semibold, s, full, .end).ptr);
    const max = @divTrunc(full, 2);
    const end = ellipsize(&buf, 14, .semibold, s, max, .end);
    try t.expect(std.mem.endsWith(u8, end, ellipsis));
    try t.expect(std.mem.startsWith(u8, s, end[0 .. end.len - ellipsis.len]));
    try t.expect(widthStyled(14, .semibold, end) <= max);
    const start = ellipsize(&buf, 14, .semibold, s, max, .start);
    try t.expect(std.mem.startsWith(u8, start, ellipsis));
    try t.expect(std.mem.endsWith(u8, s, start[ellipsis.len..]));
    try t.expect(widthStyled(14, .semibold, start) <= max);
    // the cut never splits a character
    for ([_][]const u8{ end, start }) |out| {
        var it = utf8.Iterator.init(out);
        while (it.next()) |cp| try t.expect(cp != utf8.replacement);
    }
    // nothing fits: the ellipsis alone; a tiny buffer: the ellipsis too
    try t.expectEqualStrings(ellipsis, ellipsize(&buf, 14, .semibold, s, 1, .end));
    var tiny: [2]u8 = undefined;
    try t.expectEqualStrings(ellipsis, ellipsize(&tiny, 14, .semibold, s, max, .start));
    // a buffer too small for the whole cut still gives valid text
    var small: [12]u8 = undefined;
    const e8 = "\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}\u{00E9}";
    const cut = ellipsize(&small, 14, .regular, e8, widthStyled(14, .regular, e8) - 1, .end);
    try t.expect(cut.len <= small.len and std.mem.endsWith(u8, cut, ellipsis));
    try t.expect((cut.len - ellipsis.len) % 2 == 0);
}

test "ellipsize measures semibold, not regular" {
    const t = std.testing;
    state_mod.init(t.allocator);
    defer state_mod.deinit();
    const s = "Recording saved to your Videos folder";
    var buf: [64]u8 = undefined;
    // a width the regular cut fits but the semibold one would not
    const max = widthStyled(13, .regular, s) - 4;
    const out = ellipsize(&buf, 13, .semibold, s, max, .end);
    try t.expect(widthStyled(13, .semibold, out) <= max);
}
