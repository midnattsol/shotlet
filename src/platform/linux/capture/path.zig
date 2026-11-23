//! How the last capture got its pixels ($XDG_STATE_HOME/shotlet/
//! capture-path), for Settings and `shotlet permissions`: the GNOME
//! integration, the compositor directly (capture/direct.zig), or a portal.

const std = @import("std");
const statefile = @import("../../../app/statefile.zig");

pub const Path = @import("../../api/capture.zig").Path;

const file_name = "capture-path";

pub fn remember(home: []const u8, path: Path) void {
    if (last(home) == path) return;
    statefile.write(home, .state, file_name, @tagName(path)) catch {};
}

/// How a capture through `p` went, for `shotlet permissions`.
pub fn text(p: Path) []const u8 {
    return switch (p) {
        .shell => "through the GNOME integration (no permission used)",
        .direct => "directly from the compositor (no permission used)",
        .portal => "through the screen-sharing portal (its permission)",
    };
}

pub fn last(home: []const u8) ?Path {
    var buf: [16]u8 = undefined;
    const tag = std.mem.trim(u8, statefile.readBuf(home, .state, file_name, &buf) catch return null, " \n");
    // written before the seam named the integration neutrally
    if (std.mem.eql(u8, tag, "gnome")) return .shell;
    return std.meta.stringToEnum(Path, tag);
}
