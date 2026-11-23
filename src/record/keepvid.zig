//! A finished recording in the history (or the cache, with the history
//! off): an ordinary entry whose image is the first picture, with `saved`
//! the video file, plus
//!
//!     <entry>/video       key=value: path, format, duration_ms, frames,
//!                         fps, width, height, strip (frame of each picture)
//!     <entry>/strip.png   the filmstrip (strip.zig), pictures side by side
//!
//! The video itself stays where it was written (the Videos folder).

const std = @import("std");
const log = std.log.scoped(.recording);
const history = @import("../app/history.zig");
const kvfile = @import("../app/kvfile.zig");
const keep = @import("../app/keep.zig");
const config = @import("../app/config.zig");
const env_mod = @import("../app/env.zig");
const png = @import("../gfx/png.zig");
const sys = @import("../platform/api.zig").sys;
const strip_mod = @import("strip.zig");
const sink = @import("../encode/sink.zig");

pub const Info = struct {
    path: []const u8 = "",
    format: sink.Format = .mp4,
    duration_ms: i64 = 0,
    frames: u64 = 0,
    fps: u32 = 30,
    width: u32 = 0,
    height: u32 = 0,
    /// frame number of each filmstrip picture, "0,12,24"
    strip: []const u8 = "",

    const header = "shotlet-video 1";

    pub fn serialize(self: *const Info, gpa: std.mem.Allocator) ![]u8 {
        var w = try kvfile.Writer.init(gpa, header);
        errdefer w.deinit();
        try w.str("path", self.path);
        try w.tag("format", self.format);
        try w.int("duration_ms", self.duration_ms);
        try w.int("frames", self.frames);
        try w.int("fps", self.fps);
        try w.size("size", self.width, self.height);
        try w.str("strip", self.strip);
        return w.finish();
    }

    /// Values point into `data`, whose text values are unescaped where
    /// they lie.
    pub fn parse(data: []u8) !Info {
        var r = kvfile.Reader.init(data, header) catch return error.BadVideoInfo;
        var i: Info = .{};
        while (r.next()) |f| {
            const v = f.value;
            if (f.is("path")) i.path = kvfile.textIn(data, v);
            if (f.is("format")) i.format = std.meta.stringToEnum(sink.Format, v) orelse .mp4;
            if (f.is("duration_ms")) i.duration_ms = std.fmt.parseInt(i64, v, 10) catch 0;
            if (f.is("frames")) i.frames = std.fmt.parseInt(u64, v, 10) catch 0;
            if (f.is("fps")) i.fps = std.fmt.parseInt(u32, v, 10) catch 30;
            if (f.is("strip")) i.strip = kvfile.textIn(data, v);
            if (f.is("size")) if (kvfile.parseSize(v)) |sz| {
                i.width, i.height = sz;
            };
        }
        if (i.path.len == 0) return error.BadVideoInfo;
        return i;
    }
};

/// Read an entry's video info (null when it is not a recording). The
/// values point into the returned buffer.
pub fn read(gpa: std.mem.Allocator, root: []const u8, id: []const u8) ?struct { info: Info, buf: []u8 } {
    const data = history.readFile(gpa, root, id, .video) catch return null;
    const info = Info.parse(data) catch {
        gpa.free(data);
        return null;
    };
    return .{ .info = info, .buf = data };
}

pub const What = struct {
    info: Info,
    first: []const u32,
    first_w: u32,
    first_h: u32,
    strip: *const strip_mod.Strip,
};

/// Store the recording; null (logged) when nothing was stored.
pub fn store(gpa: std.mem.Allocator, env: env_mod.Env, cfg: *const config.Config, what: What) ?keep.Kept {
    return storeInner(gpa, env, cfg, what) catch |err| {
        log.warn("could not keep the recording: {t}", .{err});
        return null;
    };
}

fn storeInner(gpa: std.mem.Allocator, env: env_mod.Env, cfg: *const config.Config, what: What) !?keep.Kept {
    if (!keep.wanted(cfg)) return null;
    const image = try png.encode(gpa, what.first, what.first_w, what.first_h);
    defer gpa.free(image);
    const info = try what.info.serialize(gpa);
    defer gpa.free(info);
    var extras: [2]history.NewEntry.Extra = .{ .{ .name = "video", .data = info }, undefined };
    var n: usize = 1;
    const strip_png: ?[]u8 = if (what.strip.n > 0) try stripPng(gpa, what.strip) else null;
    defer if (strip_png) |sp| gpa.free(sp);
    if (strip_png) |sp| {
        extras[1] = .{ .name = "strip.png", .data = sp };
        n = 2;
    }
    const k = try keep.store(gpa, env, cfg, .{
        .meta = .{ .time_ms = sys.realtimeMs(), .width = what.info.width, .height = what.info.height, .saved = what.info.path },
        .image_png = image,
        .pixels = what.first,
        .width = what.first_w,
        .height = what.first_h,
        .extras = extras[0..n],
    });
    keep.prune(gpa, cfg, k.root());
    return k;
}

fn stripPng(gpa: std.mem.Allocator, s: *const strip_mod.Strip) ![]u8 {
    const px = try s.joined(gpa);
    defer gpa.free(px);
    return png.encode(gpa, px, s.w * @as(u32, @intCast(s.n)), s.h);
}

test "video info round-trips" {
    const gpa = std.testing.allocator;
    const i: Info = .{ .path = "/v/a b\nc\\.mp4", .format = .gif, .duration_ms = 2500, .frames = 38, .fps = 15, .width = 320, .height = 200, .strip = "0,4,8" };
    const s = try i.serialize(gpa);
    defer gpa.free(s);
    // a newline in the path stays inside its value
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, s, "\n"));
    const back = try Info.parse(s);
    try std.testing.expectEqualStrings("/v/a b\nc\\.mp4", back.path);
    try std.testing.expectEqual(sink.Format.gif, back.format);
    try std.testing.expectEqual(@as(i64, 2500), back.duration_ms);
    try std.testing.expectEqual(@as(u32, 200), back.height);
    try std.testing.expectEqualStrings("0,4,8", back.strip);
    var nope = "nope".*;
    try std.testing.expectError(error.BadVideoInfo, Info.parse(&nope));
}

test "an older video file, its path unescaped, still reads" {
    var old = "shotlet-video 1\npath=/v/a b.mp4\nformat=mp4\nduration_ms=10\nframes=1\nfps=30\nsize=4x2\nstrip=0\n".*;
    const i = try Info.parse(&old);
    try std.testing.expectEqualStrings("/v/a b.mp4", i.path);
    try std.testing.expectEqual(@as(u32, 4), i.width);
}
