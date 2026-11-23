//! xdg-foreign (zxdg_exporter_v2, or v1): a handle to the window's
//! toplevel that another client can parent its dialog to, such as the
//! portal's file chooser ("wayland:HANDLE" as its parent_window).

const std = @import("std");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const events = @import("events.zig");

const Window = window.Window;

const exporter = wl.zxdg_exporter_v2;
const exported = wl.zxdg_exported_v2;

/// Export surface 0's toplevel; "wayland:HANDLE" in `buf`. It stays
/// exported until unexport() (or another export).
pub fn parentHandle(w: *Window, buf: []u8) ![]const u8 {
    const s = &w.surfaces[0];
    if (w.globals.exporter == 0) return error.Unsupported;
    if (!s.alive or s.toplevel == 0) return error.NoToplevel;
    unexport(w);
    const c = &w.conn;
    const id = c.newId();
    try c.request(w.globals.exporter, exporter.export_toplevel, &.{ .{ .new_id = id }, .{ .object = s.wl_surface } });
    w.exported = id;
    var wait: Wait = .{ .w = w, .id = id, .buf = buf };
    try c.roundtrip(&wait, Wait.onEvent);
    return wait.handle orelse error.NoHandle;
}

/// The roundtrip that brings the exported object's handle.
const Wait = struct {
    w: *Window,
    id: u32,
    buf: []u8,
    handle: ?[]const u8 = null,

    fn onEvent(self: *Wait, ev: wl.Event) !void {
        if (ev.object != self.id or ev.opcode != exported.ev_handle) return events.handleEvent(self.w, ev);
        var r = ev.reader();
        self.handle = try std.fmt.bufPrint(self.buf, "wayland:{s}", .{try r.string()});
    }
};

/// Withdraw the handle parentHandle() gave out.
pub fn unexport(w: *Window) void {
    if (w.exported == 0) return;
    w.conn.request(w.exported, exported.destroy, &.{}) catch {};
    w.exported = 0;
    w.conn.flush() catch {};
}
