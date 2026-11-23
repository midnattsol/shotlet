//! The recorder windows' test root (src/main.zig): every file of the
//! folder.

comptime {
    _ = @import("vidcard.zig");
    _ = @import("trimui.zig");
    _ = @import("trim_draw.zig");
    _ = @import("settings_rec.zig");
    _ = @import("control.zig");
    _ = @import("control_draw.zig");
    _ = @import("picker.zig");
    _ = @import("picker_bar.zig");
}
