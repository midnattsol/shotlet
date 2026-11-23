//! Cutting a recording to [start, end): MP4 through the ffmpeg program
//! (re-encoded, so the cut is exact, sound kept), GIF by our own decoder
//! and encoder. The result is a new file next to the original
//! (`<name>-trim.mp4`), never over one.

const std = @import("std");
const proc = @import("../platform/api.zig").proc;
const ffmpeg = @import("../encode/ffmpeg_proc.zig");
const gif = @import("../encode/gif.zig");
const gifdec = @import("../encode/gifdec.zig");
const sys = @import("../platform/api.zig").sys;
const filename = @import("../app/filename.zig");

pub const Range = struct { start_ms: i64, end_ms: i64 };

/// `<dir>/<base>-trim<ext>` (or -trim-2 ...), reserved; owned.
pub fn outputPath(gpa: std.mem.Allocator, src: []const u8) ![:0]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, src, '/') orelse return error.BadPath;
    const dot = std.mem.lastIndexOfScalar(u8, src, '.') orelse src.len;
    if (dot < slash) return error.BadPath;
    var base_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "{s}-trim", .{src[slash + 1 .. dot]});
    return filename.reserveUnique(gpa, src[0..slash], base, src[dot..]);
}

/// Write the part `r` of `src` to `dst` (already reserved).
pub fn cut(gpa: std.mem.Allocator, envp: proc.Envp, src: []const u8, dst: [:0]const u8, r: Range) !void {
    if (r.end_ms <= r.start_ms) return error.EmptyRange;
    if (std.ascii.endsWithIgnoreCase(src, ".gif")) return cutGif(gpa, src, dst, r);
    return ffmpeg.cut(gpa, envp, src, dst, r.start_ms, r.end_ms - r.start_ms);
}

fn cutGif(gpa: std.mem.Allocator, src: []const u8, dst: [:0]const u8, r: Range) !void {
    const data = try sys.readFileAlloc(gpa, src, 512 * 1024 * 1024);
    defer gpa.free(data);
    var d = try gifdec.Decoder.init(gpa, data);
    defer d.deinit();
    const fd = try sys.createWrite(dst);
    defer sys.close(fd);
    var enc = try gif.Encoder.init(gpa, d.width, d.height, .{}, fd);
    defer enc.deinit();
    var last: ?[]u32 = null;
    defer if (last) |l| gpa.free(l);
    while (try d.next()) |f| {
        const end = f.start_ms + f.delay_ms;
        if (end <= r.start_ms) {
            // the picture showing when the cut starts opens it
            if (last == null) last = try gpa.alloc(u32, f.pixels.len);
            @memcpy(last.?, f.pixels);
            continue;
        }
        if (f.start_ms >= r.end_ms) break;
        if (last) |l| {
            if (f.start_ms > r.start_ms) try enc.addFrame(l, d.width, 0);
            gpa.free(l);
            last = null;
        }
        try enc.addFrame(f.pixels, d.width, @max(0, f.start_ms - r.start_ms));
    }
    if (last) |l| try enc.addFrame(l, d.width, 0);
    try enc.finish(r.end_ms - r.start_ms);
}

const testutil = @import("../testutil.zig");

test "trimmed GIFs keep the pictures of the range" {
    const gpa = std.testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-trim");
    defer tmp.deinit();
    const src = try tmp.joinZ("a.gif");
    defer gpa.free(src);
    {
        const fd = try sys.createWrite(src);
        defer sys.close(fd);
        var e = try gif.Encoder.init(gpa, 16, 8, .{}, fd);
        defer e.deinit();
        var px: [16 * 8]u32 = undefined;
        for (0..10) |i| {
            @memset(&px, 0xFF000000 | @as(u32, @intCast(i * 20)) << 8);
            try e.addFrame(&px, 16, @intCast(i * 100));
        }
        try e.finish(1000);
    }
    const dst = try outputPath(gpa, src);
    defer gpa.free(dst);
    try std.testing.expect(std.mem.endsWith(u8, dst, "/a-trim.gif"));
    try cut(gpa, testutil.envp(), src, dst, .{ .start_ms = 250, .end_ms = 650 });
    const data = try sys.readFileAlloc(gpa, dst, 1 << 20);
    defer gpa.free(data);
    const st = try gifdec.stats(gpa, data);
    try std.testing.expectEqual(@as(i64, 400), st.duration_ms);
    try std.testing.expectEqual(@as(u32, 5), st.frames);
}
