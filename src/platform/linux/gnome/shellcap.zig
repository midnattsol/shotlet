//! Captures taken by the Shotlet GNOME Shell extension (prompt free):
//!
//!     shotlet --from-shell ID --monitors "x,y,w,h,scale;..."
//!             --pieces "x,y,w,h,scale;..." [--t0 MS]
//!
//! The extension took the screenshot inside the shell with
//! Shell.Screenshot.screenshot_area, a few horizontal strips ("pieces")
//! of each monitor, their edges on whole pixels, so that the PNG encoding
//! runs on several threads. Each piece is painted at its monitor's own
//! scale, without the cursor. Piece K is the PNG
//! $XDG_RUNTIME_DIR/shotlet/shot-ID-K.png: a private directory, the file
//! 0600. For an area capture the extension starts Shotlet before the
//! pieces are written (it renames each from .part when complete), so
//! each piece is waited for (wait_ms at most) and decoded the moment it
//! is there, a thread each. Shotlet builds those names itself from ID
//! (letters and digits only), reads each file once, deletes it at once,
//! and stitches the pieces as the portal path does (capture.stitch).

const std = @import("std");
const capture = @import("../../../app/capture.zig");
const geom = @import("../../../geom.zig");
const png = @import("../../../gfx/png.zig");
const sys = @import("../sys.zig");
const place = @import("shellcap_place.zig");

const max_monitors = @import("../../api/window.zig").max_outputs;

/// One monitor in the compositor's logical layout.
pub const LogicalMonitor = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    scale: f64,

    /// Where it is (sizes are at most 65535: parseLayout checks).
    pub fn rect(m: LogicalMonitor) geom.Rect {
        return .{ .x = m.x, .y = m.y, .w = @intCast(m.w), .h = @intCast(m.h) };
    }
};

/// `--from-shell` and its companions.
pub const Args = @import("../../api/shell.zig").HandedCapture;

pub const max_pieces = 32;

/// "x,y,w,h,scale;..." as the extension writes it.
pub fn parseLayout(s: []const u8, out: []LogicalMonitor) ![]LogicalMonitor {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        if (n == out.len) return error.TooManyMonitors;
        var f = std.mem.splitScalar(u8, item, ',');
        const x = try std.fmt.parseInt(i32, f.next() orelse return error.BadLayout, 10);
        const y = try std.fmt.parseInt(i32, f.next() orelse return error.BadLayout, 10);
        const w = try std.fmt.parseInt(u32, f.next() orelse return error.BadLayout, 10);
        const h = try std.fmt.parseInt(u32, f.next() orelse return error.BadLayout, 10);
        const scale = try std.fmt.parseFloat(f64, f.next() orelse return error.BadLayout);
        if (f.next() != null) return error.BadLayout;
        if (w == 0 or h == 0 or w > 65535 or h > 65535) return error.BadLayout;
        if (!(scale >= 0.25 and scale <= 8)) return error.BadLayout;
        if (@abs(x) > 1 << 20 or @abs(y) > 1 << 20) return error.BadLayout;
        out[n] = .{ .x = x, .y = y, .w = w, .h = h, .scale = scale };
        n += 1;
    }
    if (n == 0) return error.BadLayout;
    return out[0..n];
}

/// The capture directory, $XDG_RUNTIME_DIR/shotlet.
pub fn dirPath(buf: []u8, runtime_dir: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/shotlet", .{runtime_dir});
}

/// The extension's capture ids: letters and digits.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// <runtime_dir>/shotlet/shot-<id>-<k>.png
pub fn piecePath(buf: []u8, runtime_dir: []const u8, id: []const u8, k: usize) ![]u8 {
    if (!validId(id)) return error.NotAShellCapture;
    return std.fmt.bufPrint(buf, "{s}/shotlet/shot-{s}-{d}.png", .{ runtime_dir, id, k });
}

/// The capture directory must be ours, private and not a symlink.
fn checkDir(runtime_dir: []const u8) !void {
    var buf: [1100]u8 = undefined;
    sys.checkPrivateDir(try dirPath(&buf, runtime_dir)) catch return error.NotAShellCapture;
}

