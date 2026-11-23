//! Layout and drawing of the trim window (trimui.zig), in logical
//! pixels: the preview, the filmstrip with its start and end handles and
//! the playhead, and a row with play/pause, the times and the buttons.
//! The window follows the desktop's light or dark look and accent
//! (theme.Opaque); the handles stay yellow, as on any video editor.

const std = @import("std");
const render = @import("../../gfx/render.zig");
const text = @import("../../gfx/text.zig");
const resample = @import("../../gfx/resample.zig");
const fui = @import("../floatui.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");
const barkit = @import("../barkit.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const Rect = @import("../shapes.zig").Rect;

pub const width = 720;
pub const height = 372;
const margin = 16;
pub const preview: Rect = .{ .x = margin, .y = margin, .w = width - 2 * margin, .h = 236 };
pub const strip: Rect = .{ .x = margin + 10, .y = 268, .w = width - 2 * margin - 20, .h = 44 };
const row_y = 324;

pub const Part = enum { play, cancel, save, start, end, strip };

pub fn partRect(p: Part) Rect {
    return switch (p) {
        .play => .{ .x = margin, .y = row_y, .w = 36, .h = 32 },
        .save => .{ .x = width - margin - 132, .y = row_y, .w = 132, .h = 32 },
        .cancel => .{ .x = width - margin - 132 - 8 - 90, .y = row_y, .w = 90, .h = 32 },
        .strip, .start, .end => strip,
    };
}

pub const State = struct {
    duration_ms: i64,
    start_ms: i64,
    end_ms: i64,
    pos_ms: i64,
    playing: bool = false,
    hover: ?Part = null,
    busy: []const u8 = "",
    pic: []const u32 = &.{},
    pic_w: u32 = 0,
    pic_h: u32 = 0,
    /// which strip picture `pic` is (a new one is resampled anew)
    pic_index: usize = 0,
    strip_px: []const u32 = &.{},
    strip_w: u32 = 0,
    strip_h: u32 = 0,
    /// the desktop's appearance (trimui.zig loads it)
    th: theme.Theme = theme.Theme.get(true, null),
};

pub fn xOf(ms: i64, duration: i64) i32 {
    const d = @max(1, duration);
    return strip.x + @as(i32, @intCast(@divTrunc(std.math.clamp(ms, 0, d) * strip.w, d)));
}

pub fn msAt(x: i32, duration: i64) i64 {
    const rel = std.math.clamp(x - strip.x, 0, strip.w);
    return @divTrunc(@as(i64, rel) * duration, strip.w);
}

const buttons = [_]press.Target(Part){
    .{ .r = partRect(.play), .t = .play },
    .{ .r = partRect(.cancel), .t = .cancel },
    .{ .r = partRect(.save), .t = .save },
};

pub fn hit(x: i32, y: i32, st: *const State) ?Part {
    if (press.hitTest(Part, &buttons, x, y)) |p| return p;
    if (y < strip.y - 6 or y >= strip.y + strip.h + 6) return null;
    const sx = xOf(st.start_ms, st.duration_ms);
    const ex = xOf(st.end_ms, st.duration_ms);
    if (@abs(x - sx) <= 10) return .start;
    if (@abs(x - ex) <= 10) return .end;
    if (x >= strip.x - 10 and x < strip.x + strip.w + 10) return .strip;
    return null;
}

const px = scale.px;

/// the start and end handles, and their grips
const handle: u32 = 0xFFFFCC00;
const handle_grip: u32 = 0xFF6B5300;

/// The window's hairline edge (ui/frame.zig).
pub fn edge(th: theme.Theme) u32 {
    return th.hairline;
}

/// The preview and the strip at the window's size, resampled when the
/// picture or the size changes, not every frame (dragging a handle or
/// playing redraws them a lot).
pub const Cache = struct {
    preview: Block = .{},
    strip: Block = .{},

    const Block = struct {
        px: []u32 = &.{},
        key: [4]usize = @splat(0),

        /// The block for `key`, null when it must be made anew (then
        /// `px` is w x h, to fill).
        fn get(b: *Block, gpa: std.mem.Allocator, key: [4]usize, w: u32, h: u32) !?[]const u32 {
            if (b.px.len > 0 and std.mem.eql(usize, &b.key, &key)) return b.px;
            gpa.free(b.px);
            b.px = &.{};
            b.px = try gpa.alloc(u32, @as(usize, w) * h);
            b.key = key;
            return null;
        }
    };

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        gpa.free(self.preview.px);
        gpa.free(self.strip.px);
        self.* = .{};
    }
};

