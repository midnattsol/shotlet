//! The window's outputs (monitors): a slot per wl_output (its state and
//! logical rectangle live in wayland/output.zig), the surfaces placed on
//! each, and unplugging.

const std = @import("std");
const log = std.log.scoped(.window);
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");
const scale = @import("scale.zig");

const Window = window.Window;
const Surface = surface.Surface;
const max_outputs = window.max_outputs;

/// A wl_output the compositor announced (wayland/output.zig).
pub const Output = wl.output.Output;

/// The known outputs; empty slots have id 0.
pub const Outputs = struct {
    list: [max_outputs]Output = @splat(.{}),

    pub fn slotOf(self: *const Outputs, obj: u32) ?usize {
        if (obj == 0) return null;
        for (self.list, 0..) |o, slot| if (o.id == obj) return slot;
        return null;
    }

    pub fn xdgSlotOf(self: *const Outputs, obj: u32) ?usize {
        if (obj == 0) return null;
        for (self.list, 0..) |o, slot| if (o.xdg == obj) return slot;
        return null;
    }

    /// The output a surface is fullscreen on: its assigned one, else the
    /// only output it entered.
    pub fn covering(self: *const Outputs, s: *const Surface) ?*const Output {
        var found: ?*const Output = null;
        for (&self.list, 0..) |*o, slot| {
            if (o.id == 0) continue;
            if (s.output != 0) {
                if (o.global == s.output) return o;
            } else if (s.entered & (@as(u32, 1) << @intCast(slot)) != 0) {
                if (found != null) return null;
                found = o;
            }
        }
        return found;
    }

    /// Slots of the known outputs, ordered left to right, top to bottom.
    pub fn sortedSlots(self: *const Outputs, buf: *[max_outputs]u8) []u8 {
        var n: usize = 0;
        for (self.list, 0..) |o, slot| if (o.id != 0) {
            buf[n] = @intCast(slot);
            n += 1;
        };
        const Ctx = struct {
            outs: []const Output,
            fn less(ctx: @This(), a: u8, b: u8) bool {
                const ra = ctx.outs[a].logicalRect();
                const rb = ctx.outs[b].logicalRect();
                return if (ra.x != rb.x) ra.x < rb.x else ra.y < rb.y;
            }
        };
        std.mem.sort(u8, buf[0..n], Ctx{ .outs = &self.list }, Ctx.less);
        return buf[0..n];
    }

    /// The output whose logical rectangle starts at x, y.
    pub fn atOrigin(self: *Outputs, x: i32, y: i32) ?*Output {
        for (&self.list) |*o| {
            if (o.id == 0) continue;
            const r = o.logicalRect();
            if (r.x == x and r.y == y) return o;
        }
        return null;
    }
};

/// Outputs currently known (empty slots filtered out by the caller via
/// `id != 0`).
pub fn outputList(w: *Window) []const Output {
    return &w.outputs.list;
}

/// Bind a wl_output global into a free slot.
pub fn add(w: *Window, g: wl.Global) !void {
    for (&w.outputs.list) |*o| {
        if (o.id != 0) continue;
        o.* = .ofGlobal(g);
        try o.bind(&w.conn, w.globals.registry);
        try o.getXdg(&w.conn, w.globals.xdg_output_manager);
        break;
    } else log.warn("more than {d} outputs; ignoring one", .{max_outputs});
}

/// Ask for every known output's xdg_output; whether any output is known.
pub fn ensureAllXdg(w: *Window) !bool {
    var any_output = false;
    for (&w.outputs.list) |*o| if (o.id != 0) {
        any_output = true;
        try o.getXdg(&w.conn, w.globals.xdg_output_manager);
    };
    return any_output;
}

/// The output global `name` went away (unplugged).
pub fn remove(w: *Window, name: u32) !void {
    for (&w.outputs.list, 0..) |*o, slot| {
        if (o.id == 0 or o.global != name) continue;
        try dropSurfacesOn(w, slot, name);
        o.release(&w.conn);
        for (0..w.n_surfaces) |i| try scale.updateIntScale(w, @intCast(i));
        try w.conn.flush();
        return;
    }
}

/// Forget the output in every surface's entered set and tear down the
/// surfaces fullscreened on it (never surface 0: the compositor moves
/// that one, and the classic API relies on it).
fn dropSurfacesOn(w: *Window, slot: usize, name: u32) !void {
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        s.entered &= ~(@as(u32, 1) << @intCast(slot));
        if (i != 0 and s.alive and s.output == name) {
            surface.destroy(w, @intCast(i));
            try w.queue.append(w.alloc, .{ .resize = .{ .w = 0, .h = 0, .surface = @intCast(i) } });
        }
    }
}

/// wl_output events.
pub fn handleOutput(w: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
    if (try w.outputs.list[slot].onOutput(opcode, r)) try changed(w, slot);
}

/// zxdg_output_v1 events.
pub fn handleXdgOutput(w: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
    if (try w.outputs.list[slot].onXdg(opcode, r)) try changed(w, slot);
}

/// An output's state is complete: refresh surfaces placed on it.
fn changed(w: *Window, slot: usize) !void {
    const o = &w.outputs.list[slot];
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        if (!s.alive) continue;
        if (s.output != 0 and s.output == o.global) setOutputRect(s, o);
        try scale.updateIntScale(w, @intCast(i));
    }
}

/// Record the output's logical rectangle on a surface placed on it.
pub fn setOutputRect(s: *Surface, o: *const Output) void {
    const r = o.logicalRect();
    s.x = r.x;
    s.y = r.y;
    s.out_w = @intCast(@max(0, r.w));
    s.out_h = @intCast(@max(0, r.h));
}
