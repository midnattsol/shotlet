//! The desktop seam on Linux: the session bus (with the app's identity
//! for the portals), the appearance from the Settings portal, file
//! dialogs (FileChooser portal), notifications and "show in Files"
//! (org.freedesktop.FileManager1).

const std = @import("std");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const window = @import("window.zig");
const types = @import("../api/desktop.zig");
const appearance = @import("desktop/appearance.zig");
const save_dialog = @import("desktop/save_dialog.zig");
const filemanager = @import("desktop/filemanager.zig");
const Env = @import("../../app/env.zig").Env;

pub const Appearance = types.Appearance;
pub const SaveOptions = types.SaveOptions;
pub const Choice = types.Choice;

/// The connection to the desktop's services: the D-Bus session bus.
pub const Session = dbus.Connection;

/// A file dialog in progress, answered through pump().
pub const Dialog = portal.Request;

/// Where the session's services are, from the environment.
pub const Addresses = @import("desktop/session_env.zig").Addresses;
pub const addresses = @import("desktop/session_env.zig").addresses;

/// Connect to the session, telling the portals who we are.
pub fn connect(gpa: std.mem.Allocator, env: Env) !Session {
    return portal.connectApp(gpa, env.session.bus);
}

/// Connect without telling the portals who we are (identify() does):
/// for a quick question, or to ask the shell first.
pub fn connectBrief(gpa: std.mem.Allocator, env: Env) !Session {
    return dbus.Connection.connectSession(gpa, env.session.bus);
}

/// Tell the portals who we are, before any portal call on `bus`.
pub fn identify(gpa: std.mem.Allocator, bus: *Session) void {
    portal.registerApp(gpa, bus);
}

/// The appearance, waiting at most `timeout_ms` for the portal.
pub const readAppearance = appearance.read;

/// Subscribe to appearance changes (pump() folds them in).
pub fn watchAppearance(bus: *Session) !void {
    return appearance.watch(bus);
}

/// What the desktop sent since the last call, without waiting:
/// appearance changes fold into `look` (true when it changed), and the
/// answer to `dialog` is kept in it (Dialog.done()).
pub fn pump(bus: *Session, gpa: std.mem.Allocator, look: *Appearance, dialog: ?*Dialog) bool {
    const Pump = struct {
        gpa: std.mem.Allocator,
        look: *Appearance,
        dialog: ?*Dialog,
        changed: bool = false,

        fn take(self: *@This(), msg: *const dbus.Message) bool {
            if (appearance.applySignal(self.look, msg)) self.changed = true;
            const r = self.dialog orelse return false;
            return r.handle(self.gpa, msg) catch false;
        }
    };
    var p: Pump = .{ .gpa = gpa, .look = look, .dialog = dialog };
    bus.drain(16, &p, Pump.take);
    return p.changed;
}

/// Ask where to save a file (blocking); over `over` when given.
pub fn askSavePath(gpa: std.mem.Allocator, bus: *Session, opts: SaveOptions, over: ?*window.Window) !Choice {
    return save_dialog.askSavePath(gpa, bus, opts, over);
}

/// Start asking for a folder without blocking; pump() until done().
pub fn chooseFolder(gpa: std.mem.Allocator, bus: *Session, current: ?[]const u8) !Dialog {
    return portal.beginChooseFolder(gpa, bus, .{ .current_folder = current });
}

/// A finished dialog's answer.
pub fn dialogChoice(gpa: std.mem.Allocator, d: *const Dialog) Choice {
    if (d.outcome.? != .granted) return .cancelled;
    const p = portal.chosenPath(gpa, d) catch |err| {
        std.log.warn("file chooser: {t}", .{err});
        return .cancelled;
    };
    return .{ .chosen = p };
}

/// The tray icon's daemon (`shotlet daemon`): StatusNotifierItem.
pub const daemon = @import("desktop/daemon.zig").run;

/// The session's descriptor, to poll with others for what it sends.
pub fn pollFd(bus: *const Session) @import("sys.zig").fd_t {
    return bus.fd;
}

/// Whether the session already holds messages (poll would not wake).
pub fn hasPending(bus: *Session) bool {
    return bus.hasPending();
}

/// A notification (best effort).
pub fn notify(gpa: std.mem.Allocator, bus: *Session, summary: []const u8, text: []const u8) void {
    portal.notify(gpa, bus, summary, text);
}

/// Show `path` selected in the file manager.
pub fn revealFile(gpa: std.mem.Allocator, bus: *Session, path: []const u8) !void {
    return filemanager.showItem(gpa, bus, path);
}

comptime {
    _ = appearance;
    _ = save_dialog;
}
