//! The Linux backend (docs/PLATFORM.md): Wayland windows, D-Bus and the
//! xdg-desktop-portal, PipeWire, GNOME Shell, KWin and wlroots. The core
//! reaches it only through src/platform/api.zig; runtime choices among
//! desktops happen in here.

pub const sys = @import("sys.zig");
pub const window = @import("window.zig");
pub const desktop = @import("desktop.zig");
pub const shell = @import("shell.zig");
pub const capture = @import("capture.zig");
pub const record = @import("record.zig");
pub const devtools = @import("devtools.zig").run;
pub const libs = @import("libs.zig");
pub const proc = @import("proc.zig");
pub const fonts = @import("fonts.zig");
/// Tesseract (portable code over api.libs; another backend may pick
/// another engine)
pub const ocr = @import("../../ocr/tesseract.zig");

// The backend's test root (src/main.zig): every module of the folder,
// each reaching its own.
comptime {
    _ = sys;
    _ = libs;
    _ = proc;
    _ = window;
    _ = desktop;
    _ = shell;
    _ = capture;
    _ = record;
    _ = fonts;
    _ = @import("dbus.zig");
    _ = @import("permstore.zig");
    _ = @import("portal.zig");
    _ = @import("portal_test.zig");
    _ = @import("pw.zig");
    _ = @import("gnome.zig");
    _ = @import("kde.zig");
    _ = @import("wayland.zig");
    _ = @import("keyboard.zig");
}

/// The Linux plumbing itself, for Linux-only tooling outside the core:
/// the end-to-end drivers (src/e2e_module.zig). The core never uses it.
pub const native = struct {
    pub const dbus = @import("dbus.zig");
    pub const pw = @import("pw.zig");
    pub const pwstream = @import("pwstream.zig");
    pub const wayland = @import("wayland.zig");
    pub const window = @import("window.zig");
    pub const sys = @import("sys.zig");
};
