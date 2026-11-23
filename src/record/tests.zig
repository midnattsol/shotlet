//! The screen recorder's test root (src/main.zig): every file of the
//! folder.

comptime {
    _ = @import("timeline.zig");
    _ = @import("region.zig");
    _ = @import("audio.zig");
    _ = @import("frames.zig");
    _ = @import("strip.zig");
    _ = @import("engine.zig");
    _ = @import("settings.zig");
    _ = @import("keepvid.zig");
    _ = @import("ctlsock.zig");
    _ = @import("cli.zig");
    _ = @import("run.zig");
    _ = @import("files.zig");
    _ = @import("quickvid.zig");
    _ = @import("trim.zig");
}
