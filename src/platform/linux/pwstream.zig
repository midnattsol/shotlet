//! Continuous PipeWire capture for recordings: one connection (the
//! portal's fd, or the session's PipeWire for a node the GNOME Shell
//! integration started) with a video stream and up to two sound streams
//! (microphone: the default source; system sound: the default sink's
//! monitor). Callbacks run on PipeWire's thread with the mapped buffer;
//! they copy what they need and return.

const std = @import("std");
const pw = @import("pw.zig");
const sys = @import("sys.zig");

pub const VideoFormat = pw.VideoFormat;

const types = @import("../api/record.zig");
/// A video buffer as mapped: the valid area of the frame.
pub const Raw = types.Raw;
pub const VideoFn = types.VideoFn;
pub const AudioFn = types.AudioFn;
pub const AudioSource = types.AudioSource;
pub const rate = types.audio_rate;

const max_streams = 3;

const Slot = struct {
    owner: *Capture = undefined,
    stream: ?*anyopaque = null,
    hook: pw.SpaHook = .{},
    /// the negotiated video format
    fmt: pw.Format = .{},
    video: ?VideoFn = null,
    audio: ?AudioFn = null,
    ctx: *anyopaque = undefined,
    failed: bool = false,
    frames: u64 = 0,
};

pub const Capture = struct {
    pre: pw.Pre,
    slots: [max_streams]Slot = @splat(.{}),
    n: usize = 0,

    /// Connect over the portal's fd (consumed), or to the session's
    /// PipeWire daemon when null.
    pub fn open(gpa: std.mem.Allocator, fd: ?i32) !*Capture {
        const self = try gpa.create(Capture);
        errdefer gpa.destroy(self);
        self.* = .{ .pre = if (fd) |f| try pw.preconnect(f) else try pw.connectDaemon("shotlet-rec") };
        return self;
    }

    pub fn close(self: *Capture, gpa: std.mem.Allocator) void {
        var streams: [max_streams]?*anyopaque = @splat(null);
        for (self.slots[0..self.n], 0..) |s, i| streams[i] = s.stream;
        pw.teardown(&self.pre, streams[0..self.n]);
        gpa.destroy(self);
    }

    /// Whether any stream reported an error.
    pub fn failed(self: *const Capture) bool {
        for (self.slots[0..self.n]) |*s| if (@atomicLoad(bool, &s.failed, .acquire)) return true;
        return false;
    }

    pub fn videoFrames(self: *const Capture) u64 {
        for (self.slots[0..self.n]) |*s| if (s.video != null) return @atomicLoad(u64, &s.frames, .acquire);
        return 0;
    }

    pub fn addVideo(self: *Capture, node: u32, cb: VideoFn, ctx: *anyopaque) !void {
        var pod_buf: [256]u8 align(8) = undefined;
        const pod = pw.buildFormatPod(&pod_buf) orelse return error.Pod;
        const slot = try self.newSlot(ctx);
        slot.video = cb;
        try self.connect(slot, "shotlet-record", null, node, pod);
    }

    pub fn addAudio(self: *Capture, src: AudioSource, cb: AudioFn, ctx: *anyopaque) !void {
        var pod_buf: [256]u8 align(8) = undefined;
        const pod = pw.buildAudioFormatPod(&pod_buf, rate, 2) orelse return error.Pod;
        const props: [*:0]const u8 = switch (src) {
            .mic => "media.type=Audio media.category=Capture media.role=Screen node.name=shotlet-record-mic",
            .system => "media.type=Audio media.category=Capture media.role=Screen stream.capture.sink=true node.name=shotlet-record-system",
        };
        const slot = try self.newSlot(ctx);
        slot.audio = cb;
        try self.connect(slot, "shotlet-record-audio", props, 0xFFFFFFFF, pod);
    }

    fn newSlot(self: *Capture, ctx: *anyopaque) !*Slot {
        if (self.n == max_streams) return error.TooManyStreams;
        const s = &self.slots[self.n];
        s.* = .{ .owner = self, .ctx = ctx };
        return s;
    }

    fn connect(self: *Capture, slot: *Slot, name: [*:0]const u8, props: ?[*:0]const u8, target: u32, pod: []const u8) !void {
        const api = &pw.api;
        api.thread_loop_lock(self.pre.loop);
        defer api.thread_loop_unlock(self.pre.loop);
        const p = if (props) |s| api.properties_new_string(s) else null;
        slot.stream = api.stream_new(self.pre.core, name, p) orelse return error.PwStream;
        self.n += 1;
        api.stream_add_listener(slot.stream, &slot.hook, &events, slot);
        const params = [_][*]const u8{pod.ptr};
        if (api.stream_connect(slot.stream, pw.PW_DIRECTION_INPUT, target, pw.PW_STREAM_FLAG_AUTOCONNECT | pw.PW_STREAM_FLAG_MAP_BUFFERS, &params, 1) < 0)
            return error.PwConnect;
    }
};

const events: pw.StreamEvents = .{
    .state_changed = onState,
    .param_changed = onParam,
    .process = onProcess,
};

fn onState(data: ?*anyopaque, old: c_int, new: c_int, msg: ?[*:0]const u8) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    if (pw.onState("recording: ", old, new, msg)) @atomicStore(bool, &slot.failed, true, .release);
}

fn onParam(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    if (slot.video == null) return;
    pw.onFormat(slot.stream, id, param, &slot.fmt);
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(data orelse return));
    const b = pw.api.stream_dequeue_buffer(slot.stream) orelse return;
    defer _ = pw.api.stream_queue_buffer(slot.stream, b);
    const sb = b.buffer orelse return;
    const now = sys.monoNs();
    if (slot.audio) |cb| {
        const c = pw.chunkOf(sb) orelse return;
        if (c.avail <= c.offset) return;
        const n = (c.avail - c.offset) / 4;
        const samples: [*]const i16 = @ptrCast(@alignCast(c.base + c.offset));
        cb(slot.ctx, samples[0 .. n * 2], now - @divTrunc(@as(i64, @intCast(n)) * std.time.ns_per_s, rate));
        return;
    }
    const cb = slot.video orelse return;
    const src = pw.validArea(sb, slot.fmt.width, slot.fmt.height) orelse return;
    const raw: Raw = .{ .base = src.start(), .stride = src.stride, .width = src.crop.width, .height = src.crop.height, .format = @fromBackingInt(slot.fmt.format), .time_ns = now };
    cb(slot.ctx, &raw);
    _ = @atomicRmw(u64, &slot.frames, .Add, 1, .release);
}
