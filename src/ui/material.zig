//! The floating "Glass" material, for any surface: a CSS-like box shadow
//! from a theme.Shadow, a blurred and tinted copy of what lies behind
//! ("frost"), rounded blits, the hairline edge, and a snapshot to fade
//! whatever is drawn over it. The editor keeps its per-pane caches in
//! editor_ui/material.zig and draws through these.
//!
//! Stable API (sizes physical px; `k` = logical to physical, ui/scale.zig):
//!   shadowFootprint(r, sh, k) Rect      what a surface's shadow covers
//!   ShadowCache                          a shadow's mask, rebuilt on change
//!   shadow(gpa, cv, r, radius, sh, k, alpha, cache)   onto an opaque canvas
//!   shadowStraight(gpa, dst, dw, dh, r, radius, sh, k, alpha, cache)
//!                                        onto a straight-alpha buffer
//!   frost(gpa, behind, src, r, blur_px, tint, out) !void   blurred, a little
//!                                        saturated and tinted backdrop
//!   glass(gpa, cv, r, radius, th, k)     the material over what `cv` holds
//!                                        under `r`: frost, corners, hairline
//!   blitRoundRect(cv, src, r, radius)    `src` into `r`, corners rounded
//!   hairline(cv, r, radius, color), hairlineColor(th, k)   the 0.5 px edge
//!   Snapshot.take / restore              fade what is drawn in between

const std = @import("std");
const render = @import("../gfx/render.zig");
const sdf = @import("../gfx/render/sdf.zig");
const effects = @import("../gfx/effects.zig");
const color = @import("../gfx/color.zig");
const theme = @import("theme.zig");
const scale = @import("scale.zig");
const Rect = @import("shapes.zig").Rect;

const Canvas = render.Canvas;
const ff = scale.ff;

/// What a floating surface with shadow `sh` covers: itself plus its shadow.
pub fn shadowFootprint(r: Rect, sh: theme.Shadow, k: f64) Rect {
    const b = scale.px(sh.blur, k);
    const dy = scale.px(sh.dy, k);
    return .{ .x = r.x - b, .y = r.y - b + @min(0, dy), .w = r.w + 2 * b, .h = r.h + 2 * b + @as(i32, @intCast(@abs(dy))) };
}

/// A shadow's coverage mask over its footprint, kept while the surface's
/// size, radius and shadow stay the same.
pub const ShadowCache = struct {
    key: [6]i32 = @splat(0),
    mask: []u8 = &.{},

    pub fn release(self: *ShadowCache, gpa: std.mem.Allocator) void {
        gpa.free(self.mask);
        self.* = .{};
    }

    /// The mask of rect `r`'s shadow over shadowFootprint(r, sh, k);
    /// null when out of memory.
    pub fn get(self: *ShadowCache, gpa: std.mem.Allocator, r: Rect, radius: f64, sh: theme.Shadow, k: f64) ?[]const u8 {
        const b = scale.px(sh.blur, k);
        const dy = scale.px(sh.dy, k);
        const fr = shadowFootprint(r, sh, k);
        if (fr.w <= 0 or fr.h <= 0) return null;
        const key = [6]i32{ r.w, r.h, @intFromFloat(@round(std.math.clamp(radius, 0, 1e6) * 16)), b, dy, 1 };
        const n: usize = @intCast(fr.w * fr.h);
        if (!std.mem.eql(i32, &key, &self.key) or self.mask.len != n) {
            gpa.free(self.mask);
            self.mask = &.{};
            self.key = @splat(0);
            self.mask = gpa.alloc(u8, n) catch return null;
            self.key = key;
            shadowMask(self.mask, r, fr, radius, @max(0.5, ff(b) / 2.0), dy);
        }
        return self.mask;
    }
};

/// erf, Abramowitz and Stegun 7.1.26 (|error| < 1.5e-7).
fn erf(x: f64) f64 {
    const s: f64 = if (x < 0) -1 else 1;
    const a = @abs(x);
    const t = 1.0 / (1.0 + 0.3275911 * a);
    const y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-a * a);
    return s * y;
}

