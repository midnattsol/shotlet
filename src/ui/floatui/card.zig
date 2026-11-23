//! Cards on the see-through floating windows: an opaque card placed with
//! rounded corners and a theme shadow (its mask cached across frames),
//! the same faded as a whole, a picture fitted into a card (and cached
//! per size), and dragging a file out of a card. Straight alpha
//! throughout (see ui/floatui.zig).

const std = @import("std");
const effects = @import("../../gfx/effects.zig");
const resample = @import("../../gfx/resample.zig");
const theme = @import("../theme.zig");
const material = @import("../material.zig");
const Rect = @import("../shapes.zig").Rect;
const window = @import("../../platform/api.zig").window;
const pixels = @import("../floatui.zig");

/// A straight-alpha buffer to draw on.
pub const Surface = struct { px: []u32, w: u32, h: u32 };
/// Pixels to read: a card, a picture.
pub const Image = struct { px: []const u32, w: u32, h: u32 };

/// The opaque `card` with corners rounded to `radius` and the shadow `sh`
/// (null: none) at scale `k`, onto `dst` with its top-left corner at `at`.
pub fn place(dst: Surface, card: Image, at: [2]i32, radius: f64, sh: ?theme.Shadow, k: f64) void {
    if (sh) |s| {
        const r: Rect = .{ .x = at[0], .y = at[1], .w = @intCast(card.w), .h = @intCast(card.h) };
        material.shadowStraight(shadow_alloc, dst.px, dst.w, dst.h, r, radius, s, k, 1, shadowCache(.{ .w = card.w, .h = card.h, .radius = radius, .sh = s, .k = k }));
    }
    effects.blitRounded(dst.px, dst.w, dst.h, card.px, card.w, card.h, at[0], at[1], radius);
}

/// What a shadow's mask depends on.
const ShadowKey = struct { w: u32, h: u32, radius: f64, sh: theme.Shadow, k: f64 };

/// The shadows' masks, kept from frame to frame: a floating window
/// repaints its cards (fades, hovers, a growing picture) far more often
/// than their size, corners or shadow change. A few at once: a stack's
/// cards and its hint, a pin and its menu. Like the icons' masks
/// (ui/icons.zig) they live as long as the process.
var shadows: [4]struct { key: ?ShadowKey = null, used: u64 = 0, cache: material.ShadowCache = .{} } = @splat(.{});
var shadow_tick: u64 = 0;
const shadow_alloc = std.heap.page_allocator;

/// The cache holding `key`'s mask, else the least recently used one
/// (material.ShadowCache rebuilds it for the new key).
fn shadowCache(key: ShadowKey) *material.ShadowCache {
    shadow_tick += 1;
    var pick: usize = 0;
    for (&shadows, 0..) |*e, i| {
        if (e.key) |kk| if (std.meta.eql(kk, key)) {
            pick = i;
            break;
        };
        if (e.used < shadows[pick].used) pick = i;
    }
    shadows[pick].key = key;
    shadows[pick].used = shadow_tick;
    return &shadows[pick].cache;
}

/// `place`, on a layer of its own faded to `alpha` (0..1) as a whole,
/// then over `dst`: cards fading in and out, or dimmed while dragged.
pub fn compositeFaded(gpa: std.mem.Allocator, dst: Surface, card: Image, at: [2]i32, radius: f64, sh: ?theme.Shadow, alpha: f64, k: f64) !void {
    if (alpha <= 0.001) return;
    const box: Rect = .ofSize(card.w, card.h);
    const fr = if (sh) |s| material.shadowFootprint(box, s, k) else box;
    const lw: u32 = @intCast(fr.w);
    const lh: u32 = @intCast(fr.h);
    const layer = try gpa.alloc(u32, @as(usize, lw) * lh);
    defer gpa.free(layer);
    @memset(layer, 0);
    place(.{ .px = layer, .w = lw, .h = lh }, card, .{ -fr.x, -fr.y }, radius, sh, k);
    pixels.fadeAlpha(layer, alpha);
    pixels.blitOver(dst.px, dst.w, dst.h, layer, lw, lh, at[0] + fr.x, at[1] + fr.y);
}

/// How a picture fills a card: resample.Fit, or `auto`: cover when the
/// shapes are close, else contain (a thumbnail shows a tall strip whole).
pub const FitMode = enum { contain, cover, auto };

