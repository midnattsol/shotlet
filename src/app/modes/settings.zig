//! What the capture-mode settings mean. The settings themselves are a
//! section of the one config (config.Modes, app/config/modes.zig: keys
//! after_fullscreen, timer_seconds, window_shadow, scroll_max_height,
//! scroll_auto), read with config.load and written with config.save.

const std = @import("std");
const config = @import("../config.zig");

pub const After = config.After;
pub const Settings = config.Modes;

/// What a capture taken without the editor does: like an area copied or
/// saved in the editor, it always lands somewhere (the clipboard or a
/// file), and in the history; the thumbnail follows the `thumbnail`
/// setting unless it was asked for.
pub const Delivery = struct {
    save: bool = false,
    copy: bool = false,
    thumbnail: bool = false,
};

pub fn delivery(after: After, cfg: *const config.Config) Delivery {
    return switch (after) {
        .editor => .{},
        .thumbnail => .{ .copy = true, .thumbnail = true },
        .copy => .{ .copy = true, .thumbnail = cfg.showsThumbnail(false) },
        .save => .{ .save = true, .copy = cfg.copy_on_save, .thumbnail = cfg.showsThumbnail(true) },
    };
}

test "a capture without the editor is always copied or saved" {
    var cfg: config.Config = .{};
    cfg.thumbnail = .never;
    try std.testing.expectEqual(Delivery{ .copy = true, .thumbnail = true }, delivery(.thumbnail, &cfg));
    try std.testing.expectEqual(Delivery{ .copy = true }, delivery(.copy, &cfg));
    try std.testing.expectEqual(Delivery{ .save = true }, delivery(.save, &cfg));
    cfg.thumbnail = .after_save;
    cfg.copy_on_save = true;
    try std.testing.expectEqual(Delivery{ .save = true, .copy = true, .thumbnail = true }, delivery(.save, &cfg));
    try std.testing.expectEqual(After.editor, After.save.next());
}

test "mode settings read with defaults for the rest" {
    var cfg: config.Config = .{};
    _ = @import("../config/parse.zig").applyText(&cfg, "notify=true\nafter_fullscreen=copy\ntimer_seconds=10\nwindow_shadow=false\n# x\nscroll_max_height=5\n");
    const s = cfg.modes;
    try std.testing.expectEqual(After.copy, s.after);
    try std.testing.expectEqual(@as(u8, 10), s.timer_s);
    try std.testing.expect(!s.window_shadow and s.scroll_auto);
    try std.testing.expectEqual(@as(u32, 1000), s.scroll_max_height);
    var bad: config.Config = .{};
    _ = @import("../config/parse.zig").applyText(&bad, "after_fullscreen=nope\ntimer_seconds=7\n");
    try std.testing.expectEqual(After.thumbnail, bad.modes.after);
    try std.testing.expectEqual(@as(u8, 5), bad.modes.timer_s);
}
