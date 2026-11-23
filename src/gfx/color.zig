//! Colour maths on 0xAARRGGBB values, one implementation for everything
//! that mixes, composites or checks the contrast of colours (ui/theme.zig
//! re-exports these).
//!
//! Stable API:
//!   mix(a, b, t)          channel-wise blend, alpha included; t clamped to 0..1
//!   over(dst, src)        `src` composited over `dst` (straight alpha; opaque
//!                         when dst is)
//!   withAlpha(c, a), fade(c, k)   replace / scale a colour's alpha
//!   luminance(c)          WCAG relative luminance (alpha ignored)
//!   contrast(a, b)        WCAG contrast ratio, 1..21
//!   legible(c, bg, min)   `c` darkened or lightened until it reaches `min`
//!                         contrast on `bg`

const std = @import("std");

/// Channel-wise blend of two colours, alpha included, rounded; `t` is
/// clamped to 0..1 (NaN counts as 0).
pub fn mix(a: u32, b: u32, t: f64) u32 {
    const k: f64 = if (t > 0) @min(t, 1) else 0;
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |sh| {
        const ca: f64 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f64 = @floatFromInt((b >> sh) & 0xFF);
        out |= @as(u32, @intFromFloat(@round(ca + (cb - ca) * k))) << sh;
    }
    return out;
}

/// `src` over `dst`, both 0xAARRGGBB in straight alpha; the result is
/// opaque when `dst` is.
pub fn over(dst: u32, src: u32) u32 {
    const sa = (src >> 24) & 0xFF;
    if (sa == 0) return dst;
    if (sa == 255) return src;
    const inv = 255 - sa;
    const V = @Vector(4, u32);
    const s: V = @as(@Vector(4, u8), @bitCast(src));
    const d: V = @as(@Vector(4, u8), @bitCast(dst));
    // floor(x / 255) == (x * 0x8081) >> 23 for every x <= 255 * 255
    const da = (dst >> 24) & 0xFF;
    if (da == 255) {
        const m = ((s * @as(V, @splat(sa)) + d * @as(V, @splat(inv))) * @as(V, @splat(0x8081))) >> @splat(23);
        var out: @Vector(4, u8) = @intCast(m);
        out[3] = 255;
        return @bitCast(out);
    }
    // translucent destination (a see-through surface): straight alpha,
    // so edges over nothing keep their colour instead of darkening
    const dw = da * inv / 255; // destination's remaining weight
    const oa = sa + dw;
    if (oa == 0) return 0;
    const m = (s * @as(V, @splat(sa)) + d * @as(V, @splat(dw)) + @as(V, @splat(oa / 2))) / @as(V, @splat(oa));
    var out: @Vector(4, u8) = @intCast(@min(m, @as(V, @splat(255))));
    out[3] = @intCast(oa);
    return @bitCast(out);
}

/// `c` with its alpha replaced by `a`.
pub fn withAlpha(c: u32, a: u8) u32 {
    return (c & 0x00FFFFFF) | (@as(u32, a) << 24);
}

/// `c` with its alpha multiplied by `k` (0..1).
pub fn fade(c: u32, k: f64) u32 {
    const a: f64 = @floatFromInt(c >> 24);
    return withAlpha(c, @intFromFloat(@round(std.math.clamp(a * k, 0, 255))));
}

/// WCAG relative luminance of an opaque colour (alpha ignored).
pub fn luminance(c: u32) f64 {
    var l: f64 = 0;
    inline for (.{ 16, 8, 0 }, .{ 0.2126, 0.7152, 0.0722 }) |sh, w| {
        const v = @as(f64, @floatFromInt((c >> sh) & 0xFF)) / 255;
        l += w * (if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4));
    }
    return l;
}

/// WCAG contrast ratio of two opaque colours, 1..21.
pub fn contrast(a: u32, b: u32) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// `c`, darkened (on a light `bg`) or lightened (on a dark one) in small
/// steps until it reaches `min` contrast with `bg`; `c` itself when it
/// already does.
pub fn legible(c: u32, bg: u32, min: f64) u32 {
    // themes are also built at compile time (default field values)
    @setEvalBranchQuota(200_000);
    const toward: u32 = if (luminance(bg) > 0.18) 0xFF000000 else 0xFFFFFFFF;
    var k: f64 = 0;
    while (k <= 1) : (k += 1.0 / 64.0) {
        const out = mix(c | 0xFF000000, toward, k);
        if (contrast(out, bg) >= min) return out;
    }
    return toward;
}

const testing = std.testing;

test "mix blends every channel and clamps t" {
    try testing.expectEqual(@as(u32, 0xFF808080), mix(0xFF000000, 0xFFFFFFFF, 0.5));
    try testing.expectEqual(@as(u32, 0x80000000), mix(0x00000000, 0xFF000000, 0.5));
    try testing.expectEqual(@as(u32, 0xFF000000), mix(0xFF000000, 0xFFFFFFFF, -3));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), mix(0xFF000000, 0xFFFFFFFF, 7));
    try testing.expectEqual(@as(u32, 0xFF000000), mix(0xFF000000, 0xFFFFFFFF, std.math.nan(f64)));
}

test "over composites onto opaque and see-through destinations" {
    try testing.expectEqual(@as(u32, 0xFF123456), over(0xFF000000, 0xFF123456));
    try testing.expectEqual(@as(u32, 0xFFABCDEF), over(0xFFABCDEF, 0x00FFFFFF));
    const g = over(0xFF000000, 0x80FFFFFF);
    try testing.expectEqual(@as(u32, 0xFF), g >> 24);
    try testing.expect((g & 0xFF) >= 0x7F and (g & 0xFF) <= 0x81);
    // half-covered red over nothing: still red, half opaque
    const p = over(0x00000000, 0x80FF0000);
    try testing.expectEqual(@as(u32, 0x80), p >> 24);
    try testing.expectEqual(@as(u32, 0xFF), (p >> 16) & 0xFF);
}

test "alpha helpers" {
    try testing.expectEqual(@as(u32, 0x80FF0000), withAlpha(0xFFFF0000, 0x80));
    try testing.expectEqual(@as(u32, 0x40FF0000), fade(0x80FF0000, 0.5));
    try testing.expectEqual(@as(u32, 0x00FF0000), fade(0x80FF0000, -1));
}

test "luminance, contrast and legible follow WCAG" {
    try testing.expectApproxEqAbs(@as(f64, 0), luminance(0xFF000000), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), luminance(0xFFFFFFFF), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 21), contrast(0xFF000000, 0xFFFFFFFF), 1e-9);
    try testing.expectEqual(contrast(0xFF336699, 0xFFEEEEEE), contrast(0xFFEEEEEE, 0xFF336699));
    // a colour that already reads is kept; one that does not is pushed
    try testing.expectEqual(@as(u32, 0xFF1D1D1F), legible(0xFF1D1D1F, 0xFFFFFFFF, 4.5));
    const y = legible(0xFFF6D32D, 0xFFFFFFFF, 4.5);
    try testing.expect(contrast(y, 0xFFFFFFFF) >= 4.5);
    try testing.expect(luminance(y) < luminance(0xFFF6D32D));
    const d = legible(0xFF202020, 0xFF000000, 4.5);
    try testing.expect(contrast(d, 0xFF000000) >= 4.5);
}