/// Where `mode` puts a sw x sh picture in a dw x dh card.
pub fn fitPlan(sw: u32, sh: u32, dw: u32, dh: u32, mode: FitMode) resample.Placement {
    const m: resample.Fit = switch (mode) {
        .contain => .contain,
        .cover => .cover,
        .auto => blk: {
            const ratio = (@as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(sh))) / (@as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(dh)));
            break :blk if (ratio > 0.7 and ratio < 1.4) .cover else .contain;
        },
    };
    return resample.fit(sw, sh, dw, dh, m);
}

/// `src` fitted into all of `dst` by `mode` over `bg`, area-filtered
/// (gfx/resample.zig). Worth caching: see FitCache.
pub fn drawImage(gpa: std.mem.Allocator, dst: Surface, src: Image, mode: FitMode, bg: u32) void {
    @memset(dst.px[0 .. @as(usize, dst.w) * dst.h], bg);
    if (src.w == 0 or src.h == 0 or dst.w == 0 or dst.h == 0) return;
    const f = fitPlan(src.w, src.h, dst.w, dst.h, mode);
    const tmp = gpa.alloc(u32, @as(usize, f.w) * f.h) catch return;
    defer gpa.free(tmp);
    resample.region(gpa, src.px, src.w, src.h, f.src, tmp, f.w, f.h) catch return;
    pixels.blitOver(dst.px, dst.w, dst.h, tmp, f.w, f.h, f.x, f.y);
}

/// A picture fitted to a card, redrawn only when the size, the mode or
/// the picture change.
pub const FitCache = struct {
    px: []u32 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    mode: FitMode = .auto,
    src_ptr: usize = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,

    /// `src` fitted into w x h by `mode` over `bg`.
    pub fn ensure(self: *FitCache, gpa: std.mem.Allocator, src: Image, w: u32, h: u32, mode: FitMode, bg: u32) ![]const u32 {
        const ptr = @intFromPtr(src.px.ptr);
        if (self.w == w and self.h == h and self.mode == mode and self.src_ptr == ptr and self.src_w == src.w and self.src_h == src.h and self.px.len > 0)
            return self.px;
        gpa.free(self.px);
        self.* = .{};
        self.px = try gpa.alloc(u32, @as(usize, w) * h);
        self.* = .{ .px = self.px, .w = w, .h = h, .mode = mode, .src_ptr = ptr, .src_w = src.w, .src_h = src.h };
        drawImage(gpa, .{ .px = self.px, .w = w, .h = h }, src, mode, bg);
        return self.px;
    }

    pub fn deinit(self: *FitCache, gpa: std.mem.Allocator) void {
        gpa.free(self.px);
        self.* = .{};
    }
};

/// Dragging a file out of a floating window: start it, then poll each
/// turn of the event loop until the drop finished or was cancelled.
pub const DragOut = struct {
    active: bool = false,

    pub const Outcome = enum {
        /// the target took the data
        finished,
        /// nobody took it
        cancelled,
    };

    /// Start dragging `data` (PNG bytes, or a poster) with `uri` (a
    /// text/uri-list); both pass to the window on success.
    pub fn start(self: *DragOut, win: *window.Window, data: []u8, uri: []u8, icon: ?window.DragIcon) !void {
        try win.startDrag(0, data, uri, icon);
        self.active = true;
    }

    /// How the drag ended, once (ending it in the window); null while it
    /// goes on or when none is active.
    pub fn poll(self: *DragOut, win: *window.Window) ?Outcome {
        if (!self.active) return null;
        const out: Outcome = switch (win.drag_state) {
            .finished => .finished,
            .cancelled => .cancelled,
            else => return null,
        };
        win.endDrag();
        self.active = false;
        return out;
    }
};

/// Behind a dragged picture whose shape does not fill the icon
const letterbox: u32 = 0xFF2A2E37;