/// Read one piece and delete it. Refuses a symlink, anything but a
/// regular file, and a file that is not ours or that others may read.
pub fn readAndRemove(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    // whatever happens next, the capture does not stay on disk
    defer sys.unlink(path) catch {};
    const fd = sys.openPrivateRegular(path) catch return error.NotAShellCapture;
    defer sys.close(fd);
    const size = sys.fdSize(fd) catch return error.NotAShellCapture;
    if (size > 512 * 1024 * 1024) return error.FileTooBig;
    const data = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(data);
    try sys.readExact(fd, data, null);
    return data;
}

fn contains(m: LogicalMonitor, p: LogicalMonitor) bool {
    return p.x >= m.x and p.y >= m.y and
        @as(i64, p.x) + p.w <= @as(i64, m.x) + m.w and
        @as(i64, p.y) + p.h <= @as(i64, m.y) + m.h;
}

/// Which monitor each piece belongs to; every monitor must be covered by
/// its pieces exactly (same scale, areas adding up).
pub fn assignPieces(monitors: []const LogicalMonitor, pieces: []const LogicalMonitor, owner: []usize) !void {
    var area: [max_monitors]u64 = @splat(0);
    for (pieces, owner) |p, *o| {
        o.* = for (monitors, 0..) |m, i| {
            if (contains(m, p)) break i;
        } else return error.BadLayout;
        if (@abs(monitors[o.*].scale - p.scale) > 1e-6) return error.BadLayout;
        area[o.*] += @as(u64, p.w) * p.h;
    }
    for (monitors, 0..) |m, i| if (area[i] != @as(u64, m.w) * m.h) return error.BadLayout;
}

/// Stitch the decoded pieces (each at its monitor's scale) into one
/// image, as capture.stitch does for the portal's monitor frames: first
/// each monitor whole from its pieces (so a monitor scaled to the
/// image's density is resampled whole, with no seam at a strip's edge),
/// then the monitors.
pub fn build(gpa: std.mem.Allocator, monitors: []const LogicalMonitor, pieces: []const LogicalMonitor, images: []const png.Image) !capture.Capture {
    var owner: [max_pieces]usize = undefined;
    try assignPieces(monitors, pieces, owner[0..pieces.len]);
    var parts: [max_monitors]capture.Part = undefined;
    var owned: [max_monitors][]u32 = @splat(&.{});
    defer for (owned[0..monitors.len]) |px| gpa.free(px);
    for (monitors, 0..) |m, i| {
        parts[i] = try monitorPart(gpa, m, i, pieces, owner[0..pieces.len], images, &owned[i]);
    }
    const cap = try capture.stitch(gpa, parts[0..monitors.len]);
    for (cap.monitors, monitors) |*out, m| out.scale = m.scale;
    return cap;
}

/// Monitor `m` (number `i`) as one frame: its only piece as it is, else
/// its pieces placed at their pixel offsets in a new buffer (`owned`).
fn monitorPart(gpa: std.mem.Allocator, m: LogicalMonitor, i: usize, pieces: []const LogicalMonitor, owner: []const usize, images: []const png.Image, owned: *[]u32) !capture.Part {
    var first: ?usize = null;
    var n: usize = 0;
    for (owner, 0..) |o, k| if (o == i) {
        if (first == null) first = k;
        n += 1;
    };
    const f = first.?;
    if (n == 1) return .{ .pixels = images[f].pixels, .width = images[f].width, .height = images[f].height, .logical = m.rect() };
    // the pieces' own density (pixels per logical pixel)
    const k: f64 = @as(f64, @floatFromInt(images[f].width)) / @as(f64, @floatFromInt(pieces[f].w));
    const w: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(m.w)) * k));
    const h: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(m.h)) * k));
    owned.* = try gpa.alloc(u32, @as(usize, w) * h);
    @memset(owned.*, 0xFF000000);
    for (owner, pieces, images) |o, p, im| {
        if (o != i) continue;
        const x0: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(p.x - m.x)) * k));
        const y0: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(p.y - m.y)) * k));
        const cw = @min(im.width, w -| x0);
        for (0..@min(im.height, h -| y0)) |row| {
            @memcpy(owned.*[(y0 + row) * w + x0 ..][0..cw], im.pixels[row * im.width ..][0..cw]);
        }
    }
    return .{ .pixels = owned.*, .width = w, .height = h, .logical = m.rect() };
}

