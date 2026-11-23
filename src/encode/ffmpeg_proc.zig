//! The one way Shotlet runs the ffmpeg program: found on PATH (`find`,
//! error.NoFfmpeg), its arguments built on `Args` (the common prefix,
//! the H.264/AAC/MP4 output settings), and a failed run reported the same
//! way (logged, error.FfmpegFailed).
//!
//! Recording: raw YUV 4:2:0 frames on its stdin, 16-bit stereo PCM on
//! fd 3 (when the recording has sound), H.264 by VA-API when the GPU
//! offers it, else libx264; AAC sound; the index at the front. Used for
//! recordings with sound, and whenever the FFmpeg libraries cannot be
//! loaded in process. Trimming (`cut`) and the trim preview (`frameAt`)
//! go through it too.

const std = @import("std");
const switches = @import("../platform/api/switches.zig");
const proc = @import("../platform/api.zig").proc;
const yuv = @import("yuv.zig");
const sys = @import("../platform/api.zig").sys;

pub const Quality = @import("av_mp4.zig").Quality;

pub const Options = struct {
    width: u32,
    height: u32,
    fps: u32,
    quality: Quality = .medium,
    audio: bool = false,
    audio_rate: u32 = 48000,
    /// a VA-API render node, e.g. /dev/dri/renderD128
    vaapi: ?[:0]const u8 = null,
};

pub const Proc = struct {
    gpa: std.mem.Allocator,
    child: proc.Child,
    opts: Options,
    frame: []u8,
    frames: u64 = 0,

    pub fn open(gpa: std.mem.Allocator, envp: proc.Envp, path: [:0]const u8, opts: Options) !Proc {
        var exe_buf: ExeBuf = undefined;
        const exe = try find(&exe_buf, envp);
        var args: Args = .{};
        const argv = try buildArgs(&args, exe, path, opts);
        const frame = try gpa.alloc(u8, frameBytes(opts.width, opts.height));
        errdefer gpa.free(frame);
        const child = try proc.spawn(argv, envp, .{ .stdin = true, .fd3 = opts.audio, .stderr = true });
        return .{ .gpa = gpa, .child = child, .opts = opts, .frame = frame };
    }

    /// One frame; frames are numbered by their order (constant rate).
    pub fn addFrame(self: *Proc, px: []const u32, stride: usize) !void {
        const w = self.opts.width;
        const h = self.opts.height;
        const ysz = @as(usize, w) * h;
        yuv.toI420(px, stride, w, h, .{
            .y = self.frame.ptr,
            .u = self.frame.ptr + ysz,
            .v = self.frame.ptr + ysz + ysz / 4,
            .y_stride = w,
            .u_stride = w / 2,
            .v_stride = w / 2,
        });
        try sys.writeAllBlocking(self.child.stdin orelse return error.Closed, self.frame);
        self.frames += 1;
    }

    /// The previous frame once more (or black before the first).
    pub fn repeat(self: *Proc) !void {
        if (self.frames == 0) @memset(self.frame, 16);
        try sys.writeAllBlocking(self.child.stdin orelse return error.Closed, self.frame);
        self.frames += 1;
    }

    /// Interleaved stereo samples (any thread but the video one).
    pub fn addAudio(self: *Proc, samples: []const i16) !void {
        const fd = self.child.fd3 orelse return;
        try sys.writeAllBlocking(fd, std.mem.sliceAsBytes(samples));
    }

    /// Close the inputs and wait for ffmpeg to write the file.
    pub fn finish(self: *Proc) !void {
        defer self.gpa.free(self.frame);
        try check("recording", self.child.wait(120_000));
    }

    pub fn abort(self: *Proc) void {
        self.child.kill();
        self.gpa.free(self.frame);
    }
};

pub fn frameBytes(w: u32, h: u32) usize {
    return @as(usize, w) * h * 3 / 2;
}

pub const ExeBuf = [512]u8;

/// The ffmpeg program on the PATH of `envp`.
pub fn find(buf: *ExeBuf, envp: proc.Envp) error{NoFfmpeg}![:0]const u8 {
    return proc.which(buf, envp, "ffmpeg") orelse error.NoFfmpeg;
}

