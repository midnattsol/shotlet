//! "Show in Files": the file manager (org.freedesktop.FileManager1, which
//! Nautilus, Dolphin, Nemo and others implement) opens the folder with
//! the file selected.

const std = @import("std");
const dbus = @import("../dbus.zig");
const uri_mod = @import("../../../uri.zig");

/// Ask the file manager to show `path`. Fire and forget: only a failure
/// to send is an error.
pub fn showItem(gpa: std.mem.Allocator, bus: *dbus.Connection, path: []const u8) !void {
    const uri = try uri_mod.fromFilePath(gpa, path);
    defer gpa.free(uri);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    const arr = try m.beginArray(4);
    try m.putString(uri);
    m.endArray(arr);
    try m.putString(""); // startup id
    _ = try bus.callMethod("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", "ass", m.buf.items);
}