/// How long a piece may take to appear: the extension starts Shotlet
/// before it has written them (its frozen frame is up meanwhile).
pub const wait_ms = 10 * 1000;

/// readAndRemove once `path` is there: the extension writes each piece
/// as a .part file and renames it to `path` when complete. NotFound
/// (polled every millisecond) until `deadline_ms` (monotonic).
pub fn readWhenThere(gpa: std.mem.Allocator, path: []const u8, deadline_ms: i64) ![]u8 {
    while (true) {
        const fd = sys.openPrivateRegular(path) catch |err| switch (err) {
            error.NotFound => {
                if (sys.monoMs() >= deadline_ms) return error.CaptureTimedOut;
                sys.sleepMs(1);
                continue;
            },
            else => {
                sys.unlink(path) catch {};
                return error.NotAShellCapture;
            },
        };
        sys.close(fd);
        return readAndRemove(gpa, path);
    }
}

/// One piece: waited for, read, deleted and decoded on a thread of its
/// own, so each decodes as soon as the shell has written it: into its
/// place in the stitched image when it has one (shellcap_place.zig),
/// else on its own.
const Slot = struct {
    path_buf: [1200]u8 = undefined,
    path: []const u8 = "",
    deadline_ms: i64 = 0,
    spot: ?place.Spot = null,
    placed: bool = false,
    image: ?png.Image = null,
    err: ?anyerror = null,

    fn run(self: *Slot, gpa: std.mem.Allocator) void {
        const data = readWhenThere(gpa, self.path, self.deadline_ms) catch |err| {
            self.err = err;
            return;
        };
        defer gpa.free(data);
        if (self.spot) |s| {
            if (png.decodeInto(gpa, data, s.dst, s.stride, s.w, s.h)) {
                self.placed = true;
                return;
            } else |err| if (err != error.SizeMismatch) {
                self.err = err;
                return;
            }
        }
        self.image = png.decode(gpa, data) catch |err| {
            self.err = err;
            return;
        };
    }
};

/// Wait for, read, delete and decode the pieces (a thread each), and
/// stitch them. Every piece file is deleted, also when something fails.
pub fn load(gpa: std.mem.Allocator, runtime_dir: []const u8, args: Args) !capture.Capture {
    return loadWithin(gpa, runtime_dir, args, wait_ms);
}

/// load, waiting at most `wait` ms for the pieces.
fn loadWithin(gpa: std.mem.Allocator, runtime_dir: []const u8, args: Args, wait: i64) !capture.Capture {
    if (!validId(args.id)) return error.NotAShellCapture;
    var mons_buf: [max_monitors]LogicalMonitor = undefined;
    var pieces_buf: [max_pieces]LogicalMonitor = undefined;
    const pieces = parseLayout(args.pieces, &pieces_buf) catch |err| {
        removeAll(runtime_dir, args.id);
        return err;
    };
    var slots: [max_pieces]Slot = undefined;
    for (slots[0..pieces.len]) |*sl| sl.* = .{};
    // whatever fails below, every piece is gone at the end (the threads
    // have joined by then)
    defer removeAll(runtime_dir, args.id);
    defer for (slots[0..pieces.len]) |*sl| if (sl.image) |*im| im.deinit(gpa);
    const monitors = try parseLayout(args.monitors, &mons_buf);
    var owner: [max_pieces]usize = undefined;
    try assignPieces(monitors, pieces, owner[0..pieces.len]);
    try checkDir(runtime_dir);
    var target = try place.Target.init(gpa, monitors);
    defer target.deinit(gpa);
    const deadline = sys.monoMs() + wait;
    for (slots[0..pieces.len], pieces, owner[0..pieces.len], 0..) |*sl, p, o, k| {
        sl.path = try piecePath(&sl.path_buf, runtime_dir, args.id, k);
        sl.deadline_ms = deadline;
        sl.spot = target.spot(o, monitors[o], p);
    }
    runAll(gpa, slots[0..pieces.len]);
    var all_placed = true;
    for (slots[0..pieces.len]) |sl| {
        if (sl.err) |err| return err;
        all_placed = all_placed and sl.placed;
    }
    if (all_placed) return target.finish(gpa, monitors);
    // some piece was not the size its place has: the slow way (the
    // pieces decoded into place copied out of it)
    var images: [max_pieces]png.Image = undefined;
    for (slots[0..pieces.len], 0..) |*sl, i| {
        if (sl.image == null) sl.image = try place.copyOut(gpa, sl.spot.?);
        images[i] = sl.image.?;
    }
    return build(gpa, monitors, pieces, images[0..pieces.len]);
}

