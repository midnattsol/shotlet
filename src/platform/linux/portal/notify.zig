//! Desktop notifications (org.freedesktop.Notifications), fire-and-forget.

const std = @import("std");
const dbus = @import("../dbus.zig");
const app_id = @import("../../../app_id.zig").app_id;

/// Fire-and-forget desktop notification.
pub fn notify(alloc: std.mem.Allocator, bus: *dbus.Connection, summary: []const u8, text: []const u8) void {
    notifyInner(alloc, bus, summary, text) catch |err| {
        std.log.warn("notification failed: {t}", .{err});
    };
}

fn notifyInner(alloc: std.mem.Allocator, bus: *dbus.Connection, summary: []const u8, text: []const u8) !void {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString("Shotlet"); // app_name
    try m.putU32(0); // replaces_id
    try m.putString(app_id); // icon
    try m.putString(summary);
    try m.putString(text);
    const actions = try m.beginArray(4);
    m.endArray(actions);
    const hints = try m.beginDict();
    try hints.entry("desktop-entry", app_id); // GNOME groups and names it by this
    hints.end();
    try m.putI32(4000); // timeout ms

    var reply = try bus.call(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
        "susssasa{sv}i",
        m.buf.items,
        dbus.default_reply_timeout_ms,
    );
    reply.deinit(bus.alloc);
}
