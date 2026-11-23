//! Signed distances for anti-aliased shapes: one rounded-rectangle
//! distance and one distance-to-coverage rule, shared by every rounded
//! fill, blit, shadow and mask (render/aa.zig, effects/composite.zig,
//! ui/material.zig).
//!
//! Stable API:
//!   roundRectDist(px, py, x0, y0, x1, y1, r)   signed distance (negative inside)
//!   cov(d)                                     coverage of a pixel whose centre
//!                                              is `d` from the edge

const std = @import("std");

/// Signed distance from (px, py) to the rectangle [x0, x1] x [y0, y1] with
/// corners rounded to `r` (clamped to half the shorter side): negative
/// inside, exact everywhere (also inside, away from the corners).
pub inline fn roundRectDist(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64, r_in: f64) f64 {
    const r = if (r_in > 0) @min(r_in, @min((x1 - x0) / 2, (y1 - y0) / 2)) else 0;
    const qx = @max(@max(x0 + r - px, px - (x1 - r)), 0.0);
    const qy = @max(@max(y0 + r - py, py - (y1 - r)), 0.0);
    if (qx == 0 and qy == 0) return @max(@max(x0 - px, px - x1), @max(y0 - py, py - y1));
    return @sqrt(qx * qx + qy * qy) - r;
}

/// How much of a pixel lies inside an edge its centre is `d` from (one
/// pixel of anti-aliasing): 1 at d <= -0.5, 0 at d >= 0.5.
pub inline fn cov(d: f64) f64 {
    return std.math.clamp(0.5 - d, 0, 1);
}

const testing = std.testing;

test "the rounded-rect distance is exact on edges, corners and inside" {
    // a 10x10 square at the origin, corners of radius 2
    try testing.expectApproxEqAbs(@as(f64, -5), roundRectDist(5, 5, 0, 0, 10, 10, 2), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), roundRectDist(5, 0, 0, 0, 10, 10, 2), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3), roundRectDist(13, 5, 0, 0, 10, 10, 2), 1e-12);
    // the corner arc: centre (2, 2), radius 2
    const d = roundRectDist(0, 0, 0, 0, 10, 10, 2);
    try testing.expectApproxEqAbs(@as(f64, @sqrt(8.0) - 2), d, 1e-12);
    // no radius: a plain box, also inside
    try testing.expectApproxEqAbs(@as(f64, -0.5), roundRectDist(0.5, 5, 0, 0, 10, 10, 0), 1e-12);
    // a radius past half the side becomes a pill
    try testing.expectApproxEqAbs(roundRectDist(0, 0, 0, 0, 10, 4, 2), roundRectDist(0, 0, 0, 0, 10, 4, 99), 1e-12);
}

test "coverage is one pixel of anti-aliasing" {
    try testing.expectEqual(@as(f64, 1), cov(-3));
    try testing.expectEqual(@as(f64, 1), cov(-0.5));
    try testing.expectEqual(@as(f64, 0.5), cov(0));
    try testing.expectEqual(@as(f64, 0), cov(0.5));
    try testing.expectEqual(@as(f64, 0), cov(std.math.inf(f64)));
}