/// Every slot's run, a thread each (the first on this one).
fn runAll(gpa: std.mem.Allocator, slots: []Slot) void {
    var threads: [max_pieces]?std.Thread = @splat(null);
    for (slots[1..], 1..) |*sl, i| {
        threads[i] = std.Thread.spawn(.{}, Slot.run, .{ sl, gpa }) catch null;
        if (threads[i] == null) sl.run(gpa);
    }
    slots[0].run(gpa);
    for (threads[1..slots.len]) |t| if (t) |th| th.join();
}

/// Delete whatever is left of capture `id`'s pieces.
fn removeAll(runtime_dir: []const u8, id: []const u8) void {
    for (0..max_pieces) |k| {
        var buf: [1200]u8 = undefined;
        const p = piecePath(&buf, runtime_dir, id, k) catch return;
        sys.unlink(p) catch {};
    }
}

test "layout parsing" {
    var buf: [4]LogicalMonitor = undefined;
    const l = try parseLayout("0,0,1280,720,2;1280,0,1280,720,1", &buf);
    try std.testing.expectEqual(@as(usize, 2), l.len);
    try std.testing.expectEqual(LogicalMonitor{ .x = 1280, .y = 0, .w = 1280, .h = 720, .scale = 1 }, l[1]);
    const neg = try parseLayout("-1712,-10,1712,963,1.4953271150588989;", &buf);
    try std.testing.expectEqual(@as(i32, -1712), neg[0].x);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4953), neg[0].scale, 1e-3);
    try std.testing.expectError(error.BadLayout, parseLayout("", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10,1,9", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,0,10,1", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10,nan", &buf));
    try std.testing.expectError(error.BadLayout, parseLayout("0,0,10,10,0", &buf));
    try std.testing.expectError(error.InvalidCharacter, parseLayout("a,0,10,10,1", &buf));
    try std.testing.expectError(error.TooManyMonitors, parseLayout("0,0,1,1,1;1,0,1,1,1;2,0,1,1,1;3,0,1,1,1;4,0,1,1,1", &buf));
}

test "piece files: names Shotlet builds itself from a plain id" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/run/user/1000/shotlet/shot-0a1B-3.png", try piecePath(&buf, "/run/user/1000", "0a1B", 3));
    const long: [65]u8 = @splat('x');
    for ([_][]const u8{ "", "../x", "a/b", "a-b", "a.b", "a b", &long }) |id|
        try std.testing.expectError(error.NotAShellCapture, piecePath(&buf, "/run/user/1000", id, 0));
}

test "pieces must tile the monitors" {
    var mb: [4]LogicalMonitor = undefined;
    var pb: [8]LogicalMonitor = undefined;
    const mons = try parseLayout("0,0,100,60,2;100,0,50,50,1", &mb);
    var owner: [8]usize = undefined;
    const ok = try parseLayout("0,0,100,30,2;0,30,100,30,2;100,0,50,50,1", &pb);
    try assignPieces(mons, ok, owner[0..ok.len]);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1 }, owner[0..3]);
    const gap = try parseLayout("0,0,100,30,2;100,0,50,50,1", &pb);
    try std.testing.expectError(error.BadLayout, assignPieces(mons, gap, owner[0..gap.len]));
    const across = try parseLayout("0,0,120,60,2;100,0,50,50,1", &pb);
    try std.testing.expectError(error.BadLayout, assignPieces(mons, across, owner[0..across.len]));
    const scale = try parseLayout("0,0,100,60,1;100,0,50,50,1", &pb);
    try std.testing.expectError(error.BadLayout, assignPieces(mons, scale, owner[0..scale.len]));
}

const testutil = @import("../../../testutil.zig");

