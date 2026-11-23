//! One output (monitor): its wl_output and zxdg_output_v1 objects, the
//! state they announce, and its logical rectangle in the compositor's desktop
//! space. The window (window/output.zig) and direct capture
//! (capture/direct.zig) both read monitors through this.

const std = @import("std");
const protocol = @import("protocol.zig");
const wl = @import("../wayland.zig");
const ArgReader = wl.ArgReader;
const Rect = @import("../../api/window.zig").Rect;

const wl_output = protocol.wl_output;
const zxdg_output_v1 = protocol.zxdg_output_v1;

/// The wl_output version spoken (v4: name and description).
pub const max_version = 4;

/// A wl_output the compositor announced, and what it said about itself.
pub const Output = struct {
    /// wl_output object id; 0 while not bound (an empty slot)
    id: u32 = 0,
    /// registry global name (stable identity of the output)
    global: u32 = 0,
    /// wl_output version bound (v1 sends no done event)
    version: u32 = 0,
    /// zxdg_output_v1; 0 without the manager
    xdg: u32 = 0,
    /// integer scale (wl_output.scale), at least 1
    scale: i32 = 1,
    /// wl_output.transform: 0 normal, odd values turn by 90 or 270
    transform: u32 = 0,
    geo_x: i32 = 0,
    geo_y: i32 = 0,
    /// current mode, in device pixels before the transform
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    /// xdg_output's logical rectangle; has_logical once it sent one
    lx: i32 = 0,
    ly: i32 = 0,
    lw: i32 = 0,
    lh: i32 = 0,
    has_logical: bool = false,
    name_buf: [64]u8 = @splat(0),
    name_len: u8 = 0,
    desc_buf: [128]u8 = @splat(0),
    desc_len: u8 = 0,
    /// a done event arrived (all the state above is known)
    done: bool = false,

    /// Not yet bound: call bind().
    pub fn ofGlobal(g: wl.Global) Output {
        return .{ .global = g.name, .version = @min(g.version, max_version) };
    }

    pub fn bind(self: *Output, conn: *wl.Connection, registry: u32) !void {
        self.id = try conn.bind(registry, self.global, "wl_output", self.version);
    }

    /// Ask the xdg_output manager `mgr` (0: none) for the logical
    /// rectangle, once.
    pub fn getXdg(self: *Output, conn: *wl.Connection, mgr: u32) !void {
        if (mgr == 0 or self.id == 0 or self.xdg != 0) return;
        self.xdg = conn.newId();
        try conn.request(mgr, protocol.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = self.xdg }, .{ .object = self.id } });
    }

    /// Let go of the objects (the output was unplugged); an empty slot.
    pub fn release(self: *Output, conn: *wl.Connection) void {
        if (self.xdg != 0) conn.request(self.xdg, zxdg_output_v1.destroy, &.{}) catch {};
        if (self.id != 0 and self.version >= 3) conn.request(self.id, wl_output.release, &.{}) catch {};
        self.* = .{};
    }

    pub fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn description(self: *const Output) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    /// A wl_output event; true on done. A v1 output has no done event:
    /// it counts as done from its geometry on.
    pub fn onOutput(self: *Output, opcode: u16, r: *ArgReader) ArgReader.Error!bool {
        switch (opcode) {
            wl_output.ev_geometry => {
                self.geo_x = try r.int();
                self.geo_y = try r.int();
                _ = try r.int(); // physical size
                _ = try r.int();
                _ = try r.int(); // subpixel
                _ = try r.string(); // make
                _ = try r.string(); // model
                self.transform = try r.uint() & 7;
                if (self.version < 2) self.done = true;
            },
            wl_output.ev_mode => {
                const flags = try r.uint();
                const w = try r.int();
                const h = try r.int();
                if (flags & wl_output.mode_current != 0) {
                    self.mode_w = w;
                    self.mode_h = h;
                }
            },
            wl_output.ev_scale => self.scale = @max(1, try r.int()),
            wl_output.ev_name => self.name_len = copyStr(&self.name_buf, try r.string()),
            wl_output.ev_description => self.desc_len = copyStr(&self.desc_buf, try r.string()),
            wl_output.ev_done => return self.complete(),
            else => {},
        }
        return false;
    }

    /// A zxdg_output_v1 event; true when it completes the state.
    pub fn onXdg(self: *Output, opcode: u16, r: *ArgReader) ArgReader.Error!bool {
        switch (opcode) {
            zxdg_output_v1.ev_logical_position => {
                self.lx = try r.int();
                self.ly = try r.int();
                self.has_logical = true;
            },
            zxdg_output_v1.ev_logical_size => {
                self.lw = try r.int();
                self.lh = try r.int();
                self.has_logical = true;
            },
            zxdg_output_v1.ev_name => if (self.name_len == 0) {
                self.name_len = copyStr(&self.name_buf, try r.string());
            },
            zxdg_output_v1.ev_done => return self.complete(),
            else => {},
        }
        return false;
    }

    fn complete(self: *Output) bool {
        self.done = true;
        return true;
    }

    /// Logical rectangle: xdg_output's when known, else derived from the
    /// geometry, the current mode turned by the transform, and the
    /// integer scale. w/h are 0 while the mode is unknown.
    pub fn logicalRect(self: *const Output) Rect {
        if (self.has_logical and self.lw > 0 and self.lh > 0)
            return .{ .x = self.lx, .y = self.ly, .w = self.lw, .h = self.lh };
        const sc = @max(1, self.scale);
        const turned = self.transform & 1 != 0;
        return .{
            .x = self.geo_x,
            .y = self.geo_y,
            .w = @divTrunc(if (turned) self.mode_h else self.mode_w, sc),
            .h = @divTrunc(if (turned) self.mode_w else self.mode_h, sc),
        };
    }
};

