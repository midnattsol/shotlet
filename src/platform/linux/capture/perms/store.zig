//! Shotlet's entries in the portal permission store: the screen-cast
//! grants (table `screencast`, one entry per grant, keyed by its restore
//! token) and its "yes" in the Screenshot portal's entry (table
//! `screenshot`, id `screenshot`, shared by every app). Finding and
//! removing them.

const std = @import("std");
const dbus = @import("../../dbus.zig");
const permstore = @import("../../permstore.zig");
const select = @import("select.zig");
const app_id = @import("../../../../app_id.zig").app_id;

pub const Table = enum {
    screencast,
    screenshot,

    /// The table's entries are each one app's grant: they may go whole.
    fn wholeOk(t: Table) bool {
        return t == .screencast;
    }
};

/// One entry with Shotlet in it. Its id is a restore token for
/// screen casts: never printed.
pub const Entry = struct {
    table: Table,
    id: []const u8,
    pick: select.Pick,
};

/// Every entry of Shotlet's in both tables.
pub fn find(arena: std.mem.Allocator, bus: *dbus.Connection) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    try findIn(arena, bus, .screencast, try permstore.list(arena, bus, "screencast"), &out);
    try findIn(arena, bus, .screenshot, &.{"screenshot"}, &out);
    return out.items;
}

fn findIn(arena: std.mem.Allocator, bus: *dbus.Connection, table: Table, ids: []const []const u8, out: *std.ArrayList(Entry)) !void {
    for (ids) |id| {
        const perms = (try permstore.lookup(arena, bus, @tagName(table), id)) orelse continue;
        const p = select.pick(perms, table.wholeOk()) orelse continue;
        try out.append(arena, .{ .table = table, .id = id, .pick = p });
    }
}

/// Remove Shotlet's part of `e`: the whole entry when it is all
/// Shotlet's, else its own permission in it.
pub fn remove(bus: *dbus.Connection, e: Entry) !void {
    if (e.pick == .whole) return permstore.delete(bus, @tagName(e.table), e.id);
    try permstore.deletePermission(bus, @tagName(e.table), e.id, app_id);
}

/// How many of `entries` are in `table`.
pub fn count(entries: []const Entry, table: Table) usize {
    var n: usize = 0;
    for (entries) |e| n += @intFromBool(e.table == table);
    return n;
}

test "entries are counted per table" {
    const entries = [_]Entry{
        .{ .table = .screencast, .id = "a", .pick = .whole },
        .{ .table = .screencast, .id = "b", .pick = .part },
        .{ .table = .screenshot, .id = "screenshot", .pick = .part },
    };
    try std.testing.expectEqual(@as(usize, 2), count(&entries, .screencast));
    try std.testing.expectEqual(@as(usize, 1), count(&entries, .screenshot));
}