/// The shadow's coverage over its footprint `fr`: a Gaussian (sigma)
/// falloff of the rect offset by `dy`, zero inside the rect itself (a
/// translucent material shows no shadow through it).
fn shadowMask(mask: []u8, r: Rect, fr: Rect, radius: f64, sigma: f64, dy: i32) void {
    // in mask coordinates
    const x0 = ff(r.x - fr.x);
    const y0 = ff(r.y - fr.y);
    const x1 = x0 + ff(r.w);
    const y1 = y0 + ff(r.h);
    const fdy = ff(dy);
    const inv = 1.0 / (sigma * std.math.sqrt2);
    const fw: usize = @intCast(fr.w);
    for (0..@intCast(fr.h)) |yy| for (0..fw) |xx| {
        const px = ff(xx) + 0.5;
        const py = ff(yy) + 0.5;
        const inside = sdf.roundRectDist(px, py, x0, y0, x1, y1, radius);
        if (inside < -0.5) {
            mask[yy * fw + xx] = 0;
            continue;
        }
        const d = sdf.roundRectDist(px, py - fdy, x0, y0, x1, y1, radius);
        var a = 0.5 * (1.0 - erf(d * inv));
        // fade into the edge of the material itself
        if (inside < 0.5) a *= inside + 0.5;
        mask[yy * fw + xx] = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
    };
}

/// A CSS-like box shadow around the rounded rect `r` onto an opaque
/// canvas, outside `r` only; `alpha` fades it.
pub fn shadow(gpa: std.mem.Allocator, cv: *Canvas, r: Rect, radius: f64, sh: theme.Shadow, k: f64, alpha: f64, cache: *ShadowCache) void {
    const mask = cache.get(gpa, r, radius, sh, k) orelse return;
    blendShadow(cv, mask, shadowFootprint(r, sh, k), shadowAlpha(sh, alpha), sh.color & 0x00FFFFFF);
}

/// The same shadow onto a straight-alpha buffer (a see-through floating
/// window: effects.over keeps the transparency around it).
pub fn shadowStraight(gpa: std.mem.Allocator, dst: []u32, dw: u32, dh: u32, r: Rect, radius: f64, sh: theme.Shadow, k: f64, alpha: f64, cache: *ShadowCache) void {
    const mask = cache.get(gpa, r, radius, sh, k) orelse return;
    const fr = shadowFootprint(r, sh, k);
    const ca = shadowAlpha(sh, alpha);
    const rgb = sh.color & 0x00FFFFFF;
    const fw: usize = @intCast(fr.w);
    for (0..@intCast(fr.h)) |yy| {
        const y = fr.y + @as(i32, @intCast(yy));
        if (y < 0 or y >= dh) continue;
        for (mask[yy * fw ..][0..fw], 0..) |m, xx| {
            const x = fr.x + @as(i32, @intCast(xx));
            if (m == 0 or x < 0 or x >= dw) continue;
            const a = (ca * m + 127) / 255;
            const i = @as(usize, @intCast(y)) * dw + @as(usize, @intCast(x));
            dst[i] = color.over(dst[i], rgb | (a << 24));
        }
    }
}

fn shadowAlpha(sh: theme.Shadow, alpha: f64) u32 {
    return @intFromFloat(@round(ff(sh.color >> 24) * std.math.clamp(alpha, 0, 1)));
}

/// Blend colour `rgb` at alpha `ca` through `mask` onto the canvas.
fn blendShadow(canvas: *Canvas, mask: []const u8, fr: Rect, ca: u32, rgb: u32) void {
    const fw: usize = @intCast(fr.w);
    const xa: usize = @intCast(@max(0, -fr.x));
    const xb: usize = @intCast(std.math.clamp(canvas.w - fr.x, 0, fr.w));
    const cw: usize = @intCast(canvas.w);
    for (0..@intCast(fr.h)) |yy| {
        const y = fr.y + @as(i32, @intCast(yy));
        if (y < 0 or y >= canvas.h) continue;
        const row = canvas.px[@as(usize, @intCast(y)) * cw ..];
        const mrow = mask[yy * fw ..][0..fw];
        for (xa..xb) |xx| {
            const m: u32 = mrow[xx];
            if (m == 0) continue;
            const i: usize = @intCast(fr.x + @as(i32, @intCast(xx)));
            const p = row[i];
            if (rgb == 0) {
                // black: darken by the coverage, two multiplies a pixel
                const keep = 256 - ((ca * m + 127) >> 8);
                row[i] = 0xFF000000 | (((p & 0xFF00FF) * keep >> 8) & 0xFF00FF) | (((p & 0x00FF00) * keep >> 8) & 0x00FF00);
                continue;
            }
            const a = (ca * m + 127) / 255;
            if (a != 0) row[i] = Canvas.blendPixel(p, rgb | (a << 24));
        }
    }
}

