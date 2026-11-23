//! Where each piece of a shell capture goes, worked out from the layout
//! before any piece is there (shellcap.zig): the stitched image is laid
//! out as capture.stitch would lay out the monitors (capture.plan), and
//! every piece decodes straight into its place, a monitor at the image's
//! density right into the image, any other into a buffer of its own
//! monitor, which is resampled into the image once complete
//! (capture.fill). No piece is copied after decoding.
//!
//! A piece whose PNG is not the size the layout says (a scale that is
//! not a whole number of pixels) has no place; the caller decodes it on
//! its own and stitches the slow way.

const std = @import("std");
const capture = @import("../../../app/capture.zig");
const shellcap = @import("shellcap.zig");

const LogicalMonitor = shellcap.LogicalMonitor;
const max_monitors = @import("../../api/window.zig").max_outputs;

/// Where one piece decodes: rows of `w` pixels, `stride` apart.
pub const Spot = struct {
    dst: []u32,
    stride: u32,
    w: u32,
    h: u32,
};

pub const Target = struct {
    plan: capture.Plan,
    /// the stitched image
    image: []u32,
    /// each monitor as captured; `own` holds the buffers made for the
    /// monitors resampled into the image
    parts: [max_monitors]capture.Part = undefined,
    own: [max_monitors][]u32 = @splat(&.{}),
    n: usize,

    pub fn init(gpa: std.mem.Allocator, monitors: []const LogicalMonitor) !Target {
        var parts: [max_monitors]capture.Part = undefined;
        for (monitors, 0..) |m, i| {
            parts[i] = .{ .pixels = &.{}, .width = px(m.w, m.scale), .height = px(m.h, m.scale), .logical = m.rect() };
        }
        const pl = try capture.plan(gpa, parts[0..monitors.len]);
        var t: Target = .{ .plan = pl, .image = &.{}, .parts = parts, .n = monitors.len };
        errdefer t.deinit(gpa);
        t.image = try gpa.alloc(u32, @as(usize, pl.width) * pl.height);
        for (0..monitors.len) |i| {
            if (pl.native[i]) continue;
            t.own[i] = try gpa.alloc(u32, @as(usize, parts[i].width) * parts[i].height);
            t.parts[i].pixels = t.own[i];
        }
        return t;
    }

    /// Where piece `p` of monitor `mi` (`m`) goes; null when it does not
    /// fit its monitor's pixels.
    pub fn spot(t: *const Target, mi: usize, m: LogicalMonitor, p: LogicalMonitor) ?Spot {
        const part = t.parts[mi];
        const x0 = px(@intCast(p.x - m.x), m.scale);
        const y0 = px(@intCast(p.y - m.y), m.scale);
        const w = px(p.w, m.scale);
        const h = px(p.h, m.scale);
        if (x0 + w > part.width or y0 + h > part.height or w == 0 or h == 0) return null;
        if (t.plan.native[mi]) {
            const mon = t.plan.mons[mi];
            const stride = t.plan.width;
            return .{ .dst = t.image[(@as(usize, mon.y) + y0) * stride + mon.x + x0 ..], .stride = stride, .w = w, .h = h };
        }
        return .{ .dst = t.own[mi][@as(usize, y0) * part.width + x0 ..], .stride = part.width, .w = w, .h = h };
    }

    /// Every piece is in place: the stitched capture (the target is
    /// spent, whatever happens).
    pub fn finish(t: *Target, gpa: std.mem.Allocator, monitors: []const LogicalMonitor) capture.Capture {
        capture.fill(t.image, t.plan, t.parts[0..t.n], true);
        for (t.plan.mons, monitors) |*out, m| out.scale = m.scale;
        const cap: capture.Capture = .{ .image = .{ .width = t.plan.width, .height = t.plan.height, .pixels = t.image }, .monitors = t.plan.mons };
        t.image = &.{};
        t.plan.mons = &.{};
        t.deinit(gpa);
        return cap;
    }

    pub fn deinit(t: *Target, gpa: std.mem.Allocator) void {
        for (t.own[0..t.n]) |b| gpa.free(b);
        t.own = @splat(&.{});
        gpa.free(t.image);
        gpa.free(t.plan.mons);
        gpa.free(t.plan.native);
        t.image = &.{};
        t.plan.mons = &.{};
        t.plan.native = &.{};
    }
};

/// The pixels decoded into spot `s`, as an image of their own.
pub fn copyOut(gpa: std.mem.Allocator, s: Spot) !@import("../../../gfx/png.zig").Image {
    const out = try gpa.alloc(u32, @as(usize, s.w) * s.h);
    for (0..s.h) |row| @memcpy(out[row * s.w ..][0..s.w], s.dst[row * s.stride ..][0..s.w]);
    return .{ .width = s.w, .height = s.h, .pixels = out };
}

/// Pixels of `logical` logical pixels at `scale`.
fn px(logical: u32, scale: f64) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(logical)) * scale));
}

test "a 2x and a 1.5 monitor: the 2x pieces land in the image, the 1.5 ones in its own buffer" {
    const gpa = std.testing.allocator;
    var mb: [2]LogicalMonitor = undefined;
    const mons = try shellcap.parseLayout("0,0,1728,1080,2;1728,0,2560,1440,1.5", &mb);
    var t = try Target.init(gpa, mons);
    defer t.deinit(gpa);
    // the image at 2x: 1728*2 + 2560*2 wide, 1440*2 high
    try std.testing.expectEqual(@as(u32, 8576), t.plan.width);
    try std.testing.expectEqual(@as(u32, 2880), t.plan.height);
    try std.testing.expect(t.plan.native[0] and !t.plan.native[1]);
    var pb: [2]LogicalMonitor = undefined;
    const strip = (try shellcap.parseLayout("0,540,1728,540,2;1728,720,2560,720,1.5", &pb));
    const a = t.spot(0, mons[0], strip[0]).?;
    try std.testing.expectEqual(@as(u32, 8576), a.stride);
    try std.testing.expectEqual(@as(usize, 1080 * 8576), t.image.len - a.dst.len);
    const b = t.spot(1, mons[1], strip[1]).?;
    try std.testing.expectEqual(@as(u32, 3840), b.stride);
    try std.testing.expectEqual(@as(u32, 1080), b.h);
    try std.testing.expectEqual(@as(usize, 1080 * 3840), t.own[1].len - b.dst.len);
}
