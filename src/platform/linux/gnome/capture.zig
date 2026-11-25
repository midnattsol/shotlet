//! What the active extension (dev.shotlet.Shell1, shell1.zig) reports
//! about its capture shortcut, for `status` and Settings.

const std = @import("std");
const dbus = @import("../dbus.zig");
const shell1 = @import("shell1.zig");
const extension = @import("extension.zig");
const gtk_accel = @import("gtk_accel.zig");
const out = @import("../../../cli/out.zig").say;

/// How captures go, for `status` and the Settings window.
pub const CaptureInfo = @import("../../api/shell.zig").CaptureInfo;

pub fn captureInfo(_: std.mem.Allocator, bus: *dbus.Connection) CaptureInfo {
    var info: CaptureInfo = .{};
    if (!extension.extensionActive(bus)) return info;
    info.capture = true;
    for ([_][]const u8{ "Shortcuts", "BlockedShortcuts" }) |prop| {
        if (readShortcut(bus, prop, &info)) {
            info.blocked = std.mem.eql(u8, prop, "BlockedShortcuts");
            break;
        }
    }
    return info;
}

/// The first accelerator of the `prop` list into `info`, in the neutral
/// notation where it has one; false when there is none (or it cannot be
/// read).
fn readShortcut(bus: *dbus.Connection, prop: []const u8, info: *CaptureInfo) bool {
    var p = shell1.getProperty(bus, prop) catch return false;
    defer p.deinit(bus.alloc);
    var pr = p.reader();
    const acc = (readFirstOfStrvVariant(&pr) catch return false) orelse return false;
    var dbuf: [64]u8 = undefined;
    const shown = gtk_accel.display(&dbuf, acc);
    const n = @min(shown.len, info.shortcut_buf.len);
    @memcpy(info.shortcut_buf[0..n], shown[0..n]);
    info.shortcut_len = n;
    return true;
}

/// A variant holding `as`: its first string, if any.
fn readFirstOfStrvVariant(r: *dbus.Reader) !?[]const u8 {
    const sig = try r.readSignature();
    if (!std.mem.eql(u8, sig, "as")) return error.BadSignature;
    const len = try r.readU32();
    if (len == 0) return null;
    return try r.readString();
}

/// The capture shortcut, for the command line (stdout).
pub fn printShortcut(info: *const CaptureInfo) void {
    if (!info.capture) return;
    if (info.shortcut()) |k| {
        if (info.blocked) {
            out("Shortcut {s}: GNOME's own screenshot tool uses that key, so Shotlet leaves it alone.\n" ++
                "  Pick another: shotlet gnome-integration shortcut Shift+Super+S\n" ++
                "  (or free {s} in GNOME Settings \u{203A} Keyboard \u{203A} View and Customize Shortcuts \u{203A} Screenshots)\n", .{ k, k });
        } else out("Shortcut {s} captures without prompts.\n", .{k});
    } else out("No capture shortcut (shotlet gnome-integration shortcut KEY sets one).\n", .{});
}