/// What lies behind `r` as the material shows it: `behind` (the pixels
/// of `src`, src.w x src.h, which must cover `r` plus the blur where the
/// surface allows) blurred by about `blur_px` at half resolution, a
/// little more saturated (vibrancy), tinted with `tint`, into `out`
/// (r.w x r.h, opaque).
pub fn frost(gpa: std.mem.Allocator, behind: []const u32, src: Rect, r: Rect, blur_px: i32, tint: u32, out: []u32) !void {
    // blur at half resolution: cheaper, and nobody can tell
    const sw: usize = @intCast(@divTrunc(src.w + 1, 2));
    const sh: usize = @intCast(@divTrunc(src.h + 1, 2));
    const small = try gpa.alloc(u32, sw * sh);
    defer gpa.free(small);
    halve(behind, @intCast(src.w), @intCast(src.h), small, sw, sh);
    try effects.softBlur(gpa, small, @intCast(sw), @intCast(sh), .ofSize(@intCast(sw), @intCast(sh)), @intCast(@max(1, @divTrunc(blur_px, 2))));
    // saturate a little, like vibrancy, and tint, at the small size;
    // then scale up
    for (small) |*p| p.* = Canvas.blendPixel(saturate(p.*), tint);
    upscale(small, sw, sh, out, r, src);
}

/// Box-filter `src` (srcw x srch) down to half size into `small`.
fn halve(src: []const u32, srcw: usize, srch: usize, small: []u32, sw: usize, sh: usize) void {
    for (0..sh) |y| for (0..sw) |x| {
        var acc: [3]u32 = .{ 0, 0, 0 };
        for (0..2) |dy| for (0..2) |dx| {
            const p = src[@min(srch - 1, y * 2 + dy) * srcw + @min(srcw - 1, x * 2 + dx)];
            acc[0] += (p >> 16) & 0xFF;
            acc[1] += (p >> 8) & 0xFF;
            acc[2] += p & 0xFF;
        };
        small[y * sw + x] = 0xFF000000 | ((acc[0] / 4) << 16) | ((acc[1] / 4) << 8) | (acc[2] / 4);
    };
}

/// Push a colour away from its luminance by 346/256, like vibrancy.
inline fn saturate(p: u32) u32 {
    const cr: i32 = @intCast((p >> 16) & 0xFF);
    const cg: i32 = @intCast((p >> 8) & 0xFF);
    const cb: i32 = @intCast(p & 0xFF);
    const lum = @divTrunc(54 * cr + 183 * cg + 19 * cb, 256);
    var out: u32 = 0xFF000000;
    inline for (.{ cr, cg, cb }, 0..) |cc, i| {
        const v = std.math.clamp(lum + @divTrunc((cc - lum) * 346, 256), 0, 255);
        out |= @as(u32, @intCast(v)) << @intCast(16 - 8 * i);
    }
    return out;
}

/// Scale the half-size `small` up into `out` (r.w x r.h, bilinear in
/// 8-bit fixed point); `src` is the area `small` was made from.
fn upscale(small: []const u32, sw: usize, sh: usize, out: []u32, r: Rect, src: Rect) void {
    const rw: usize = @intCast(r.w);
    for (0..@intCast(r.h)) |y| {
        // source position in 1/256ths of a small pixel
        const fy = std.math.clamp(@as(i32, @intCast(y)) * 128 + (r.y - src.y) * 128 - 64, 0, @as(i32, @intCast(sh - 1)) * 256);
        const y0: usize = @intCast(@divTrunc(fy, 256));
        const y1 = @min(sh - 1, y0 + 1);
        const ty: u32 = @intCast(@mod(fy, 256));
        const row0 = small[y0 * sw ..][0..sw];
        const row1 = small[y1 * sw ..][0..sw];
        for (0..rw) |x| {
            const fx = std.math.clamp(@as(i32, @intCast(x)) * 128 + (r.x - src.x) * 128 - 64, 0, @as(i32, @intCast(sw - 1)) * 256);
            const x0: usize = @intCast(@divTrunc(fx, 256));
            const x1 = @min(sw - 1, x0 + 1);
            const tx: u32 = @intCast(@mod(fx, 256));
            out[y * rw + x] = bilerp(row0[x0], row0[x1], row1[x0], row1[x1], tx, ty);
        }
    }
}

