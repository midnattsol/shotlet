//! The capture modes' test root (app/tests.zig).

comptime {
    _ = @import("mode.zig");
    _ = @import("settings.zig");
    _ = @import("geom.zig");
    _ = @import("last_area.zig");
    _ = @import("window_frame.zig");
    _ = @import("cli.zig");
}
