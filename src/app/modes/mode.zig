//! Capture modes: what a capture covers and how it starts.
//!
//!     shotlet [area]        select a region in the editor (the default)
//!     shotlet fullscreen    the monitor under the pointer
//!     shotlet screens       every monitor
//!     shotlet previous      the last selection again (per monitor layout)
//!     shotlet window        click a window: just that window
//!     shotlet scroll        a region scrolled and stitched into one image
//!     shotlet timer [S]     area after a 3, 5 or 10 s countdown
//!
//! Every mode takes `--delay S` (the self-timer). On GNOME with the
//! Shotlet extension each mode has its own shortcut there; elsewhere bind
//! the commands in the desktop's keyboard settings.

const std = @import("std");

pub const Mode = enum {
    area,
    fullscreen,
    screens,
    previous,
    window,
    scroll,

    pub fn parse(name: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, name);
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .area => "Capture area",
            .fullscreen => "Capture screen",
            .screens => "Capture all screens",
            .previous => "Capture previous area",
            .window => "Capture window",
            .scroll => "Scrolling capture",
        };
    }

    /// Captured and finished without the editor's region selection.
    pub fn instant(self: Mode) bool {
        return self == .fullscreen or self == .screens or self == .window;
    }
};

/// A global shortcut the shell integration holds: a mode, the
/// self-timer, or the last thumbnail again.
pub const Shortcut = struct {
    /// the word `shotlet gnome-integration shortcut WORD KEY` takes; the
    /// backend's name for it (api.shell.getShortcut, setShortcut)
    name: []const u8,
    label: []const u8,
    /// what the integration binds it to at first (app/accel.zig's
    /// notation); none of GNOME's own shortcuts uses these (Alt+Print is
    /// SysRq)
    default: []const u8,
};

pub const shortcuts = [_]Shortcut{
    .{ .name = "area", .label = "Capture area", .default = "Print" },
    .{ .name = "fullscreen", .label = "Capture screen", .default = "Ctrl+Print" },
    .{ .name = "screens", .label = "Capture all screens", .default = "Ctrl+Shift+Print" },
    .{ .name = "previous", .label = "Capture previous area", .default = "Shift+Super+Print" },
    .{ .name = "window", .label = "Capture window", .default = "Super+Print" },
    .{ .name = "scroll", .label = "Scrolling capture", .default = "Ctrl+Super+Print" },
    .{ .name = "timer", .label = "Self-timer", .default = "Ctrl+Shift+Super+Print" },
    .{ .name = "thumbnail", .label = "Last thumbnail again", .default = "Shift+Super+T" },
};

pub fn shortcutNamed(name: []const u8) ?Shortcut {
    for (shortcuts) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// The timer's choices, in seconds.
pub const timer_choices = [_]u8{ 3, 5, 10 };

/// The longest countdown `--delay` and `timer` take.
pub const max_delay_s = 60;

/// One capture to make.
pub const Request = struct {
    mode: Mode = .area,
    /// seconds of countdown before capturing
    delay_s: u8 = 0,
    /// the pointer, in the compositor's logical layout, when known (the
    /// GNOME extension says where it was)
    pointer: ?[2]i32 = null,
};

test "modes parse by name" {
    try std.testing.expectEqual(Mode.window, Mode.parse("window").?);
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse("settings"));
    try std.testing.expect(Mode.fullscreen.instant() and !Mode.area.instant());
}

test "every shortcut has its own default, in the neutral notation" {
    const accel = @import("../accel.zig");
    for (shortcuts, 0..) |s, i| {
        const a = accel.parse(s.default).?;
        for (shortcuts[i + 1 ..]) |o| try std.testing.expect(!a.eql(accel.parse(o.default).?));
    }
    try std.testing.expect(shortcutNamed("scroll") != null);
    try std.testing.expect(shortcutNamed("nope") == null);
}
