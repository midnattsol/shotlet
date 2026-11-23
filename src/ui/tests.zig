//! The UI's test root (src/main.zig): its files and its folders' roots.

comptime {
    _ = @import("badge.zig");
    _ = @import("barkit.zig");
    _ = @import("caret.zig");
    _ = @import("dim.zig");
    _ = @import("doc.zig");
    _ = @import("drag.zig");
    _ = @import("editor.zig");
    _ = @import("editor_ui.zig");
    _ = @import("floatui.zig");
    _ = @import("floatwin.zig");
    _ = @import("focus.zig");
    _ = @import("frame.zig");
    _ = @import("hsv.zig");
    _ = @import("icons.zig");
    _ = @import("lens.zig");
    _ = @import("material.zig");
    _ = @import("menukit.zig");
    _ = @import("motion.zig");
    _ = @import("press.zig");
    _ = @import("rect_list.zig");
    _ = @import("region_pick.zig");
    _ = @import("scale.zig");
    _ = @import("script_input.zig");
    _ = @import("scroll_hud.zig");
    _ = @import("scroll_steps.zig");
    _ = @import("selchrome.zig");
    _ = @import("settings.zig");
    _ = @import("settings_modes.zig");
    _ = @import("settings_steps.zig");
    _ = @import("shapes.zig");
    _ = @import("tall_view.zig");
    _ = @import("textbox.zig");
    _ = @import("textedit.zig");
    _ = @import("theme.zig");
    _ = @import("view.zig");
    _ = @import("recui/tests.zig");
    _ = @import("tools/mod.zig");
}
