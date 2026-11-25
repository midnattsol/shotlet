//! One-time things already done ("this hint was shown"): an empty file
//! per flag in $XDG_STATE_HOME/shotlet (statefile.zig), so they survive
//! a config file reset and never race the settings writers.

const std = @import("std");
const log = std.log.scoped(.state);
const statefile = @import("statefile.zig");

pub const Flag = enum {
    /// the editor's first-run hint
    editor_hint,
    /// the magnifier's "Hold Ctrl to zoom" hint (ui/editor_ui/loupe_hint.zig)
    zoom_hint,

    fn fileName(self: Flag) []const u8 {
        return switch (self) {
            .editor_hint => "editor-hint-shown",
            .zoom_hint => "zoom-hint-shown",
        };
    }
};

/// The flag was set.
pub fn isSet(home: []const u8, f: Flag) bool {
    var b: [1]u8 = undefined;
    _ = statefile.readBuf(home, .state, f.fileName(), &b) catch |err| return err != error.NotFound;
    return true;
}

/// Set the flag, for good.
pub fn set(home: []const u8, f: Flag) void {
    statefile.write(home, .state, f.fileName(), "") catch |err|
        log.warn("could not remember {t}: {t}", .{ f, err });
}

test "a flag is unset until it is set" {
    var tmp = try @import("../testutil.zig").TmpDir.home();
    defer tmp.deinit();
    const home = tmp.path;
    try std.testing.expect(!isSet(home, .zoom_hint));
    set(home, .zoom_hint);
    try std.testing.expect(isSet(home, .zoom_hint));
    try std.testing.expect(!isSet(home, .editor_hint));
}
