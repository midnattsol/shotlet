//! The image -> canvas transform used by shapes and the editor chrome,
//! over the program's Point and Rect (src/geom.zig).

const geom = @import("../../geom.zig");
const Point = geom.Point;
const Rect = geom.Rect;

/// Maps shape (image) coordinates onto a canvas: c = p * scale + o.
pub const Xform = struct {
    scale: f64 = 1.0,
    ox: f64 = 0,
    oy: f64 = 0,

    pub fn fx(self: Xform, x: i32) f64 {
        return @as(f64, @floatFromInt(x)) * self.scale + self.ox;
    }
    pub fn fy(self: Xform, y: i32) f64 {
        return @as(f64, @floatFromInt(y)) * self.scale + self.oy;
    }
    pub fn pt(self: Xform, p: Point) Point {
        return .{ .x = @intFromFloat(@round(self.fx(p.x))), .y = @intFromFloat(@round(self.fy(p.y))) };
    }
    pub fn rect(self: Xform, r: Rect) Rect {
        const x0: i32 = @intFromFloat(@round(self.fx(r.x)));
        const y0: i32 = @intFromFloat(@round(self.fy(r.y)));
        const x1: i32 = @intFromFloat(@round(self.fx(r.right())));
        const y1: i32 = @intFromFloat(@round(self.fy(r.bottom())));
        return .fromEdges(x0, y0, x1, y1);
    }
};