pub fn paint(gpa: std.mem.Allocator, cv: *render.Canvas, k: f64, st: *const State, cache: *Cache) void {
    const o = theme.Opaque.of(st.th);
    @memset(cv.px, o.panel);
    paintPreview(gpa, cv, k, st, &cache.preview);
    paintStrip(gpa, cv, k, st, o, &cache.strip);
    paintRow(cv, k, st, o);
}

/// Copy a w x h block into the canvas at r's top-left.
fn blit(cv: *render.Canvas, r: Rect, buf: []const u32, w: u32, h: u32) void {
    const cw: usize = @intCast(cv.w);
    for (0..h) |y| @memcpy(cv.px[(@as(usize, @intCast(r.y)) + y) * cw + @as(usize, @intCast(r.x)) ..][0..w], buf[y * w ..][0..w]);
}

/// The picture at the playhead, letterboxed (never cropped) on black.
fn paintPreview(gpa: std.mem.Allocator, cv: *render.Canvas, k: f64, st: *const State, b: *Cache.Block) void {
    const r = scale.rect(preview, k);
    if (st.pic_w == 0) return;
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    const made = (b.get(gpa, .{ st.pic_index, @intFromPtr(st.pic.ptr), w, h }, w, h) catch return) orelse blk: {
        fui.drawImage(gpa, .{ .px = b.px, .w = w, .h = h }, .{ .px = st.pic, .w = st.pic_w, .h = st.pic_h }, .contain, 0xFF000000);
        for (b.px) |*p| p.* |= 0xFF000000;
        break :blk b.px;
    };
    blit(cv, r, made, w, h);
}

fn paintStrip(gpa: std.mem.Allocator, cv: *render.Canvas, k: f64, st: *const State, o: theme.Opaque, b: *Cache.Block) void {
    const r = scale.rect(strip, k);
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    if (st.strip_w > 0) {
        const made = (b.get(gpa, .{ @intFromPtr(st.strip_px.ptr), st.strip_w, w, h }, w, h) catch return) orelse blk: {
            resample.box(st.strip_px, st.strip_w, st.strip_w, st.strip_h, b.px, w, h);
            break :blk b.px;
        };
        blit(cv, r, made, w, h);
    } else cv.fillRect(r.x, r.y, r.w, r.h, o.field);
    const sx = px(xOf(st.start_ms, st.duration_ms), k);
    const ex = px(xOf(st.end_ms, st.duration_ms), k);
    // outside the range: dimmed
    const veil = st.th.scrim(.pill);
    cv.fillRect(r.x, r.y, sx - r.x, r.h, veil);
    cv.fillRect(ex, r.y, r.x + r.w - ex, r.h, veil);
    const bw = px(3, k);
    cv.fillRect(sx, r.y - bw, ex - sx, bw, handle);
    cv.fillRect(sx, r.y + r.h, ex - sx, bw, handle);
    for ([_]i32{ sx, ex }, 0..) |x, i| {
        const hx = if (i == 0) x - px(10, k) else x;
        cv.fillRoundRectAA(hx, r.y - bw, px(10, k), r.h + 2 * bw, 3 * k, handle);
        cv.fillRect(hx + px(4, k), r.y + @divTrunc(r.h, 2) - px(7, k), px(2, k), px(14, k), handle_grip);
    }
    const ph = px(xOf(st.pos_ms, st.duration_ms), k);
    cv.fillRoundRectAA(ph - px(1, k), r.y - px(6, k), px(3, k), r.h + px(12, k), 1.5 * k, st.th.on_scrim);
}

fn paintRow(cv: *render.Canvas, k: f64, st: *const State, o: theme.Opaque) void {
    const p = scale.rect(partRect(.play), k);
    if (st.hover == .play) cv.fillRoundRectAA(p.x, p.y, p.w, p.h, 8 * k, o.hover);
    icons.drawAt(cv, if (st.playing) .pause else .play, scale.ff(p.x) + scale.ff(p.w) / 2, scale.ff(p.y) + scale.ff(p.h) / 2, 18 * k, .{}, o.fg);
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var c: [96]u8 = undefined;
    const full = std.fmt.bufPrint(&c, "{s} \u{2013} {s}   \u{00B7}   {s}", .{ fmtMs(&a, st.start_ms), fmtMs(&b, st.end_ms), if (st.busy.len > 0) st.busy else lengthLabel(st) }) catch "";
    const fs = 13 * k;
    const lx = p.x + p.w + px(12, k);
    var eb: [100]u8 = undefined;
    const label = text.ellipsize(&eb, fs, text.Style.regular.num(), full, px(partRect(.cancel).x - 12, k) - lx, .end);
    text.drawStyled(cv, lx, p.y + @divTrunc(p.h - text.height(fs), 2), fs, o.muted, text.Style.regular.num(), label);
    for ([_]Part{ .cancel, .save }) |part| {
        const r = scale.rect(partRect(part), k);
        const hover: f64 = if (st.hover == part) 1 else 0;
        if (part == .save)
            barkit.textButton(cv, r, k, st.th, .primary, hover, "Save trimmed")
        else
            barkit.textButton(cv, r, k, st.th, .secondary, hover, "Cancel");
    }
}