test "pieces stitch into mixed-scale monitors" {
    const gpa = std.testing.allocator;
    // 1280x720 logical at 2, in two strips; 1280x720 at 1 on its right
    var mb: [4]LogicalMonitor = undefined;
    var pb: [8]LogicalMonitor = undefined;
    const mons = try parseLayout("0,0,1280,720,2;1280,0,1280,720,1", &mb);
    const pieces = try parseLayout("0,0,1280,360,2;0,360,1280,360,2;1280,0,1280,720,1", &pb);
    var imgs = [_]png.Image{
        try testutil.solidImage(2560, 720, 0xFFFF0000),
        try testutil.solidImage(2560, 720, 0xFF00FF00),
        try testutil.solidImage(1280, 720, 0xFF0000FF),
    };
    defer for (&imgs) |*im| im.deinit(gpa);
    var cap = try build(gpa, mons, pieces, &imgs);
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 5120), cap.image.width);
    try std.testing.expectEqual(@as(u32, 1440), cap.image.height);
    try std.testing.expectEqual(@as(usize, 2), cap.monitors.len);
    try std.testing.expectEqual(capture.Monitor{ .x = 0, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 0, .y = 0, .w = 1280, .h = 720 }, .scale = 2 }, cap.monitors[0]);
    try std.testing.expectEqual(capture.Monitor{ .x = 2560, .y = 0, .w = 2560, .h = 1440, .logical = .{ .x = 1280, .y = 0, .w = 1280, .h = 720 }, .scale = 1 }, cap.monitors[1]);
    const W = 5120;
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), cap.image.pixels[719 * W + 10]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), cap.image.pixels[720 * W + 10]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cap.image.pixels[1439 * W + 5119]);
}

test "a fractional monitor in one piece next to a 1x one" {
    const gpa = std.testing.allocator;
    var mb: [4]LogicalMonitor = undefined;
    const mons = try parseLayout("0,0,1712,963,1.4953271150588989;1712,0,1280,720,1", &mb);
    var imgs = [_]png.Image{ try testutil.solidImage(2560, 1440, 0xFF111111), try testutil.solidImage(1280, 720, 0xFF222222) };
    defer for (&imgs) |*im| im.deinit(gpa);
    var cap = try build(gpa, mons, mons, &imgs);
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2560), cap.monitors[0].w);
    try std.testing.expectEqual(@as(u32, 1440), cap.monitors[0].h);
    try std.testing.expectEqual(@as(u32, 2560), cap.monitors[1].x);
    try std.testing.expect(cap.monitors[1].x + cap.monitors[1].w <= cap.image.width);
}

test "pieces are read once, deleted, and never through a symlink" {
    const gpa = std.testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-rt");
    defer tmp.deinit();
    const rt = tmp.path;
    var dbuf: [1024]u8 = undefined;
    const dir = try dirPath(&dbuf, rt);
    sys.mkdirMode(dir, 0o700);
    var pbuf: [1200]u8 = undefined;

    // a tiny 2x1 PNG as the only piece of a 2x1 monitor
    const data = try png.encode(gpa, &.{ 0xFFFF0000, 0xFF0000FF }, 2, 1);
    defer gpa.free(data);
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o600);
    var cap = try load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" });
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cap.image.pixels[1]);
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 0)) == null);
    try std.testing.expectError(error.CaptureTimedOut, loadWithin(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }, 20));

    // readable by others: refused, and still deleted
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o644);
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 0)) == null);

    // a symlink in its place is not followed; the target stays
    var tbuf: [1200]u8 = undefined;
    const target = try std.fmt.bufPrint(&tbuf, "{s}/keep.png", .{rt});
    try sys.writeFileExclusive(target, data, 0o600);
    try sys.symlink(target, try piecePath(&pbuf, rt, "abc", 0));
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));
    try std.testing.expect(sys.mtimeSec(target) != null);

    // a layout that does not add up: the files go anyway
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o600);
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 1), data, 0o600);
    try std.testing.expectError(error.BadLayout, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,4,1,1", .pieces = "0,0,2,1,1;2,0,2,1,1;0,0,9,9,1" }));
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 0)) == null);
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "abc", 1)) == null);

    // the directory open to others: refused
    const dfd = try sys.openDir(dir);
    sys.fchmod(dfd, 0o755);
    sys.close(dfd);
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "abc", 0), data, 0o600);
    try std.testing.expectError(error.NotAShellCapture, load(gpa, rt, .{ .id = "abc", .monitors = "0,0,2,1,1", .pieces = "0,0,2,1,1" }));
}

