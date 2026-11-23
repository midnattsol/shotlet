//! org.freedesktop.DBus.Properties on objects we export (the tray icon
//! and its menu): Get and GetAll of read-only properties.

const std = @import("std");
const Connection = @import("connection.zig").Connection;
const Message = @import("message.zig").Message;
const Marshal = @import("marshal.zig").Marshal;

pub const iface = @import("connection.zig").properties_iface;

/// Answer `msg` when it is a Properties Get or GetAll on an object whose
/// read-only properties are `names`: `put(ctx, m, name)` writes one
/// property's variant. Get of a name not in `names` gets an
/// UnknownProperty error reply. False when `msg` is neither (the caller
/// answers it); the interface argument is not checked (one interface
/// per object).
pub fn reply(
    bus: *Connection,
    msg: *const Message,
    names: []const []const u8,
    ctx: anytype,
    comptime put: fn (@TypeOf(ctx), *Marshal, []const u8) anyerror!void,
) !bool {
    var m = Marshal.init(bus.alloc);
    defer m.deinit();
    if (msg.isCall(iface, "GetAll")) {
        const d = try m.beginDict();
        for (names) |name| {
            try m.beginStruct();
            try m.putString(name);
            try put(ctx, &m, name);
        }
        d.end();
        try bus.replyTo(msg, "a{sv}", m.buf.items);
        return true;
    }
    if (!msg.isCall(iface, "Get")) return false;
    var r = msg.reader();
    _ = try r.readString(); // interface
    const prop = try r.readString();
    for (names) |name| {
        if (!std.mem.eql(u8, name, prop)) continue;
        try put(ctx, &m, name);
        try bus.replyTo(msg, "v", m.buf.items);
        return true;
    }
    try bus.replyError(msg, "org.freedesktop.DBus.Error.UnknownProperty", "no such property");
    return true;
}
