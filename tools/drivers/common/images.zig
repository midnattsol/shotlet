//! The drivers' picture commands that need no compositor: PNG files read
//! (`png`, `pixel`, `runs`, `findpng`), written (`mkpng`, `textpng`), and
//! the colour search `find` and `findpng` share.

const std = @import("std");
const kit = @import("shotlet");
const sys = kit.sys;
const loop = @import("loop.zig");
const pixels = @import("pixels.zig");
const Args = loop.Args;

/// 0xAARRGGBB pixels and the allocator that owns them.
pub const Frame = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Frame) void {
        self.alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// A PNG file's pixels.
pub fn load(gpa: std.mem.Allocator, path: []const u8) !Frame {
    const data = try sys.readFileAlloc(gpa, path, 256 * 1024 * 1024);
    defer gpa.free(data);
    const img = try kit.png.decode(gpa, data);
    return .{ .pixels = img.pixels, .width = img.width, .height = img.height, .alloc = gpa };
}

/// Write `px` as a PNG at `path` (replacing it); answers WxH in `out`.
pub fn writePng(gpa: std.mem.Allocator, out: []u8, path: []const u8, px: []const u32, w: u32, h: u32) ![]const u8 {
    const data = try kit.png.encode(gpa, px, w, h);
    defer gpa.free(data);
    sys.unlink(path) catch {};
    try sys.writeFile(path, data);
    return std.fmt.bufPrint(out, "{d}x{d}", .{ w, h });
}

/// RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]] in `f`: "cx cy w h" of the first
/// blob of that colour at least MINW wide (pixels outside the box never
/// match). `f`'s pixels outside the box are overwritten.
pub fn find(gpa: std.mem.Allocator, out: []u8, f: *Frame, it: *Args) ![]const u8 {
    const rgb = try loop.color(it);
    const tol = try loop.optInt(u32, it, 24);
    const min_w = try loop.optInt(u32, it, 1);
    if (try loop.optBox(it)) |region| pixels.maskOutside(f.pixels, f.width, region, rgb);
    const box = try pixels.findBlob(gpa, f.pixels, f.width, f.height, rgb, tol, min_w);
    return std.fmt.bufPrint(out, "{d} {d} {d} {d}", .{ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2, box[2] - box[0] + 1, box[3] - box[1] + 1 });
}

/// findpng PATH RRGGBB ...: `find` in a PNG file.
pub fn findPng(gpa: std.mem.Allocator, out: []u8, it: *Args) ![]const u8 {
    var f = try load(gpa, try loop.arg(it));
    defer f.deinit();
    return find(gpa, out, &f, it);
}

/// png PATH: the size, WxH.
pub fn size(gpa: std.mem.Allocator, out: []u8, it: *Args) ![]const u8 {
    var f = try load(gpa, try loop.arg(it));
    defer f.deinit();
    return std.fmt.bufPrint(out, "{d}x{d}", .{ f.width, f.height });
}

/// pixel PATH X Y: one pixel as AARRGGBB.
pub fn pixel(gpa: std.mem.Allocator, out: []u8, it: *Args) ![]const u8 {
    var f = try load(gpa, try loop.arg(it));
    defer f.deinit();
    const x = try loop.int(u32, it);
    const y = try loop.int(u32, it);
    if (x >= f.width or y >= f.height) return error.OutOfImage;
    return std.fmt.bufPrint(out, "{x:0>8}", .{f.pixels[@as(usize, y) * f.width + x]});
}

/// runs PATH X RRGGBB [TOL]: how many vertical runs of that colour
/// column X has.
pub fn runs(gpa: std.mem.Allocator, out: []u8, it: *Args) ![]const u8 {
    var f = try load(gpa, try loop.arg(it));
    defer f.deinit();
    const x = try loop.int(u32, it);
    const want = try loop.color(it);
    const tol = try loop.optInt(u32, it, 8);
    if (x >= f.width) return error.OutOfImage;
    return std.fmt.bufPrint(out, "{d}", .{pixels.columnRuns(f.pixels, f.width, f.height, x, want, tol)});
}

/// A filled rectangle of a test picture: x0, y0, x1, y1 (exclusive) and
/// its colour.
pub const Box = struct { x0: u32, y0: u32, x1: u32, y1: u32, rgb: u32 };

/// "X0,Y0,X1,Y1,RRGGBB"
pub fn parseBox(spec: []const u8) !Box {
    var parts = std.mem.splitScalar(u8, spec, ',');
    var v: [4]u32 = undefined;
    for (&v) |*n| n.* = try std.fmt.parseInt(u32, parts.next() orelse return error.BadBox, 10);
    const rgb = try loop.parseColor(parts.next() orelse return error.BadBox);
    if (parts.next() != null) return error.BadBox;
    return .{ .x0 = v[0], .y0 = v[1], .x1 = v[2], .y1 = v[3], .rgb = rgb };
}

/// Fill `px` (w wide) with `bg`, then each box in turn (clipped).
pub fn paint(px: []u32, w: u32, bg: u32, boxes: []const Box) void {
    @memset(px, 0xFF000000 | bg);
    const h: u32 = @intCast(px.len / w);
    for (boxes) |b| {
        for (@min(b.y0, h)..@min(b.y1, h)) |y| {
            const x0 = @min(b.x0, w);
            @memset(px[y * w + x0 .. y * w + @max(x0, @min(b.x1, w))], 0xFF000000 | b.rgb);
        }
    }
}

/// mkpng PATH W H BG [BOX...]: a test picture, BG with each
/// X0,Y0,X1,Y1,RRGGBB box drawn over it in turn (X1, Y1 exclusive).
/// Without boxes, BG is framed in dark grey (the middle three
/// fifths each way); a single `plain` box leaves it plain.
pub fn mkpng(gpa: std.mem.Allocator, out: []u8, it: *Args) ![]const u8 {
    const path = try loop.arg(it);
    const w = try loop.int(u32, it);
    const h = try loop.int(u32, it);
    var bg = try loop.color(it);
    var boxes: [32]Box = undefined;
    var n: usize = 0;
    var plain = false;
    while (it.next()) |spec| {
        if (loop.eql(spec, "plain")) {
            plain = true;
            continue;
        }
        if (n == boxes.len) return error.TooManyBoxes;
        boxes[n] = try parseBox(spec);
        n += 1;
    }
    if (n == 0 and !plain) {
        boxes[0] = .{ .x0 = w / 5, .y0 = h / 5, .x1 = w - w / 5, .y1 = h - h / 5, .rgb = bg };
        bg = 0x303030;
        n = 1;
    }
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(px);
    paint(px, w, bg, boxes[0..n]);
    return writePng(gpa, out, path, px, w, h);
}

/// textpng PATH SIZE TEXT: black TEXT on white, in Shotlet's own text
/// renderer.
pub fn textpng(gpa: std.mem.Allocator, out: []u8, line: []const u8, it: *Args) ![]const u8 {
    const path = try loop.arg(it);
    const pt = try loop.float(it);
    const s = loop.rest(line, try loop.arg(it));
    kit.text.init(gpa);
    defer kit.text.deinit();
    if (!kit.text.available()) return error.NoFont;
    const w: u32 = @intCast(kit.text.width(pt, s) + 80);
    const h: u32 = @intFromFloat(pt * 3);
    const px = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(px);
    @memset(px, 0xFFFFFFFF);
    var c = kit.render.Canvas.init(px, w, h);
    kit.text.draw(&c, 40, @intFromFloat(pt), pt, 0xFF000000, s);
    return writePng(gpa, out, path, px, w, h);
}

test "test pictures" {
    var px: [4 * 3]u32 = undefined;
    paint(&px, 4, 0x2a5db0, &.{ try parseBox("1,0,3,2,ffffff"), try parseBox("3,2,9,9,ff8800") });
    try std.testing.expectEqualSlices(u32, &.{
        0xFF2A5DB0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFF2A5DB0,
        0xFF2A5DB0, 0xFFFFFFFF, 0xFFFFFFFF, 0xFF2A5DB0,
        0xFF2A5DB0, 0xFF2A5DB0, 0xFF2A5DB0, 0xFFFF8800,
    }, &px);
    try std.testing.expectError(error.BadBox, parseBox("1,2,3"));
}
