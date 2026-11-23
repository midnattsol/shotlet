//! One capture stream's state and its PipeWire callbacks: learn the
//! negotiated format, then copy the first good buffer's valid area into a
//! tight pixel array. Callbacks run on PipeWire's loop thread.

const std = @import("std");
const abi = @import("abi.zig");
const stream = @import("stream.zig");
const pw = @import("../pw.zig");
const shm_pixels = @import("../capture/direct/pixels.zig");

const VideoFormat = abi.VideoFormat;

pub const Frame = struct {
    width: u32,
    height: u32,
    /// 0xAARRGGBB; allocated with page_allocator
    pixels: []u32,

    pub fn deinit(self: *Frame) void {
        std.heap.page_allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const Ctx = struct {
    loop: ?*anyopaque = null,
    stream: ?*anyopaque = null,
    fmt: stream.Format = .{},
    /// tight 4-byte pixels of the (cropped) frame; page_allocator
    pixels: ?[]u32 = null,
    out_w: u32 = 0,
    out_h: u32 = 0,
    done: bool = false,
    failed: bool = false,
};

/// The listener every capture stream registers, with its Ctx as data.
pub const events = abi.StreamEvents{
    .state_changed = onStateChanged,
    .param_changed = onParamChanged,
    .process = onProcess,
};

fn onParamChanged(data: ?*anyopaque, id: u32, param: ?*const anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    stream.onFormat(ctx.stream, id, param, &ctx.fmt);
}

fn onStateChanged(data: ?*anyopaque, old: c_int, new: c_int, msg: ?[*:0]const u8) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    if (stream.onState("", old, new, msg)) {
        ctx.failed = true;
        pw.api.thread_loop_signal(ctx.loop, false);
    }
}

/// Copy the valid area row by row into a new tight pixel array, then
/// mark the ctx done (or failed when out of memory) and wake the waiter.
fn copyFrame(ctx: *Ctx, src: stream.Source) void {
    const crop = src.crop;
    const n: usize = @as(usize, crop.width) * crop.height;
    const pixels = std.heap.page_allocator.alloc(u32, n) catch {
        ctx.failed = true;
        pw.api.thread_loop_signal(ctx.loop, false);
        return;
    };
    const dst_bytes = std.mem.sliceAsBytes(pixels);
    const row_bytes = @as(usize, crop.width) * 4;
    var y: usize = 0;
    while (y < crop.height) : (y += 1) {
        const src_row = src.base[src.first + y * src.stride ..][0..row_bytes];
        @memcpy(dst_bytes[y * row_bytes ..][0..row_bytes], src_row);
    }
    ctx.pixels = pixels;
    ctx.out_w = crop.width;
    ctx.out_h = crop.height;
    ctx.done = true;
    pw.api.thread_loop_signal(ctx.loop, false);
}

fn onProcess(data: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data orelse return));
    const s = ctx.stream orelse return;
    const b = pw.api.stream_dequeue_buffer(s) orelse return;
    defer _ = pw.api.stream_queue_buffer(s, b);
    if (ctx.done or ctx.failed) return;
    const sb = b.buffer orelse return;
    const src = stream.validArea(sb, ctx.fmt.width, ctx.fmt.height) orelse return;
    copyFrame(ctx, src);
}

/// Turn a captured ctx into an opaque 0xAARRGGBB Frame (in place); frees
/// the pixels on an unsupported format.
pub fn finishFrame(ctx: *Ctx) !Frame {
    const pixels = ctx.pixels.?;
    // the same bytes as wl_shm's little-endian formats
    const shm: u32 = switch (@as(VideoFormat, @fromBackingInt(ctx.fmt.format))) {
        .BGRA, .BGRx => shm_pixels.fmt_xrgb8888,
        .RGBA, .RGBx => shm_pixels.fmt_xbgr8888,
        else => {
            std.heap.page_allocator.free(pixels);
            return error.UnsupportedFormat;
        },
    };
    switch (shm) {
        inline shm_pixels.fmt_xrgb8888, shm_pixels.fmt_xbgr8888 => |f| for (pixels) |*p| {
            p.* = shm_pixels.convert(f, p.*);
        },
        else => unreachable,
    }
    return .{ .width = ctx.out_w, .height = ctx.out_h, .pixels = pixels };
}

test "finishFrame makes BGRx and RGBx opaque 0xAARRGGBB" {
    const page = std.heap.page_allocator;
    var ctx: Ctx = .{ .out_w = 2, .out_h = 1 };
    ctx.pixels = try page.dupe(u32, &.{ 0x00112233, 0x7F445566 });
    ctx.fmt.format = @backingInt(VideoFormat.BGRx);
    var f = try finishFrame(&ctx);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF112233, 0xFF445566 }, f.pixels);
    f.deinit();
    ctx.pixels = try page.dupe(u32, &.{ 0x00332211, 0x7F665544 });
    ctx.fmt.format = @backingInt(VideoFormat.RGBA);
    f = try finishFrame(&ctx);
    try std.testing.expectEqualSlices(u32, &.{ 0xFF112233, 0xFF445566 }, f.pixels);
    f.deinit();
    ctx.pixels = try page.dupe(u32, &.{0});
    ctx.fmt.format = 99;
    try std.testing.expectError(error.UnsupportedFormat, finishFrame(&ctx));
}
