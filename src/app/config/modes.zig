//! Settings of the capture modes (Config.modes; app/modes/settings.zig
//! decides what they mean):
//!
//!     after_fullscreen=thumbnail   editor | thumbnail | copy | save:
//!                                  what a screen, all-screens or window
//!                                  capture does once taken
//!     timer_seconds=5              the self-timer: 3, 5 or 10
//!     window_shadow=true           window captures get a soft shadow
//!     scroll_max_height=20000      scrolling captures stop there (px)
//!     scroll_auto=true             scroll for the person where possible

const std = @import("std");
const keys = @import("keys.zig");
const mode = @import("../modes/mode.zig");

pub const After = enum {
    editor,
    thumbnail,
    copy,
    save,

    pub fn label(self: After) []const u8 {
        return switch (self) {
            .editor => "Open the editor",
            .thumbnail => "Copy, show the thumbnail",
            .copy => "Copy to the clipboard",
            .save => "Save to the folder",
        };
    }

    /// The next choice, for the Settings button that cycles them.
    pub fn next(self: After) After {
        const n = @typeInfo(After).@"enum".field_names.len;
        return @fromBackingInt(@intCast((@as(usize, @backingInt(self)) + 1) % n));
    }
};

pub const Modes = struct {
    after: After = .thumbnail,
    timer_s: u8 = 5,
    window_shadow: bool = true,
    scroll_max_height: u32 = 20_000,
    scroll_auto: bool = true,
};

const timer_choices = blk: {
    var out: [mode.timer_choices.len]i64 = undefined;
    for (mode.timer_choices, 0..) |c, i| out[i] = c;
    break :blk out;
};

pub const table = [_]keys.Key{
    .{ .name = "after_fullscreen", .field = "after", .kind = .tag },
    .{ .name = "timer_seconds", .field = "timer_s", .kind = .{ .one_of = &timer_choices } },
    .{ .name = "window_shadow", .field = "window_shadow", .kind = .flag },
    .{ .name = "scroll_max_height", .field = "scroll_max_height", .kind = .{ .int = .{ .min = 1000, .max = 60_000 } } },
    .{ .name = "scroll_auto", .field = "scroll_auto", .kind = .flag },
};
