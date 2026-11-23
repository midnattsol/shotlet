//! The second half of an install that has to wait for the next login: a
//! freshly copied extension only loads then, and pointing it at shotlet
//! and moving the shortcuts needs it running. Install records the
//! person's answer ($XDG_STATE_HOME/shotlet/gnome-setup-pending: "move"
//! or "keep"); the first shotlet the extension starts, or the tray
//! daemon once it is active, runs `gnome-integration install` with that
//! answer, once.

const std = @import("std");
const log = std.log.scoped(.gnome);
const statefile = @import("../../../app/statefile.zig");
const proc = @import("../proc.zig");
const Env = @import("../../../app/env.zig").Env;

const file_name = "gnome-setup-pending";

/// Remember to finish the install once the extension runs; `move`: the
/// shortcuts go to it (--move-shortcut), else they stay (--keep-shortcut).
pub fn record(home: []const u8, move: bool) void {
    statefile.write(home, .state, file_name, if (move) "move\n" else "keep\n") catch |err|
        log.warn("could not remember to finish the setup: {t}", .{err});
}

/// Nothing is pending any more (install ran by hand, or uninstall).
pub fn clear(home: []const u8) void {
    _ = statefile.remove(home, .state, file_name);
}

/// The recorded answer, taken: only the caller that removed the marker
/// gets it, so the setup runs once.
fn take(home: []const u8) ?bool {
    var buf: [16]u8 = undefined;
    const answer = statefile.readBuf(home, .state, file_name, &buf) catch return null;
    if (!statefile.remove(home, .state, file_name)) return null;
    return parseAnswer(answer);
}

fn parseAnswer(s: []const u8) ?bool {
    const a = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.eql(u8, a, "move")) return true;
    if (std.mem.eql(u8, a, "keep")) return false;
    return null;
}

/// The extension runs: finish a pending install in the background.
pub fn finish(env: Env) void {
    const move = take(env.home) orelse return;
    log.info("finishing the GNOME integration setup ({s} the shortcuts)", .{if (move) "moving" else "keeping"});
    proc.spawnSelf(env.envp, &.{ "gnome-integration", "install", if (move) "--move-shortcut" else "--keep-shortcut" }, null);
}

test "the recorded answer is read back, anything else is ignored" {
    try std.testing.expectEqual(@as(?bool, true), parseAnswer("move\n"));
    try std.testing.expectEqual(@as(?bool, false), parseAnswer("keep"));
    try std.testing.expectEqual(@as(?bool, null), parseAnswer("yes"));
    try std.testing.expectEqual(@as(?bool, null), parseAnswer(""));
}
