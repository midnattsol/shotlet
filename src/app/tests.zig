//! The app's test root (src/main.zig): its files and its folders' roots.

comptime {
    _ = @import("accel.zig");
    _ = @import("annot.zig");
    _ = @import("capture.zig");
    _ = @import("clock.zig");
    _ = @import("config.zig");
    _ = @import("deliver.zig");
    _ = @import("editor_prefs.zig");
    _ = @import("env.zig");
    _ = @import("filename.zig");
    _ = @import("history.zig");
    _ = @import("history_ui.zig");
    _ = @import("keep.zig");
    _ = @import("pin.zig");
    _ = @import("quick.zig");
    _ = @import("quick_ipc.zig");
    _ = @import("shot.zig");
    _ = @import("shot_args.zig");
    _ = @import("statefile.zig");
    _ = @import("stateflag.zig");
    _ = @import("modes/tests.zig");
    _ = @import("scroll/tests.zig");
}
