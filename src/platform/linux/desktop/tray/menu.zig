//! The tray icon's menu, exported as com.canonical.dbusmenu at /MenuBar:
//! a flat list of items whose clicks become MenuActions.

const std = @import("std");
const dbus = @import("../../dbus.zig");
const MenuAction = @import("../tray.zig").MenuAction;

pub const path = "/MenuBar";
pub const iface = "com.canonical.dbusmenu";

pub const Item = struct { id: i32, label: []const u8, separator: bool };

pub const items = [_]Item{
    .{ .id = 1, .label = "Take screenshot", .separator = false },
    .{ .id = 6, .label = "Capture screen", .separator = false },
    .{ .id = 7, .label = "Capture window", .separator = false },
    .{ .id = 8, .label = "Scrolling capture", .separator = false },
    .{ .id = 9, .label = "Timer…", .separator = false },
    .{ .id = 10, .label = "Capture text", .separator = false },
    .{ .id = 20, .label = "Record screen / stop recording", .separator = false },
    .{ .id = 5, .label = "Recent captures…", .separator = false },
    .{ .id = 2, .label = "Settings", .separator = false },
    .{ .id = 3, .label = "", .separator = true },
    .{ .id = 4, .label = "Quit", .separator = false },
};

/// Answers one call on the menu object; returns the clicked item's action.
pub fn handle(alloc: std.mem.Allocator, bus: *dbus.Connection, msg: *const dbus.Message) !MenuAction {
    if (msg.isCall(iface, "GetLayout")) {
        try getLayout(alloc, bus, msg);
    } else if (msg.isCall(iface, "GetGroupProperties")) {
        try getGroupProperties(alloc, bus, msg);
    } else if (msg.isCall(iface, "AboutToShow")) {
        var m = dbus.Marshal.init(alloc);
        defer m.deinit();
        try m.putBool(false);
        try bus.replyTo(msg, "b", m.buf.items);
    } else if (msg.isCall(iface, "Event")) {
        return event(bus, msg);
    } else if (try dbus.Properties.reply(bus, msg, &prop_names, {}, putProperty)) {
        // answered
    } else {
        try bus.replyError(msg, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    }
    return .none;
}

/// An item's a{sv}: its label, or its separator type.
fn putItemProps(m: *dbus.Marshal, item: Item) !void {
    const props = try m.beginDict();
    if (item.separator) try props.entry("type", "separator") else try props.entry("label", item.label);
    props.end();
}

/// reply: (u(ia{sv}av)), the root and its items without nested children
fn getLayout(alloc: std.mem.Allocator, bus: *dbus.Connection, msg: *const dbus.Message) !void {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putU32(1); // revision
    try m.beginStruct();
    try m.putI32(0); // root id
    const root_props = try m.beginDict();
    try root_props.entry("children-display", "submenu");
    root_props.end();
    const children = try m.beginArray(1); // av: variants align 1
    for (items) |item| {
        try m.putSignature("(ia{sv}av)");
        try m.beginStruct();
        try m.putI32(item.id);
        try putItemProps(&m, item);
        const sub = try m.beginArray(1);
        m.endArray(sub); // no nested children
    }
    m.endArray(children);
    try bus.replyTo(msg, "u(ia{sv}av)", m.buf.items);
}

/// reply: a(ia{sv})
fn getGroupProperties(alloc: std.mem.Allocator, bus: *dbus.Connection, msg: *const dbus.Message) !void {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    const arr = try m.beginArray(8);
    for (items) |item| {
        try m.beginStruct();
        try m.putI32(item.id);
        try putItemProps(&m, item);
    }
    m.endArray(arr);
    try bus.replyTo(msg, "a(ia{sv})", m.buf.items);
}

fn event(bus: *dbus.Connection, msg: *const dbus.Message) !MenuAction {
    var r = msg.reader();
    const id = @as(i32, @bitCast(try r.readU32()));
    const event_type = try r.readString();
    try bus.replyTo(msg, "", &.{});
    if (!std.mem.eql(u8, event_type, "clicked")) return .none;
    return actionFor(id);
}

fn actionFor(id: i32) MenuAction {
    return switch (id) {
        1 => .capture,
        10 => .capture_text,
        20 => .record,
        5 => .history,
        2 => .settings,
        4 => .quit,
        6 => .capture_screen,
        7 => .capture_window,
        8 => .capture_scroll,
        9 => .capture_timer,
        else => .none,
    };
}

/// dbusmenu properties: Version (u) and Status (s)
const prop_names = [_][]const u8{ "Version", "Status" };

fn putProperty(_: void, m: *dbus.Marshal, prop: []const u8) anyerror!void {
    if (std.mem.eql(u8, prop, "Version")) try m.putVariantU32(3) else try m.putVariantString("normal");
}
