//! Which permission-store entries are Shotlet's: those of its app id. An
//! entry of other apps, or with an empty app id (apps the portal could not
//! identify), is never Shotlet's.

const std = @import("std");
const permstore = @import("../../permstore.zig");
const app_id = @import("../../../../app_id.zig").app_id;

/// Shotlet's part of an entry: all of it, or its own permission in it.
pub const Pick = enum { whole, part };

/// Shotlet's part of an entry; null when it has none. `whole_ok`: the
/// table's entries may go as a whole (each screen-cast grant is its own
/// entry; the screenshot table's one entry is shared by every app).
pub fn pick(perms: []const permstore.AppPerms, whole_ok: bool) ?Pick {
    const ours = for (perms) |p| {
        if (std.mem.eql(u8, p.app, app_id)) break true;
    } else false;
    if (!ours) return null;
    return if (whole_ok and perms.len == 1) .whole else .part;
}

const testing = std.testing;

test "only Shotlet's app id is Shotlet's" {
    for ([_][]const u8{ "", "shotlet", "Shotlet", app_id ++ ".Other", "org.gnome.Other" }) |other| {
        try testing.expectEqual(@as(?Pick, null), pick(&.{.{ .app = other, .perms = &.{"yes"} }}, true));
    }
    try testing.expectEqual(@as(?Pick, null), pick(&.{}, true));
}

test "an entry goes whole only when it is all Shotlet's" {
    const own: permstore.AppPerms = .{ .app = app_id, .perms = &.{"yes"} };
    try testing.expectEqual(@as(?Pick, .whole), pick(&.{own}, true));
    // shared with an unidentified app: only Shotlet's permission goes
    try testing.expectEqual(@as(?Pick, .part), pick(&.{ .{ .app = "", .perms = &.{"yes"} }, own }, true));
    // the screenshot table's shared entry never goes whole
    try testing.expectEqual(@as(?Pick, .part), pick(&.{own}, false));
}
