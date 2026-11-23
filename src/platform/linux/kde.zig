//! KDE: KWin's bus interfaces. ScreenShot2 for direct and window
//! capture (kde/screenshot2.zig) and its scripting interface for where
//! the windows are (kde/winrects.zig).

const dbus = @import("dbus.zig");

/// KWin's name on the session bus.
pub const bus_name = "org.kde.KWin";

/// KWin runs this session (it owns its bus name).
pub fn kwinRunning(bus: *dbus.Connection) bool {
    return bus.nameHasOwner(bus_name) catch false;
}

comptime {
    _ = @import("kde/screenshot2.zig");
    _ = @import("kde/winrects.zig");
}