var len_buf: [32]u8 = undefined;
fn lengthLabel(st: *const State) []const u8 {
    const ms = st.end_ms - st.start_ms;
    return std.fmt.bufPrint(&len_buf, "{d}.{d} s", .{ @divTrunc(ms, 1000), @divTrunc(@mod(ms, 1000), 100) }) catch "";
}

pub fn fmtMs(buf: []u8, ms: i64) []const u8 {
    const t: u64 = @intCast(@max(0, ms));
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d}", .{ t / 60000, t / 1000 % 60, t / 100 % 10 }) catch "";
}

test "timeline positions and hits" {
    const st: State = .{ .duration_ms = 4000, .start_ms = 1000, .end_ms = 3000, .pos_ms = 1000 };
    try std.testing.expectEqual(@as(i64, 1000), msAt(xOf(1000, 4000), 4000));
    try std.testing.expectEqual(@as(?Part, .start), hit(xOf(1000, 4000) + 3, strip.y + 10, &st));
    try std.testing.expectEqual(@as(?Part, .end), hit(xOf(3000, 4000) - 3, strip.y + 10, &st));
    try std.testing.expectEqual(@as(?Part, .strip), hit(xOf(2000, 4000), strip.y + 10, &st));
    try std.testing.expectEqual(@as(?Part, .save), hit(width - 30, row_y + 10, &st));
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1:02.5", fmtMs(&buf, 62_500));
}

test "Save is drawn in the accent" {
    const gpa = std.testing.allocator;
    text.init(gpa);
    defer text.deinit();
    defer icons.deinit();
    const th = theme.Theme.get(false, 0xFF2EC27E);
    const buf = try gpa.alloc(u32, width * height);
    defer gpa.free(buf);
    var cv = render.Canvas.init(buf, width, height);
    const st: State = .{ .duration_ms = 4000, .start_ms = 0, .end_ms = 4000, .pos_ms = 0, .th = th };
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    paint(gpa, &cv, 1, &st, &cache);
    const r = partRect(.save);
    try std.testing.expectEqual(th.accent_fill, buf[@intCast((r.y + 3) * width + r.x + 8)]);
    try std.testing.expectEqual(theme.Opaque.of(th).panel, buf[2 * width + 2]);
}

test "the preview and the strip are resampled once, not every frame" {
    const gpa = std.testing.allocator;
    text.init(gpa);
    defer text.deinit();
    defer icons.deinit();
    const buf = try gpa.alloc(u32, width * height);
    defer gpa.free(buf);
    var cv = render.Canvas.init(buf, width, height);
    var pic: [16 * 9]u32 = @splat(0xFF336699);
    var strip_px: [64 * 9]u32 = @splat(0xFF996633);
    var st: State = .{ .duration_ms = 4000, .start_ms = 0, .end_ms = 4000, .pos_ms = 0, .pic = &pic, .pic_w = 16, .pic_h = 9, .strip_px = &strip_px, .strip_w = 64, .strip_h = 9 };
    var cache: Cache = .{};
    defer cache.deinit(gpa);
    paint(gpa, &cv, 1, &st, &cache);
    const made = .{ cache.preview.px.ptr, cache.strip.px.ptr };
    // a handle dragged, the playhead moved: the same blocks
    st.start_ms = 500;
    st.pos_ms = 700;
    paint(gpa, &cv, 1, &st, &cache);
    try std.testing.expectEqual(made[0], cache.preview.px.ptr);
    try std.testing.expectEqual(made[1], cache.strip.px.ptr);
    // another strip picture: the preview anew, the strip kept
    st.pic_index = 1;
    paint(gpa, &cv, 1, &st, &cache);
    try std.testing.expect(cache.preview.key[0] == 1);
    try std.testing.expectEqual(made[1], cache.strip.px.ptr);
}
