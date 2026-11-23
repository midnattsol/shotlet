//! The editor's floating "Glass" material: ui/material.zig drawn with the
//! editor's per-pane caches (a blurred backdrop and a shadow mask per
//! floating surface, rebuilt only when what lies behind it changes).

const std = @import("std");
const render = @import("../../gfx/render.zig");
const shapes_mod = @import("../shapes.zig");
const editor_mod = @import("../editor.zig");
const theme = @import("../theme.zig");
const material = @import("../material.zig");

const Canvas = render.Canvas;
const Editor = editor_mod.Editor;
const Rect = shapes_mod.Rect;

/// Per-pane caches of one floating surface: its blurred backdrop and its
/// shadow mask. Rebuilt only when what lies behind it (or its size) changes.
pub const Backdrop = struct {
    rect: Rect = Rect.empty,
    hash: u64 = 0,
    /// the material over the blurred backdrop, r.w x r.h
    px: []u32 = &.{},
    /// scratch: what lies behind, composed each frame to see if it changed
    src: []u32 = &.{},
    shadow: material.ShadowCache = .{},
    /// the pane's content generation when `src` was last composed
    gen: u64 = 0,

    pub fn release(self: *Backdrop, gpa: std.mem.Allocator) void {
        gpa.free(self.px);
        gpa.free(self.src);
        self.shadow.release(gpa);
        self.* = .{};
    }
};

pub const Slot = enum(u3) { bar, panel, popover, picker, help, notice, strip, loupe };
pub const n_slots = @typeInfo(Slot).@"enum".field_names.len;

pub const Snapshot = material.Snapshot;

/// What a floating surface with `sh` covers: itself plus its shadow.
pub fn shadowFootprint(self: *const Editor, r: Rect, sh: theme.Shadow) Rect {
    return material.shadowFootprint(r, sh, self.uf());
}

/// The pixels behind `r`, blurred and a little more saturated; cached
/// while they stay the same.
fn backdrop(self: *Editor, slot: Slot, r: Rect) ?[]const u32 {
    const bd = &self.pn().backdrops[@backingInt(slot)];
    const rad: i32 = @max(2, self.sc(theme.backdrop_blur));
    const src = Rect.intersect(r.expand(rad * 2), self.screenRect()) orelse return null;
    const need: usize = @intCast(r.w * r.h);
    // nothing behind changed since last time: no need to even look
    if (bd.gen == self.pn().gen and bd.hash != 0 and Rect.eql(bd.rect, r) and bd.px.len == need) return bd.px;
    bd.gen = self.pn().gen;
    const scratch = composeBehind(self, bd, src) orelse return null;
    const hash = behindHash(self, scratch, r, src);
    if (bd.hash == hash and bd.px.len == need and Rect.eql(bd.rect, r)) return bd.px;
    if (bd.px.len != need) {
        self.alloc.free(bd.px);
        bd.px = &.{};
        bd.px = self.alloc.alloc(u32, need) catch return null;
    }
    material.frost(self.alloc, scratch, src, r, rad, self.theme.material, bd.px) catch return null;
    bd.rect = r;
    bd.hash = hash;
    return bd.px;
}

/// Compose what lies behind `src` into the pane's scratch buffer (grown
/// as needed).
fn composeBehind(self: *Editor, bd: *Backdrop, src: Rect) ?[]u32 {
    const n: usize = @intCast(src.w * src.h);
    if (bd.src.len < n) {
        self.alloc.free(bd.src);
        bd.src = &.{};
        bd.src = self.alloc.alloc(u32, n) catch return null;
    }
    const scratch = bd.src[0..n];
    self.composeRegionTo(scratch, @intCast(src.w), .{ .x = src.x, .y = src.y }, src);
    return scratch;
}

/// Identifies a backdrop: the pixels behind, the geometry and the tint.
fn behindHash(self: *const Editor, scratch: []const u32, r: Rect, src: Rect) u64 {
    var hasher = std.hash.Wyhash.init(0x5107);
    hasher.update(std.mem.sliceAsBytes(scratch));
    hasher.update(std.mem.asBytes(&r));
    hasher.update(std.mem.asBytes(&src));
    hasher.update(std.mem.asBytes(&self.theme.material));
    return hasher.final();
}

/// A CSS-like box shadow around the rounded rect `r`, outside it only
/// (the material is translucent: no shadow shows through it); `alpha`
/// fades it.
pub fn drawShadow(self: *Editor, canvas: *Canvas, slot: Slot, r: Rect, radius: f64, sh: theme.Shadow, alpha: f64) void {
    const bd = &self.pn().backdrops[@backingInt(slot)];
    material.shadow(self.alloc, canvas, r, radius, sh, self.uf(), alpha, &bd.shadow);
}

/// The floating material: shadow, the tinted blurred backdrop clipped to
/// the rounded rect, and a hairline edge.
pub fn drawMaterial(self: *Editor, canvas: *Canvas, slot: Slot, r: Rect, radius: f64, sh: theme.Shadow) void {
    if (r.w <= 0 or r.h <= 0) return;
    const th = self.theme;
    drawShadow(self, canvas, slot, r, radius, sh, 1);
    if (backdrop(self, slot, r)) |bdp| {
        material.blitRoundRect(canvas, bdp, r, radius);
    } else canvas.fillRoundRectAA(r.x, r.y, r.w, r.h, radius, th.material);
    material.hairline(canvas, r, radius, material.hairlineColor(th, self.uf()));
}