/// The image under the pointer while dragging a card out: the picture at
/// w x h, rounded, a little see-through, premultiplied (caller frees).
/// `k` is the integer buffer scale the icon is drawn at.
pub fn dragIcon(gpa: std.mem.Allocator, src: Image, w: u32, h: u32, k: i32) ![]u32 {
    const out = try gpa.alloc(u32, @as(usize, w) * h);
    errdefer gpa.free(out);
    @memset(out, 0);
    const pic = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(pic);
    drawImage(gpa, .{ .px = pic, .w = w, .h = h }, src, .auto, letterbox);
    effects.blitRounded(out, w, h, pic, w, h, 0, 0, @floatFromInt(10 * @max(1, k)));
    pixels.fadeAlpha(out, 0.92);
    pixels.premultiply(out, w, h, .ofSize(w, h));
    return out;
}

const testing = std.testing;

test "a placed card keeps its corners clear and casts a shadow below" {
    var dst: [60 * 60]u32 = @splat(0);
    const card: [30 * 20]u32 = @splat(0xFF336699);
    const sh: theme.Shadow = .{ .color = 0x80000000, .blur = 8, .dy = 3 };
    place(.{ .px = &dst, .w = 60, .h = 60 }, .{ .px = &card, .w = 30, .h = 20 }, .{ 15, 15 }, 6, sh, 1);
    try testing.expectEqual(@as(u32, 0xFF336699), dst[25 * 60 + 30]);
    try testing.expect(dst[15 * 60 + 15] != 0xFF336699); // the corner is rounded
    try testing.expect(dst[37 * 60 + 30] >> 24 > 0); // the shadow under it
    try testing.expectEqual(@as(u32, 0), dst[0]);
}

test "a faded card is the placed card at that opacity" {
    const gpa = testing.allocator;
    var dst: [60 * 60]u32 = @splat(0);
    const card: [30 * 20]u32 = @splat(0xFF336699);
    try compositeFaded(gpa, .{ .px = &dst, .w = 60, .h = 60 }, .{ .px = &card, .w = 30, .h = 20 }, .{ 15, 15 }, 6, theme.Theme.get(true, null).card_shadow, 0.5, 1);
    const p = dst[25 * 60 + 30];
    try testing.expectEqual(@as(u32, 0x336699), p & 0xFFFFFF);
    try testing.expect(p >> 24 >= 0x7E and p >> 24 <= 0x81);
    // fully faded: nothing drawn
    var none: [10 * 10]u32 = @splat(0);
    try compositeFaded(gpa, .{ .px = &none, .w = 10, .h = 10 }, .{ .px = &card, .w = 30, .h = 20 }, .{ 0, 0 }, 6, null, 0, 1);
    for (none) |q| try testing.expectEqual(@as(u32, 0), q);
}

test "pictures cover close shapes and fit very different ones" {
    const a = fitPlan(1600, 1000, 240, 150, .auto);
    try testing.expectApproxEqAbs(@as(f64, 1600), a.src.w, 1e-6);
    const b = fitPlan(1600, 1200, 240, 150, .auto);
    try testing.expectApproxEqAbs(@as(f64, 100), b.src.y, 1e-6);
    const c = fitPlan(100, 1000, 240, 150, .auto);
    try testing.expectEqual(@as(u32, 15), c.w);
    try testing.expectEqual(@as(i32, 112), c.x);
    try testing.expectEqual(@as(u32, 240), fitPlan(100, 1000, 240, 150, .cover).w);
}

test "the fit cache redraws only when something changed" {
    const gpa = testing.allocator;
    var fc: FitCache = .{};
    defer fc.deinit(gpa);
    const pic: [4 * 4]u32 = @splat(0xFFFF0000);
    const a = try fc.ensure(gpa, .{ .px = &pic, .w = 4, .h = 4 }, 8, 8, .cover, 0xFF000000);
    try testing.expectEqual(@as(u32, 0xFFFF0000), a[0]);
    const b = try fc.ensure(gpa, .{ .px = &pic, .w = 4, .h = 4 }, 8, 8, .cover, 0xFF000000);
    try testing.expectEqual(a.ptr, b.ptr);
    const c = try fc.ensure(gpa, .{ .px = &pic, .w = 4, .h = 4 }, 6, 8, .contain, 0xFF000000);
    try testing.expectEqual(@as(usize, 48), c.len);
    const icon = try dragIcon(gpa, .{ .px = &pic, .w = 4, .h = 4 }, 40, 25, 1);
    defer gpa.free(icon);
    try testing.expectEqual(@as(u32, 0), icon[0]);
}