inline fn bilerp(a: u32, b: u32, c: u32, d: u32, tx: u32, ty: u32) u32 {
    var out: u32 = 0xFF000000;
    inline for (.{ 16, 8, 0 }) |sh_| {
        const top = ((a >> sh_) & 0xFF) * (256 - tx) + ((b >> sh_) & 0xFF) * tx;
        const bot = ((c >> sh_) & 0xFF) * (256 - tx) + ((d >> sh_) & 0xFF) * tx;
        out |= (((top * (256 - ty) + bot * ty) >> 16) & 0xFF) << sh_;
    }
    return out;
}

/// The material over what `cv` already holds under `r`: blurred, tinted
/// with th.material, corners rounded to `radius`, a hairline edge. (No
/// shadow: draw `shadow` first.) A plain material fill when out of memory.
pub fn glass(gpa: std.mem.Allocator, cv: *Canvas, r: Rect, radius: f64, th: theme.Theme, k: f64) void {
    if (r.w <= 0 or r.h <= 0) return;
    if (!frostOnto(gpa, cv, r, radius, th, k)) cv.fillRoundRectAA(r.x, r.y, r.w, r.h, radius, th.material_solid);
    hairline(cv, r, radius, hairlineColor(th, k));
}

fn frostOnto(gpa: std.mem.Allocator, cv: *Canvas, r: Rect, radius: f64, th: theme.Theme, k: f64) bool {
    const blur_px: i32 = @max(2, scale.px(theme.backdrop_blur, k));
    const src = Rect.intersect(r.expand(blur_px * 2), .{ .x = 0, .y = 0, .w = cv.w, .h = cv.h }) orelse return false;
    const sw: usize = @intCast(src.w);
    const behind = gpa.alloc(u32, sw * @as(usize, @intCast(src.h))) catch return false;
    defer gpa.free(behind);
    for (0..@intCast(src.h)) |yy| {
        const off = @as(usize, @intCast(src.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(cv.w)) + @as(usize, @intCast(src.x));
        @memcpy(behind[yy * sw ..][0..sw], cv.px[off..][0..sw]);
    }
    const out = gpa.alloc(u32, @intCast(r.w * r.h)) catch return false;
    defer gpa.free(out);
    frost(gpa, behind, src, r, blur_px, th.material, out) catch return false;
    blitRoundRect(cv, out, r, radius);
    return true;
}

/// Copy `src` (r.w x r.h) into `r` with rounded, anti-aliased corners.
pub fn blitRoundRect(canvas: *Canvas, src: []const u32, r: Rect, radius: f64) void {
    const c = Rect.intersect(r, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return;
    const rw: usize = @intCast(r.w);
    const cw: usize = @intCast(canvas.w);
    const band: i32 = @intFromFloat(@ceil(std.math.clamp(radius, 0, 1e6)));
    const x0 = ff(r.x);
    const y0 = ff(r.y);
    const x1 = x0 + ff(r.w);
    const y1 = y0 + ff(r.h);
    var y = c.y;
    while (y < c.bottom()) : (y += 1) {
        const sy: usize = @intCast(y - r.y);
        const srow = src[sy * rw ..][0..rw];
        const drow = canvas.px[@as(usize, @intCast(y)) * cw ..][0..cw];
        const corner_row = y < r.y + band or y >= r.bottom() - band;
        // the straight middle: a plain copy
        const ma = if (corner_row) @max(c.x, r.x + band) else c.x;
        const mb = if (corner_row) @min(c.right(), r.right() - band) else c.right();
        if (mb > ma) @memcpy(drow[@intCast(ma)..@intCast(mb)], srow[@intCast(ma - r.x)..@intCast(mb - r.x)]);
        if (!corner_row) continue;
        for ([2][2]i32{ .{ c.x, @min(ma, c.right()) }, .{ @max(mb, c.x), c.right() } }) |span| {
            var x = span[0];
            while (x < span[1]) : (x += 1) {
                const cov = sdf.cov(sdf.roundRectDist(ff(x) + 0.5, ff(y) + 0.5, x0, y0, x1, y1, radius));
                if (cov <= 0) continue;
                const a: u32 = @intFromFloat(@round(cov * 255));
                const p = srow[@intCast(x - r.x)];
                drow[@intCast(x)] = Canvas.blendPixel(drow[@intCast(x)], (p & 0x00FFFFFF) | (a << 24));
            }
        }
    }
}

/// The hairline's colour at scale `k`: 0.5 px, so one pixel at half
/// strength on a 1x screen.
pub fn hairlineColor(th: theme.Theme, k: f64) u32 {
    return color.fade(th.hairline, @min(1.0, 0.5 * k));
}

/// A one-pixel line just inside the rounded rect `r`.
pub fn hairline(canvas: *Canvas, r: Rect, radius: f64, col: u32) void {
    const rad: i32 = @intFromFloat(@ceil(std.math.clamp(radius, 0, 1e6)));
    canvas.fillRect(r.x + rad, r.y, r.w - 2 * rad, 1, col);
    canvas.fillRect(r.x + rad, r.bottom() - 1, r.w - 2 * rad, 1, col);
    canvas.fillRect(r.x, r.y + rad, 1, r.h - 2 * rad, col);
    canvas.fillRect(r.right() - 1, r.y + rad, 1, r.h - 2 * rad, col);
    // the corners: a ring of radius - 0.5 around each corner's centre
    const corners = [4][4]f64{
        .{ ff(r.x) + radius, ff(r.y) + radius, -1, -1 },
        .{ ff(r.right()) - radius, ff(r.y) + radius, 1, -1 },
        .{ ff(r.x) + radius, ff(r.bottom()) - radius, -1, 1 },
        .{ ff(r.right()) - radius, ff(r.bottom()) - radius, 1, 1 },
    };
    const ca = ff(col >> 24);
    for (corners) |kc| {
        const bx: i32 = if (kc[2] < 0) r.x else r.right() - rad;
        const by: i32 = if (kc[3] < 0) r.y else r.bottom() - rad;
        var y = by;
        while (y < by + rad) : (y += 1) {
            var x = bx;
            while (x < bx + rad) : (x += 1) {
                const dx = ff(x) + 0.5 - kc[0];
                const dy = ff(y) + 0.5 - kc[1];
                const d = @sqrt(dx * dx + dy * dy);
                const cov = std.math.clamp(1.0 - @abs(d - (radius - 0.5)), 0, 1);
                if (cov <= 0) continue;
                canvas.blend(x, y, (col & 0x00FFFFFF) | (@as(u32, @intFromFloat(@round(ca * cov))) << 24));
            }
        }
    }
}

/// Opacity for whatever is drawn between snapshot and restore: keeps a
/// copy of `r`, and mixes it back in afterwards.
pub const Snapshot = struct {
    r: Rect,
    px: []u32,

    pub fn take(gpa: std.mem.Allocator, canvas: *Canvas, r_in: Rect) ?Snapshot {
        const r = Rect.intersect(r_in, .{ .x = 0, .y = 0, .w = canvas.w, .h = canvas.h }) orelse return null;
        const px = gpa.alloc(u32, @intCast(r.w * r.h)) catch return null;
        const rw: usize = @intCast(r.w);
        for (0..@intCast(r.h)) |yy| {
            const off = @as(usize, @intCast(r.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(r.x));
            @memcpy(px[yy * rw ..][0..rw], canvas.px[off..][0..rw]);
        }
        return .{ .r = r, .px = px };
    }

    pub fn restore(self: Snapshot, gpa: std.mem.Allocator, canvas: *Canvas, alpha: f64) void {
        defer gpa.free(self.px);
        if (alpha >= 1) return;
        const k: u32 = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 256));
        const rw: usize = @intCast(self.r.w);
        for (0..@intCast(self.r.h)) |yy| {
            const off = @as(usize, @intCast(self.r.y + @as(i32, @intCast(yy)))) * @as(usize, @intCast(canvas.w)) + @as(usize, @intCast(self.r.x));
            effects.mixRows(canvas.px[off..][0..rw], self.px[yy * rw ..][0..rw], canvas.px[off..][0..rw], k);
        }
    }
};

comptime {
    _ = @import("material_test.zig");
}
