//! One surface of a picker over the frozen desktop (ui/freeze_pick.zig):
//! its part of the capture at the surface's size, area-averaged
//! (resample.box), and the same dimmed, both made once. With two 4K
//! monitors that is a few tens of millions of pixels to average, so the
//! panes are filled at once, a thread each (`fillAll`).

const std = @import("std");
const parallel = @import("../parallel.zig");
const geom = @import("../geom.zig");
const resample = @import("../gfx/resample.zig");
const view_mod = @import("view.zig");
const dim = @import("dim.zig");

const Rect = geom.Rect;
const View = view_mod.View;

/// The capture the picker shows.
pub const Frozen = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    /// where each monitor is in the image and in the layout (empty: one
    /// monitor, the whole image)
    monitors: []const geom.Monitor = &.{},

    pub fn bounds(self: Frozen) Rect {
        return .ofSize(self.width, self.height);
    }
};

/// One surface: its part of the capture at its own size.
pub const Pane = struct {
    view: View = .{},
    base: []u32 = &.{},
    /// `base` dimmed (outside the area)
    dimmed: []u32 = &.{},
    /// per back buffer, what of it is not the dimmed capture (all of it
    /// until it was painted whole)
    drawn: [2]Rect = .{ Rect.empty, Rect.empty },
    w: u32 = 0,
    h: u32 = 0,
    /// buffer pixels per logical pixel
    k: f64 = 1,
    /// the surface's logical rectangle (its output's)
    logical: Rect = .empty,

    pub fn bounds(self: *const Pane) Rect {
        return .ofSize(self.w, self.h);
    }

    pub fn release(self: *Pane, gpa: std.mem.Allocator) void {
        gpa.free(self.base);
        gpa.free(self.dimmed);
        self.* = .{};
    }

    /// `w` x `h` buffers for the surface at logical `l`, showing `view`.
    pub fn alloc(self: *Pane, gpa: std.mem.Allocator, w: u32, h: u32, l: Rect, view: View) !void {
        self.release(gpa);
        self.base = try gpa.alloc(u32, @as(usize, w) * h);
        errdefer self.release(gpa);
        self.dimmed = try gpa.alloc(u32, @as(usize, w) * h);
        self.w = w;
        self.h = h;
        self.logical = l;
        self.k = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(@max(1, l.w)));
        self.view = view;
        self.drawn = .{ self.bounds(), self.bounds() };
    }

    /// The capture under the pane, area-averaged onto `base`
    /// (letterboxed where the view leaves room), and dimmed to `keep`.
    pub fn fill(self: *Pane, gpa: std.mem.Allocator, f: Frozen, keep: u32) !void {
        if (self.w == 0) return;
        try self.average(gpa, f);
        dim.dimRow(self.base, self.dimmed, keep);
    }

    fn average(p: *Pane, gpa: std.mem.Allocator, f: Frozen) !void {
        const tl = p.view.toImgEdge(.{ .x = 0, .y = 0 });
        const br = p.view.toImgEdge(.{ .x = @intCast(p.w), .y = @intCast(p.h) });
        const src = Rect.fromEdges(tl.x, tl.y, br.x, br.y).intersect(f.bounds()) orelse return @memset(p.base, view_mod.letterbox);
        const dst = p.view.rectToBuf(src).intersect(p.bounds()) orelse return @memset(p.base, view_mod.letterbox);
        const sx: usize = @intCast(src.x);
        const off = @as(usize, @intCast(src.y)) * f.width + sx;
        if (dst.eql(p.bounds())) return resample.box(f.pixels[off..], f.width, @intCast(src.w), @intCast(src.h), p.base, p.w, p.h);
        @memset(p.base, view_mod.letterbox);
        const tmp = try gpa.alloc(u32, @intCast(dst.area()));
        defer gpa.free(tmp);
        resample.box(f.pixels[off..], f.width, @intCast(src.w), @intCast(src.h), tmp, @intCast(dst.w), @intCast(dst.h));
        const dw: usize = @intCast(dst.w);
        for (0..@intCast(dst.h)) |row| {
            const at = (@as(usize, @intCast(dst.y)) + row) * p.w + @as(usize, @intCast(dst.x));
            @memcpy(p.base[at..][0..dw], tmp[row * dw ..][0..dw]);
        }
    }
};

/// Fill every pane, a thread each (the last, or all without threads,
/// here).
pub fn fillAll(gpa: std.mem.Allocator, f: Frozen, panes: []Pane, keep: u32) !void {
    const Job = struct {
        pane: *Pane,
        err: ?anyerror = null,
        fn run(j: *@This(), g: std.mem.Allocator, fz: Frozen, kp: u32) void {
            j.pane.fill(g, fz, kp) catch |e| {
                j.err = e;
            };
        }
    };
    var jobs: [16]Job = undefined;
    var g: parallel.Group(jobs.len) = .{};
    const n = @min(panes.len, jobs.len);
    for (panes[0..n], jobs[0..n]) |*p, *j| {
        j.* = .{ .pane = p };
        g.go(Job.run, .{ j, gpa, f, keep });
    }
    g.wait();
    for (jobs[0..n]) |j| if (j.err) |e| return e;
}

const testing = std.testing;

test "a surface's part of the capture, area-averaged, letterboxed when unmatched" {
    const gpa = testing.allocator;
    var px: [16]u32 = undefined;
    for (&px, 0..) |*c, i| c.* = 0xFF000000 | @as(u32, @intCast(i * 10));
    const f: Frozen = .{ .pixels = &px, .width = 4, .height = 4 };
    // the whole capture on a buffer twice as wide: fitted, bars left and right
    var panes: [2]Pane = .{ .{}, .{} };
    defer for (&panes) |*p| p.release(gpa);
    try panes[0].alloc(gpa, 8, 4, .ofSize(8, 4), View.fit(4, 4, .ofSize(8, 4), 8));
    // a monitor's part at half size: each pixel the mean of four
    const mon: geom.Monitor = .{ .x = 2, .y = 0, .w = 2, .h = 2, .logical = .{ .x = 0, .y = 0, .w = 1, .h = 1 } };
    try panes[1].alloc(gpa, 1, 1, .ofSize(1, 1), view_mod.monitorView(mon.pixelRect(), 1, 1));
    try fillAll(gpa, f, &panes, 256);
    try testing.expectEqual(view_mod.letterbox, panes[0].base[0]);
    try testing.expectEqual(px[0], panes[0].base[2]);
    try testing.expectEqual(px[3], panes[0].base[5]);
    try testing.expectEqual(@as(u32, 0xFF000000 | (20 + 30 + 60 + 70 + 2) / 4), panes[1].base[0]);
    // dimmed by keep/256: 256 keeps it all
    try testing.expectEqualSlices(u32, panes[0].base, panes[0].dimmed);
}