/// An exit status that is not 0 (null: killed or timed out) is logged
/// with what ffmpeg was doing and becomes error.FfmpegFailed.
fn check(what: []const u8, status: ?u8) error{FfmpegFailed}!void {
    if (status != null and status.? == 0) return;
    std.log.warn("{s}: ffmpeg exited with {?d}", .{ what, status });
    return error.FfmpegFailed;
}

/// Run ffmpeg to completion; its standard output, owned (at most `max`
/// bytes). Failures as `check`.
fn run(gpa: std.mem.Allocator, envp: proc.Envp, what: []const u8, args: *Args, max: usize, timeout_ms: i64) ![]u8 {
    const res = try proc.output(gpa, args.argv(), envp, max, timeout_ms);
    errdefer gpa.free(res.out);
    try check(what, res.status);
    return res.out;
}

/// An ffmpeg command line: pointers to the caller's strings, and room
/// for the ones printed here.
pub const Args = struct {
    list: [72]?[*:0]const u8 = @splat(null),
    n: usize = 0,
    text: [8192]u8 = undefined,
    used: usize = 0,

    /// The program and what every run starts with: no banner, no
    /// keyboard, errors only.
    fn start(self: *Args, exe: [*:0]const u8) !void {
        try self.addAll(&.{ exe, "-hide_banner", "-nostdin", "-loglevel", "error" });
    }

    fn add(self: *Args, a: [*:0]const u8) !void {
        if (self.n == self.list.len) return error.TooManyArgs;
        self.list[self.n] = a;
        self.n += 1;
    }

    fn print(self: *Args, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrintSentinel(self.text[self.used..], fmt, args, 0);
        self.used += s.len + 1;
        try self.add(s.ptr);
    }

    fn addAll(self: *Args, items: []const [*:0]const u8) !void {
        for (items) |a| try self.add(a);
    }

    /// Software H.264 at the quality's constant rate factor.
    fn x264(self: *Args, q: Quality) !void {
        try self.addAll(&.{ "-c:v", "libx264", "-preset", "veryfast", "-crf", crf(q), "-pix_fmt", "yuv420p" });
    }

    fn aac(self: *Args) !void {
        try self.addAll(&.{ "-c:a", "aac", "-b:a", "160k" });
    }

    /// The MP4 output, its index at the front.
    fn mp4(self: *Args, path: [*:0]const u8) !void {
        try self.addAll(&.{ "-movflags", "+faststart", "-f", "mp4", path });
    }

    fn argv(self: *const Args) []const ?[*:0]const u8 {
        return self.list[0..self.n];
    }
};

fn crf(q: Quality) [*:0]const u8 {
    return switch (q) {
        .low => "30",
        .medium => "25",
        .high => "20",
    };
}

fn buildArgs(s: *Args, exe: [*:0]const u8, path: [*:0]const u8, o: Options) ![]const ?[*:0]const u8 {
    try s.start(exe);
    try s.add("-y");
    if (o.vaapi) |dev| try s.addAll(&.{ "-vaapi_device", dev.ptr });
    // inputs open at once (no probing ahead): the other pipe must not wait
    try s.addAll(&.{ "-probesize", "32", "-analyzeduration", "0", "-thread_queue_size", "64" });
    try s.addAll(&.{ "-f", "rawvideo", "-pix_fmt", "yuv420p", "-color_range", "tv", "-colorspace", "bt709" });
    try s.add("-s");
    try s.print("{d}x{d}", .{ o.width, o.height });
    try s.add("-r");
    try s.print("{d}", .{o.fps});
    try s.addAll(&.{ "-i", "pipe:0" });
    if (o.audio) {
        try s.addAll(&.{ "-probesize", "32", "-analyzeduration", "0", "-thread_queue_size", "64" });
        try s.addAll(&.{ "-f", "s16le", "-ac", "2", "-ar" });
        try s.print("{d}", .{o.audio_rate});
        try s.addAll(&.{ "-i", "pipe:3" });
    }
    if (o.vaapi != null) {
        try s.addAll(&.{ "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-qp", crf(o.quality) });
    } else {
        try s.x264(o.quality);
    }
    try s.add("-g");
    try s.print("{d}", .{o.fps * 2});
    try s.addAll(&.{ "-color_primaries", "bt709", "-color_trc", "bt709" });
    if (o.audio) try s.aac();
    try s.mp4(path);
    return s.argv();
}

