//! What every PipeWire stream client shares, screenshot grab and
//! recording alike: the negotiated video format, the valid area of a
//! mapped buffer, and the format and state callbacks' common part.
//! Everything here runs on PipeWire's loop thread.

const std = @import("std");
const abi = @import("abi.zig");
const pod = @import("pod.zig");
const pw = @import("../pw.zig");

const SpaMetaRegion = abi.SpaMetaRegion;

/// The negotiated video format and size, out of a Format pod.
pub const Format = struct {
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// forEachProp visitor filling a Format.
pub fn visitFormat(f: *Format, key: u32, vt: u32, val: []const u8) void {
    if (key == abi.SPA_FORMAT_VIDEO_format and vt == abi.SPA_TYPE_Id and val.len >= 4) {
        f.format = std.mem.readInt(u32, val[0..4], .little);
    } else if (key == abi.SPA_FORMAT_VIDEO_size and vt == abi.SPA_TYPE_Rectangle and val.len >= 8) {
        f.width = std.mem.readInt(u32, val[0..4], .little);
        f.height = std.mem.readInt(u32, val[4..8], .little);
    }
}

/// param_changed's common part: on the negotiated Format, parse it into
/// `f`, then ask for crop regions (some producers send a larger buffer
/// and mark the valid area with SPA_META_VideoCrop).
pub fn onFormat(stream: ?*anyopaque, id: u32, param: ?*const anyopaque, f: *Format) void {
    std.log.debug("pw param_changed id={d} param={}", .{ id, param != null });
    if (id != abi.SPA_PARAM_Format or param == null) return;
    const head: [*]const u8 = @ptrCast(param.?);
    const body_size = std.mem.readInt(u32, head[0..4], .little);
    if (body_size > 64 * 1024) return;
    pod.forEachProp(head[0 .. 8 + @as(usize, body_size)], f, visitFormat);
    var meta_buf: [96]u8 align(8) = undefined;
    if (pod.buildCropMetaPod(&meta_buf)) |meta| {
        const params = [_][*]const u8{meta.ptr};
        _ = pw.api.stream_update_params(stream, &params, 1);
    }
}

/// state_changed's common part: log the change; true when the stream
/// failed (the warning names `who`).
pub fn onState(comptime who: []const u8, old: c_int, new: c_int, msg: ?[*:0]const u8) bool {
    std.log.debug("pw state {d} -> {d}", .{ old, new });
    if (new != abi.PW_STREAM_STATE_ERROR) return false;
    std.log.warn(who ++ "pipewire stream error: {s}", .{if (msg) |m| std.mem.span(m) else "?"});
    return true;
}

/// A buffer's first data block as mapped: where it is and how much of it
/// may be read.
pub const Chunk = struct {
    base: [*]const u8,
    offset: usize,
    /// end of the readable bytes: never past the mapping or the chunk
    avail: usize,
    /// bytes per row as the producer reported them; 0 when unknown
    stride: usize,
};

/// The buffer's data, or null to skip it (no data, empty, corrupted,
/// unmapped).
pub fn chunkOf(sb: *const abi.SpaBuffer) ?Chunk {
    if (sb.n_datas < 1) return null;
    const d = sb.datas.?[0];
    const chunk = d.chunk orelse return null;
    // an empty or corrupted buffer is skipped; the next one will do
    if (chunk.size == 0 or (chunk.flags & abi.SPA_CHUNK_FLAG_CORRUPTED) != 0) {
        std.log.debug("pw: skipping empty/corrupted buffer", .{});
        return null;
    }
    const base: [*]const u8 = @ptrCast(d.data orelse return null);
    return .{
        .base = base,
        .offset = chunk.offset,
        .avail = @min(@as(usize, d.maxsize), @as(usize, chunk.offset) + chunk.size),
        .stride = if (chunk.stride > 0) @intCast(chunk.stride) else 0,
    };
}

/// The valid area of a buffer: its VideoCrop region when the producer
/// attached a sensible one, else the whole negotiated frame.
pub fn cropRegion(sb: *const abi.SpaBuffer, width: u32, height: u32) SpaMetaRegion {
    const full = SpaMetaRegion{ .x = 0, .y = 0, .width = width, .height = height };
    const metas = sb.metas orelse return full;
    for (metas[0..sb.n_metas]) |m| {
        if (m.type != abi.SPA_META_VideoCrop or m.size < @sizeOf(SpaMetaRegion)) continue;
        const r: *const SpaMetaRegion = @ptrCast(@alignCast(m.data orelse continue));
        if (r.width == 0 or r.height == 0 or r.x < 0 or r.y < 0) return full;
        const x: u32 = @intCast(r.x);
        const y: u32 = @intCast(r.y);
        if (x >= width or y >= height or r.width > width - x or r.height > height - y) return full;
        return r.*;
    }
    return full;
}

/// Where a buffer's valid area sits in its mapped memory.
pub const Source = struct {
    base: [*]const u8,
    /// byte offset of the crop's first pixel
    first: usize,
    stride: usize,
    crop: SpaMetaRegion,

    /// The first pixel of the valid area.
    pub fn start(self: Source) [*]const u8 {
        return self.base + self.first;
    }
};

/// Locate the valid area of a 4-byte-per-pixel video buffer of the
/// negotiated `width` x `height`, or null to skip the buffer (empty,
/// corrupted, unmapped, no format yet, or smaller than the frame it
/// claims to hold).
pub fn validArea(sb: *const abi.SpaBuffer, width: u32, height: u32) ?Source {
    const c = chunkOf(sb) orelse return null;
    if (width == 0 or height == 0) return null;
    const stride: usize = if (c.stride > 0) c.stride else @as(usize, width) * 4;
    if (stride < @as(usize, width) * 4) return null;
    const crop = cropRegion(sb, width, height);
    const first = c.offset + @as(usize, @intCast(crop.y)) * stride + @as(usize, @intCast(crop.x)) * 4;
    const needed = first + (@as(usize, crop.height) - 1) * stride + @as(usize, crop.width) * 4;
    if (needed > c.avail) {
        std.log.debug("pw: buffer smaller than the frame ({d} < {d}); skipping", .{ c.avail, needed });
        return null;
    }
    return .{ .base = c.base, .first = first, .stride = stride, .crop = crop };
}

// --- tests

const TestBuf = struct {
    mem: [4096]u8 align(8) = @splat(0),
    chunk: abi.SpaChunk = .{ .offset = 0, .size = 4096, .stride = 0, .flags = 0 },
    data: [1]abi.SpaData = undefined,
    region: SpaMetaRegion = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    metas: [1]abi.SpaMeta = undefined,
    sb: abi.SpaBuffer = undefined,

    fn init(self: *TestBuf, maxsize: u32, with_crop: bool) *const abi.SpaBuffer {
        self.data = .{.{ .type = 0, .flags = 0, .fd = -1, .mapoffset = 0, .maxsize = maxsize, .data = &self.mem, .chunk = &self.chunk }};
        self.metas = .{.{ .type = abi.SPA_META_VideoCrop, .size = @sizeOf(SpaMetaRegion), .data = &self.region }};
        self.sb = .{ .n_metas = if (with_crop) 1 else 0, .n_datas = 1, .metas = &self.metas, .datas = &self.data };
        return &self.sb;
    }
};

test "validArea: the whole frame, with the producer's stride" {
    var t: TestBuf = .{};
    t.chunk = .{ .offset = 16, .size = 4000, .stride = 64, .flags = 0 };
    const src = validArea(t.init(4096, false), 10, 8).?;
    try std.testing.expectEqual(@as(usize, 64), src.stride);
    try std.testing.expectEqual(@as(usize, 16), src.first);
    try std.testing.expectEqual(@as(u32, 10), src.crop.width);
    try std.testing.expectEqual(@as(u32, 8), src.crop.height);
    try std.testing.expectEqual(@as([*]const u8, @ptrCast(&t.mem)) + 16, src.start());
}

test "validArea: a crop region moves the first pixel" {
    var t: TestBuf = .{};
    t.chunk.stride = 40;
    t.region = .{ .x = 2, .y = 3, .width = 4, .height = 5 };
    const src = validArea(t.init(4096, true), 10, 10).?;
    try std.testing.expectEqual(@as(usize, 3 * 40 + 2 * 4), src.first);
    try std.testing.expectEqual(@as(u32, 4), src.crop.width);
}

test "validArea: skips buffers it cannot read" {
    var t: TestBuf = .{};
    // no format yet
    try std.testing.expect(validArea(t.init(4096, false), 0, 10) == null);
    // stride smaller than a row
    t.chunk.stride = 8;
    try std.testing.expect(validArea(t.init(4096, false), 10, 10) == null);
    // implicit stride, but the mapping is too small for the frame
    t.chunk.stride = 0;
    try std.testing.expect(validArea(t.init(10 * 4 * 10 - 1, false), 10, 10) == null);
    try std.testing.expect(validArea(t.init(10 * 4 * 10, false), 10, 10) != null);
    // the chunk is smaller than the mapping
    t.chunk.size = 100;
    try std.testing.expect(validArea(t.init(4096, false), 10, 10) == null);
    // empty and corrupted chunks
    t.chunk = .{ .offset = 0, .size = 0, .stride = 0, .flags = 0 };
    try std.testing.expect(validArea(t.init(4096, false), 1, 1) == null);
    t.chunk = .{ .offset = 0, .size = 4096, .stride = 0, .flags = abi.SPA_CHUNK_FLAG_CORRUPTED };
    try std.testing.expect(validArea(t.init(4096, false), 1, 1) == null);
    // unmapped
    t.chunk.flags = 0;
    const sb = t.init(4096, false);
    t.data[0].data = null;
    try std.testing.expect(validArea(sb, 1, 1) == null);
}

test "crop region validation" {
    var region = SpaMetaRegion{ .x = 10, .y = 20, .width = 100, .height = 50 };
    var metas = [_]abi.SpaMeta{.{ .type = abi.SPA_META_VideoCrop, .size = @sizeOf(SpaMetaRegion), .data = &region }};
    var sb = abi.SpaBuffer{ .n_metas = 1, .n_datas = 0, .metas = &metas, .datas = null };
    const r = cropRegion(&sb, 200, 100);
    try std.testing.expectEqual(@as(u32, 100), r.width);
    try std.testing.expectEqual(@as(i32, 20), r.y);
    // out of bounds falls back to the full frame
    region.width = 300;
    try std.testing.expectEqual(@as(u32, 200), cropRegion(&sb, 200, 100).width);
}
