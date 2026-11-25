//! After Copy or Save: keep the capture (history entry, or a cache entry
//! for the floating thumbnail alone) and start the quick-access process.

const std = @import("std");
const log = std.log.scoped(.history);
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const annot = @import("annot.zig");
const png = @import("../gfx/png.zig");
const resample = @import("../gfx/resample.zig");
const sys = @import("../platform/api.zig").sys;
const shapes = @import("../ui/shapes.zig");
const doc_mod = @import("../ui/doc.zig");
const relaunch = @import("relaunch.zig");
const Env = env_mod.Env;

/// Thumbnails fit in this box (twice the 240x150 card, for HiDPI).
pub const thumb_w = 480;
pub const thumb_h = 300;

pub const Kept = struct {
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,
    id: history.Id,

    pub fn root(self: *const Kept) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

pub const What = struct {
    /// the exported PNG (what was copied or saved)
    image_png: []const u8,
    /// the unannotated capture and the document, to edit it again
    source: ?*const png.Image = null,
    doc: ?*const doc_mod.Document = null,
    beautify: doc_mod.Beautify = .{},
    /// where Save wrote it
    saved: []const u8 = "",
    /// replace this entry (a capture edited again) instead of adding one
    replace: ?Kept = null,
    /// where the capture's centre was on the desktop (logical pixels)
    at: ?[2]i32 = null,
};

/// Where entries go: the history when it is on, else the cache.
pub fn rootFor(cfg: *const config.Config, env: Env, buf: []u8) ![]u8 {
    return if (cfg.history) history.historyRoot(buf, env.home) else history.cacheRoot(buf, env.home);
}

/// Store a capture. Null (logged) when nothing was stored.
pub fn keep(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, what: What) ?Kept {
    const k = keepEntry(gpa, env, cfg, what) orelse return null;
    finishEntry(gpa, cfg, &k, what);
    return k;
}

/// The part of keep() a thumbnail needs: the image, its thumbnail, the
/// meta and the annotations. finishEntry() adds the rest.
pub fn keepEntry(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, what: What) ?Kept {
    return keepInner(gpa, env, cfg, what) catch |err| {
        log.warn("could not keep the capture: {t}", .{err});
        return null;
    };
}

/// The slower rest of an entry keepEntry() stored: the unannotated
/// source to edit it again, then the history's limits.
pub fn finishEntry(gpa: std.mem.Allocator, cfg: *const config.Config, k: *const Kept, what: What) void {
    if (what.source != null and what.doc != null) {
        const src = encodeCrop(gpa, what.source.?, sourceCrop(what.doc.?)) catch |err| {
            log.warn("could not keep the capture's source: {t}", .{err});
            return;
        };
        defer gpa.free(src);
        history.replaceFile(k.root(), k.id.slice(), "source.png", src) catch |err|
            log.warn("could not keep the capture's source: {t}", .{err});
    }
    prune(gpa, cfg, k.root());
}

/// Whether anything is kept at all: the history, or the thumbnail.
pub fn wanted(cfg: *const config.Config) bool {
    return cfg.history or cfg.thumbnails();
}

/// The history's limits, after an entry was added.
pub fn prune(gpa: std.mem.Allocator, cfg: *const config.Config, root: []const u8) void {
    if (!cfg.history) return;
    _ = history.prune(gpa, root, cfg.history_max, @as(u64, cfg.history_max_mb) * 1024 * 1024) catch 0;
}

/// A new entry: its picture as a PNG and as pixels (for the thumbnail).
pub const NewEntry = struct {
    meta: history.Meta,
    image_png: []const u8,
    pixels: []const u32,
    width: u32,
    height: u32,
    doc: ?[]const u8 = null,
    extras: []const history.NewEntry.Extra = &.{},
};

/// Store a new entry where entries go (rootFor), with its thumbnail;
/// it appears all at once, extras included.
pub fn store(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, e: NewEntry) !Kept {
    var k: Kept = .{ .id = undefined };
    k.root_len = (try rootFor(cfg, env, &k.root_buf)).len;
    const thumb = try thumbPng(gpa, e.pixels, e.width, e.height);
    defer gpa.free(thumb);
    k.id = try history.create(gpa, k.root(), .{ .meta = e.meta, .image_png = e.image_png, .thumb_png = thumb, .doc = e.doc, .extras = e.extras });
    return k;
}

/// The thumbnail of a picture, as a PNG (owned).
fn thumbPng(gpa: std.mem.Allocator, pixels: []const u32, w: u32, h: u32) ![]u8 {
    const t = try thumbnail(gpa, pixels, w, h, thumb_w, thumb_h);
    defer gpa.free(t.pixels);
    return png.encodeWith(gpa, t.pixels, t.width, t.height, .{ .alpha = .auto });
}

fn keepInner(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, what: What) !?Kept {
    if (!wanted(cfg)) return null;
    var img = try png.decode(gpa, what.image_png);
    defer img.deinit(gpa);
    const doc_text: ?[]u8 = if (what.source != null and what.doc != null)
        try docRelativeTo(gpa, what.doc.?, sourceCrop(what.doc.?), what.beautify)
    else
        null;
    defer if (doc_text) |d| gpa.free(d);
    var meta: history.Meta = .{ .time_ms = sys.realtimeMs(), .width = img.width, .height = img.height, .saved = what.saved, .at = what.at };
    if (what.replace) |r| {
        try replaceEntry(gpa, &r, what.image_png, &img, doc_text, &meta);
        return r;
    }
    return try store(gpa, env, cfg, .{ .meta = meta, .image_png = what.image_png, .pixels = img.pixels, .width = img.width, .height = img.height, .doc = doc_text });
}

/// A capture edited again: its entry's files replaced.
fn replaceEntry(gpa: std.mem.Allocator, k: *const Kept, image_png: []const u8, img: *const png.Image, doc_text: ?[]const u8, meta: *history.Meta) !void {
    const id = k.id.slice();
    // edited again: it still came from where it was
    if (meta.at == null) meta.at = previousAt(gpa, k.root(), id);
    const thumb = try thumbPng(gpa, img.pixels, img.width, img.height);
    defer gpa.free(thumb);
    try history.replaceFile(k.root(), id, "image.png", image_png);
    try history.replaceFile(k.root(), id, "thumb.png", thumb);
    if (doc_text) |d| try history.replaceFile(k.root(), id, "doc", d);
    try history.writeMeta(gpa, k.root(), id, meta);
}

fn previousAt(gpa: std.mem.Allocator, root: []const u8, id: []const u8) ?[2]i32 {
    var old = history.readMeta(gpa, root, id) catch return null;
    defer old.deinit(gpa);
    return old.at;
}

/// `crop` of `src` as a PNG.
fn encodeCrop(gpa: std.mem.Allocator, src: *const png.Image, crop: shapes.Rect) ![]u8 {
    const cw: u32 = @intCast(crop.w);
    const ch: u32 = @intCast(crop.h);
    const px = try gpa.alloc(u32, @as(usize, cw) * ch);
    defer gpa.free(px);
    for (0..ch) |y| {
        const off = (@as(usize, @intCast(crop.y)) + y) * src.width + @as(usize, @intCast(crop.x));
        @memcpy(px[y * cw ..][0..cw], src.pixels[off..][0..cw]);
    }
    return png.encode(gpa, px, cw, ch);
}

/// The document as annot text, shapes relative to the cropped source.
fn docRelativeTo(gpa: std.mem.Allocator, d: *const doc_mod.Document, crop: shapes.Rect, beautify: doc_mod.Beautify) ![]u8 {
    var moved: std.ArrayList(shapes.Shape) = .empty;
    defer {
        for (moved.items) |*s| s.deinit(gpa);
        moved.deinit(gpa);
    }
    for (d.shapes.items) |*s| {
        var c = try s.clone(gpa);
        c.translate(-crop.x, -crop.y);
        moved.append(gpa, c) catch |err| {
            c.deinit(gpa);
            return err;
        };
    }
    var sel = d.exportRect();
    sel.x -= crop.x;
    sel.y -= crop.y;
    return annot.write(gpa, sel, beautify, moved.items);
}

/// The part of the capture kept for editing again: the selection plus
/// what blur and pixelate read around it.
pub fn sourceCrop(d: *const doc_mod.Document) shapes.Rect {
    var margin: i32 = 0;
    for (d.shapes.items) |*s| margin = @max(margin, s.readMargin());
    const sel = d.exportRect();
    return shapes.Rect.intersect(sel.expand(@min(margin, 256)), d.imageRect()) orelse d.imageRect();
}

pub const Pixels = struct { pixels: []u32, width: u32, height: u32 };

/// Scale down to fit max_w x max_h (never up), area-filtered.
pub fn thumbnail(gpa: std.mem.Allocator, src: []const u32, sw: u32, sh: u32, max_w: u32, max_h: u32) !Pixels {
    const fx = @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(@max(1, sw)));
    const fy = @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(@max(1, sh)));
    const f = @min(1.0, @min(fx, fy));
    const dw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sw)) * f))));
    const dh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sh)) * f))));
    const out = try gpa.alloc(u32, @as(usize, dw) * dh);
    errdefer gpa.free(out);
    try resample.scale(gpa, src, sw, sh, out, dw, dh);
    return .{ .pixels = out, .width = dw, .height = dh };
}

test "thumbnails fit the box and average colours" {
    const gpa = std.testing.allocator;
    var src: [8 * 4]u32 = undefined;
    @import("../testutil.zig").checker(&src, 8);
    const t = try thumbnail(gpa, &src, 8, 4, 4, 4);
    defer gpa.free(t.pixels);
    try std.testing.expectEqual(@as(u32, 4), t.width);
    try std.testing.expectEqual(@as(u32, 2), t.height);
    // black and white average to grey
    try std.testing.expectEqual(@as(u32, 0xFF808080), t.pixels[0]);
    // never scaled up
    const same = try thumbnail(gpa, &src, 8, 4, 100, 100);
    defer gpa.free(same.pixels);
    try std.testing.expectEqual(@as(u32, 8), same.width);
}