/// "S.mmm", the form ffmpeg's -ss and -t take.
fn seconds(buf: []u8, ms: i64) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{d}.{d:0>3}", .{ @divTrunc(ms, 1000), @as(u64, @intCast(@mod(ms, 1000))) }, 0);
}

fn cutArgs(s: *Args, exe: [*:0]const u8, src: []const u8, dst: [*:0]const u8, start_ms: i64, len_ms: i64) ![]const ?[*:0]const u8 {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try s.start(exe);
    try s.addAll(&.{ "-y", "-ss" });
    try s.print("{s}", .{try seconds(&a, start_ms)});
    try s.add("-i");
    try s.print("{s}", .{src});
    try s.add("-t");
    try s.print("{s}", .{try seconds(&b, len_ms)});
    try s.x264(.high);
    try s.aac();
    try s.mp4(dst);
    return s.argv();
}

/// `len_ms` of the MP4 `src` from `start_ms`, re-encoded (so the cut is
/// exact; sound kept) into `dst`.
pub fn cut(gpa: std.mem.Allocator, envp: proc.Envp, src: []const u8, dst: [:0]const u8, start_ms: i64, len_ms: i64) !void {
    var exe_buf: ExeBuf = undefined;
    var args: Args = .{};
    _ = try cutArgs(&args, try find(&exe_buf, envp), src, dst, start_ms, len_ms);
    gpa.free(try run(gpa, envp, "trim", &args, 1 << 20, 10 * 60_000));
}

fn frameArgs(s: *Args, exe: [*:0]const u8, path: []const u8, ms: i64) ![]const ?[*:0]const u8 {
    var a: [32]u8 = undefined;
    try s.start(exe);
    try s.add("-ss");
    try s.print("{s}", .{try seconds(&a, ms)});
    try s.add("-i");
    try s.print("{s}", .{path});
    try s.addAll(&.{ "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgra", "-" });
    return s.argv();
}

/// The first picture of an MP4 at `ms`, as 0xFFRRGGBB w x h; owned.
pub fn frameAt(gpa: std.mem.Allocator, envp: proc.Envp, path: []const u8, ms: i64, w: u32, h: u32) ![]u32 {
    var exe_buf: ExeBuf = undefined;
    var args: Args = .{};
    _ = try frameArgs(&args, try find(&exe_buf, envp), path, ms);
    const size = @as(usize, w) * h * 4;
    const out = try run(gpa, envp, "video preview", &args, size + 1, 30_000);
    errdefer gpa.free(out);
    if (out.len != size) return error.NoFrame;
    const px: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out));
    for (px) |*p| p.* |= 0xFF000000;
    return px;
}

/// A render node where ffmpeg can encode H.264 with VA-API: tried once
/// with a tiny encode (about a tenth of a second). Null without one.
pub fn probeVaapi(gpa: std.mem.Allocator, envp: proc.Envp) ?[:0]const u8 {
    if (switches.get().no_vaapi) return null;
    var exe_buf: ExeBuf = undefined;
    const exe = find(&exe_buf, envp) catch return null;
    var dev_buf: [2][:0]const u8 = undefined;
    for (proc.hwEncodeDevices(&dev_buf)) |dev| {
        var args: Args = .{};
        args.start(exe) catch return null;
        args.addAll(&.{ "-vaapi_device", dev.ptr, "-f", "lavfi", "-i", "color=c=gray:s=64x64:d=0.1", "-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-f", "null", "-" }) catch return null;
        // no device is no failure: probe quietly
        const r = proc.output(gpa, args.argv(), envp, 4096, 5000) catch continue;
        gpa.free(r.out);
        if (r.status != null and r.status.? == 0) return dev;
    }
    return null;
}