fn copyStr(dst: []u8, src: []const u8) u8 {
    const n = @min(dst.len, src.len, 255);
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

// --- tests: events as the compositor sends them ---

fn putU32(buf: []u8, pos: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], v, .little);
    pos.* += 4;
}

fn putStr(buf: []u8, pos: *usize, s: []const u8) void {
    putU32(buf, pos, @intCast(s.len + 1));
    @memcpy(buf[pos.*..][0..s.len], s);
    const padded = std.mem.alignForward(usize, s.len + 1, 4);
    @memset(buf[pos.* + s.len ..][0 .. padded - s.len], 0);
    pos.* += padded;
}

/// Feed a geometry event (at x, y with `transform`) and a current mode.
fn feedMonitor(st: *Output, x: i32, y: i32, transform: u32, mode_w: i32, mode_h: i32) !void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for ([_]i32{ x, y, 600, 340, 0 }) |v| putU32(&buf, &n, @bitCast(v));
    putStr(&buf, &n, "make");
    putStr(&buf, &n, "model");
    putU32(&buf, &n, transform);
    var r: ArgReader = .{ .data = buf[0..n] };
    _ = try st.onOutput(wl_output.ev_geometry, &r);
    n = 0;
    for ([_]u32{ wl_output.mode_current, @bitCast(mode_w), @bitCast(mode_h), 60000 }) |v| putU32(&buf, &n, v);
    r = .{ .data = buf[0..n] };
    _ = try st.onOutput(wl_output.ev_mode, &r);
}

test "a monitor turned by 90 degrees is as tall as its mode is wide" {
    var st: Output = .{ .version = 4 };
    try feedMonitor(&st, 1920, 0, 1, 1920, 1080); // WL_OUTPUT_TRANSFORM_90
    try std.testing.expectEqual(Rect{ .x = 1920, .y = 0, .w = 1080, .h = 1920 }, st.logicalRect());
    st.transform = 3; // 270
    try std.testing.expectEqual(@as(i32, 1080), st.logicalRect().w);
    st.transform = 2; // 180: not turned sideways
    try std.testing.expectEqual(Rect{ .x = 1920, .y = 0, .w = 1920, .h = 1080 }, st.logicalRect());
}

test "the integer scale divides the mode; xdg_output wins when known" {
    var st: Output = .{ .version = 4 };
    try feedMonitor(&st, 0, 0, 1, 3840, 2160);
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    putU32(&buf, &n, 2);
    var r: ArgReader = .{ .data = &buf };
    _ = try st.onOutput(wl_output.ev_scale, &r);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1080, .h = 1920 }, st.logicalRect());
    st.lx = 10;
    st.lw = 1440;
    st.lh = 2560;
    st.has_logical = true;
    try std.testing.expectEqual(Rect{ .x = 10, .y = 0, .w = 1440, .h = 2560 }, st.logicalRect());
}

test "a v1 output is done after its geometry; later ones on done" {
    var st: Output = .{ .version = 1 };
    try feedMonitor(&st, 0, 0, 0, 800, 600);
    try std.testing.expect(st.done);
    var st2: Output = .{ .version = 4 };
    try feedMonitor(&st2, 0, 0, 0, 800, 600);
    try std.testing.expect(!st2.done);
    var r: ArgReader = .{ .data = &.{} };
    try std.testing.expect(try st2.onOutput(wl_output.ev_done, &r));
    try std.testing.expect(st2.done);
}