test "a piece written after Shotlet started is waited for; one that never comes times out" {
    const gpa = std.testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-rt");
    defer tmp.deinit();
    const rt = tmp.path;
    var dbuf: [1024]u8 = undefined;
    sys.mkdirMode(try dirPath(&dbuf, rt), 0o700);
    const data = try png.encode(gpa, &.{ 0xFF00FF00, 0xFF0000FF }, 2, 1);
    defer gpa.free(data);
    const Late = struct {
        fn write(root: []const u8, bytes: []const u8) void {
            sys.sleepMs(30);
            var b: [1200]u8 = undefined;
            sys.writeFileExclusive(piecePath(&b, root, "late", 1) catch unreachable, bytes, 0o600) catch unreachable;
        }
    };
    var pbuf: [1200]u8 = undefined;
    try sys.writeFileExclusive(try piecePath(&pbuf, rt, "late", 0), data, 0o600);
    const th = try std.Thread.spawn(.{}, Late.write, .{ rt, data });
    var cap = try load(gpa, rt, .{ .id = "late", .monitors = "0,0,4,1,1", .pieces = "0,0,2,1,1;2,0,2,1,1" });
    th.join();
    defer cap.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), cap.image.pixels[3]);
    try std.testing.expect(sys.mtimeSec(try piecePath(&pbuf, rt, "late", 1)) == null);
    // nothing there by the deadline: an error, not a wait forever
    try std.testing.expectError(error.CaptureTimedOut, readWhenThere(gpa, try piecePath(&pbuf, rt, "never", 0), sys.monoMs() + 20));
}

test "a 1.5 monitor in strips stitches exactly as the same monitor whole, next to a 2x one" {
    const gpa = std.testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-rt");
    defer tmp.deinit();
    const rt = tmp.path;
    var dbuf: [1024]u8 = undefined;
    sys.mkdirMode(try dirPath(&dbuf, rt), 0o700);
    // 2x: 4x4 logical = 8x8 px; 1.5: 4x4 logical = 6x6 px, a gradient
    var two: [64]u32 = undefined;
    for (&two, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i * 3));
    var half: [36]u32 = undefined;
    for (&half, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i * 7)) << 8;
    const mons = "0,0,4,4,2;4,0,4,4,1.5";
    const Run = struct {
        fn one(root: []const u8, id: []const u8, k: usize, px: []const u32, w: u32, h: u32) !void {
            const data = try png.encode(std.testing.allocator, px, w, h);
            defer std.testing.allocator.free(data);
            var b: [1200]u8 = undefined;
            try sys.writeFileExclusive(try piecePath(&b, root, id, k), data, 0o600);
        }
    };
    try Run.one(rt, "whole", 0, &two, 8, 8);
    try Run.one(rt, "whole", 1, &half, 6, 6);
    var whole = try load(gpa, rt, .{ .id = "whole", .monitors = mons, .pieces = mons });
    defer whole.deinit(gpa);
    // the 2x one in two strips, the 1.5 one in two (edges on whole pixels)
    try Run.one(rt, "strips", 0, two[0..32], 8, 4);
    try Run.one(rt, "strips", 1, two[32..], 8, 4);
    try Run.one(rt, "strips", 2, half[0..18], 6, 3);
    try Run.one(rt, "strips", 3, half[18..], 6, 3);
    var strips = try load(gpa, rt, .{ .id = "strips", .monitors = mons, .pieces = "0,0,4,2,2;0,2,4,2,2;4,0,4,2,1.5;4,2,4,2,1.5" });
    defer strips.deinit(gpa);
    try std.testing.expectEqual(whole.image.width, strips.image.width);
    try std.testing.expectEqualSlices(u32, whole.image.pixels, strips.image.pixels);
    try std.testing.expectEqualSlices(capture.Monitor, whole.monitors, strips.monitors);
    // the 1.5 monitor resampled to the image's 2x: 8x8 beside the 2x one
    try std.testing.expectEqual(@as(u32, 16), strips.image.width);
    try std.testing.expectEqual(@as(f64, 1.5), strips.monitors[1].scale);
}
