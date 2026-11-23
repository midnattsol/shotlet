//! The drivers' `sni-watcher MS`: play org.kde.StatusNotifierWatcher on
//! the session bus until a tray item registers.

const std = @import("std");
const kit = @import("shotlet");
const dbus = kit.dbus;
const sys = kit.sys;

/// Own the watcher's name and answer "SENDER ITEM" (in `out`) for the
/// first RegisterStatusNotifierItem within `ms`.
pub fn watch(gpa: std.mem.Allocator, conn: *dbus.Connection, ms: u32, out: []u8) ![]const u8 {
    if (!try conn.requestName("org.kde.StatusNotifierWatcher")) return error.NameTaken;
    const deadline = sys.monoMs() + ms;
    while (try conn.nextMessageDeadline(deadline)) |msg_| {
        var msg = msg_;
        defer msg.deinit(gpa);
        if (!msg.isCall("org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem")) continue;
        try conn.replyTo(&msg, "", &.{});
        var r = msg.reader();
        const item = try r.readString();
        return std.fmt.bufPrint(out, "{s} {s}", .{ msg.sender orelse "?", item }) catch "?";
    }
    return error.NoRegistration;
}
