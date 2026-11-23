//! "Show in Files": the file manager (org.freedesktop.FileManager1, which
//! Nautilus, Dolphin, Nemo and others implement) opens the folder with
//! the file selected.

const std = @import("std");
const dbus = @import("../dbus.zig");
const uri_mod = @import("../../../uri.zig");

/// how long a file manager may take to answer (D-Bus activation starts
/// one that is not running; Nautilus answers in about a second then)
const answer_ms = 4000;

/// Ask the file manager to show `path`, and wait for its answer: an
/// error when none can (no file manager: error.ServiceUnknown), the call
/// failed, or nothing answered in time (error.Timeout).
pub fn showItem(gpa: std.mem.Allocator, bus: *dbus.Connection, path: []const u8) !void {
    const uri = try uri_mod.fromFilePath(gpa, path);
    defer gpa.free(uri);
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    const arr = try m.beginArray(4);
    try m.putString(uri);
    m.endArray(arr);
    try m.putString(""); // startup id
    var reply = try bus.call("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", "ass", m.buf.items, answer_ms);
    reply.deinit(bus.alloc);
}