/// A command line as one string, for the tests.
fn joined(buf: []u8, argv: []const ?[*:0]const u8) []const u8 {
    var n: usize = 0;
    for (argv, 0..) |x, i| {
        const p = std.mem.span(x.?);
        if (i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    return buf[0..n];
}

test "ffmpeg arguments for software and VA-API encodes" {
    var buf: [1024]u8 = undefined;
    var s: Args = .{};
    const line = joined(&buf, try buildArgs(&s, "/usr/bin/ffmpeg", "/tmp/o.mp4", .{ .width = 640, .height = 360, .fps = 30, .audio = true }));
    try std.testing.expect(std.mem.startsWith(u8, line, "/usr/bin/ffmpeg -hide_banner -nostdin -loglevel error -y "));
    try std.testing.expect(std.mem.indexOf(u8, line, "-s 640x360 -r 30 -i pipe:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-i pipe:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-c:v libx264 -preset veryfast -crf 25 -pix_fmt yuv420p") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-c:a aac -b:a 160k") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "-movflags +faststart -f mp4 /tmp/o.mp4"));
    var s2: Args = .{};
    const line2 = joined(&buf, try buildArgs(&s2, "/usr/bin/ffmpeg", "/tmp/o.mp4", .{ .width = 64, .height = 64, .fps = 60, .quality = .low, .vaapi = "/dev/dri/renderD128" }));
    try std.testing.expect(std.mem.indexOf(u8, line2, "-vaapi_device /dev/dri/renderD128 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "-c:v h264_vaapi -qp 30") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "libx264") == null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "aac") == null);
}

test "trimming and the preview share the prefix and the output settings" {
    var buf: [1024]u8 = undefined;
    var s: Args = .{};
    try std.testing.expectEqualStrings(
        "ffmpeg -hide_banner -nostdin -loglevel error -y -ss 1.050 -i /v/a b.mp4 -t 62.000 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart -f mp4 /v/a b-trim.mp4",
        joined(&buf, try cutArgs(&s, "ffmpeg", "/v/a b.mp4", "/v/a b-trim.mp4", 1050, 62_000)),
    );
    var s2: Args = .{};
    try std.testing.expectEqualStrings(
        "ffmpeg -hide_banner -nostdin -loglevel error -ss 0.007 -i /v/a.mp4 -frames:v 1 -f rawvideo -pix_fmt bgra -",
        joined(&buf, try frameArgs(&s2, "ffmpeg", "/v/a.mp4", 7)),
    );
}

test "a long path fits; a failed exit is an error" {
    var s: Args = .{};
    const long: [4000]u8 = @splat('x');
    _ = try cutArgs(&s, "ffmpeg", &long, "/o.mp4", 0, 1000);
    try std.testing.expectError(error.FfmpegFailed, check("test", 1));
    try std.testing.expectError(error.FfmpegFailed, check("test", null));
    try check("test", 0);
}

test "the ffmpeg program writes H.264 and AAC that ffprobe reads back" {
    const gpa = std.testing.allocator;
    const envp: proc.Envp = @ptrCast(std.c.environ);
    var buf: [512]u8 = undefined;
    const probe = proc.which(&buf, envp, "ffprobe") orelse return error.SkipZigTest;
    const dir = try sys.makeTempDir(gpa, "/tmp", "shotlet-ff");
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/a.mp4", .{dir}, 0);
    defer gpa.free(path);
    var p = Proc.open(gpa, envp, path, .{ .width = 64, .height = 48, .fps = 30, .audio = true }) catch |err| {
        if (err == error.NoFfmpeg) return error.SkipZigTest;
        return err;
    };
    // sound from its own thread, as when recording
    const Audio = struct {
        fn run(pp: *Proc) void {
            var pcm: [1600 * 2]i16 = @splat(0);
            for (0..30) |_| pp.addAudio(&pcm) catch return;
        }
    };
    const t = try std.Thread.spawn(.{}, Audio.run, .{&p});
    var px: [64 * 48]u32 = @splat(0xFF336699);
    for (0..30) |i| {
        px[i] = 0xFFFFFFFF;
        try p.addFrame(&px, 64);
    }
    t.join();
    try p.finish();
    const r = try proc.output(gpa, &.{ probe.ptr, "-v", "error", "-show_entries", "stream=codec_name,width,height,avg_frame_rate", "-of", "csv=p=0", path.ptr }, envp, 4096, 10_000);
    defer gpa.free(r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "h264,64,48,30/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "aac") != null);
}
