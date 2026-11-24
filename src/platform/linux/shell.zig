//! The shell integration seam on Linux: the Shotlet GNOME Shell
//! extension (gnome.zig). It captures without prompts, holds the global
//! shortcuts of the capture modes (its GSettings keys), keeps floating
//! windows above the others on mutter and places them.

const std = @import("std");
const dbus = @import("dbus.zig");
const gnome = @import("gnome.zig");
const gsettings = @import("gnome/gsettings.zig");
const proc = @import("proc.zig");
const sys = @import("sys.zig");
const gtk_accel = @import("gnome/gtk_accel.zig");
const mode_keys = @import("gnome/mode_keys.zig");
const shell1 = @import("gnome/shell1.zig");
const shellcap = @import("gnome/shellcap.zig");
const types = @import("../api/shell.zig");
const Env = @import("../../app/env.zig").Env;
const capture = @import("../../app/capture.zig");
const mode = @import("../../app/modes/mode.zig");
const Accel = @import("../../app/accel.zig").Accel;

pub const State = types.State;
pub const Words = types.Words;
pub const CaptureInfo = types.CaptureInfo;
pub const Handoff = types.Handoff;
pub const HandedCapture = types.HandedCapture;
pub const FrozenInput = types.FrozenInput;
pub const Cli = types.Cli;

/// How Settings names the integration (GNOME's) and the desktop's
/// shortcuts here.
pub fn words() Words {
    if (!gnome.isGnome()) return .{};
    return .{
        .title = "GNOME integration",
        .part = "Shell extension",
        .command = "shotlet gnome-integration",
        .system_key = "GNOME\u{2019}s screenshot key",
        .custom_shortcuts = "GNOME Settings \u{203A} Keyboard \u{203A} Custom Shortcuts",
    };
}

/// This desktop has an integration to offer (GNOME).
pub const applies = gnome.isGnome;

/// The integration runs.
pub fn active(bus: *dbus.Connection) bool {
    return gnome.extensionActive(bus);
}

/// applies() and active(), on a connection of its own.
pub fn activeNow(gpa: std.mem.Allocator, env: Env) bool {
    if (!gnome.isGnome()) return false;
    var bus = dbus.Connection.connectSession(gpa, env.session.bus) catch return false;
    defer bus.deinit();
    return gnome.integrationActive(&bus);
}

/// Where the integration stands, for Settings.
pub fn state(gpa: std.mem.Allocator, env: Env, bus_opt: ?*dbus.Connection) State {
    if (!gnome.isGnome()) return .unsupported;
    const bus = bus_opt orelse return .missing;
    return switch (gnome.installState(gpa, env, bus)) {
        .active => .active,
        // nothing to click: it loads at the next login
        .next_login => .installed,
        else => .missing,
    };
}

/// Install and enable it (moving shortcuts that run shotlet to it).
pub fn install(gpa: std.mem.Allocator, env: Env, bus: ?*dbus.Connection) State {
    return switch (gnome.install(gpa, env, bus, .yes)) {
        .active => .active,
        .installed_relogin => .installed,
        .failed => .failed,
    };
}

pub const captureInfo = gnome.captureInfo;

/// A line for Settings about the last install.
pub const note = gnome.note;

/// Ask it to take a capture in `req`'s mode (it starts another shotlet).
pub fn requestCapture(_: std.mem.Allocator, bus: *dbus.Connection, req: mode.Request) Handoff {
    return shell1.captureMode(bus, req);
}

/// Put our window titled `title` at x, y (logical); false when it cannot.
pub const place = shell1.place;

/// It refused this Shotlet at least once in this run: it answers only
/// the binary it would start itself, and this is another copy
/// (zig-out/bin/shotlet, say).
pub const refusedCaller = shell1.refused;

/// The installed binary it answers (and starts), when it is there: its
/// `shotlet-path`, else `shotlet` on the PATH (into `buf`); null when
/// unknown or missing.
pub fn servedExe(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, buf: []u8) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sd_buf: [1100]u8 = undefined;
    const configured: []const u8 = blk: {
        const sd = gnome.schemaDir(gpa, env, bus, &sd_buf) catch break :blk "";
        const v = gsettings.get(arena, env, sd, gnome.ext_schema_id, "shotlet-path") catch break :blk "";
        break :blk gsettings.parseString(arena, v) catch "";
    };
    const exe: []const u8 = if (std.mem.startsWith(u8, configured, "/")) configured else proc.which(buf, env.envp, "shotlet") orelse return null;
    if (sys.fileMode(exe) == null or exe.len > buf.len) return null;
    std.mem.copyForwards(u8, buf[0..exe.len], exe);
    return buf[0..exe.len];
}

/// The capture handed over as `id` is on screen in Shotlet (or never
/// will be): the shell takes its frozen frame away, and says what the
/// pointer and keyboard did while it was up.
pub const unfreeze = shell1.unfreeze;

/// The capture it handed over.
pub fn loadHanded(gpa: std.mem.Allocator, env: Env, args: HandedCapture) !capture.Capture {
    return shellcap.load(gpa, env.runtime_dir, args);
}

/// It runs and Shotlet was started by it: an install that waited for the
/// next login can finish.
pub const finishPendingSetup = gnome.finishPendingSetup;

/// `shotlet gnome-integration ...`.
pub const runCli = gnome.runCli;

// --- the capture modes' global shortcuts (its settings) ---

/// Where its settings are (into `buf`), when it runs; null otherwise.
pub fn shortcutStore(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, buf: []u8) ?[]const u8 {
    if (!gnome.integrationActive(bus)) return null;
    return gnome.schemaDir(gpa, env, bus, buf) catch null;
}

/// The first shortcut bound to `name` ("Ctrl+Print": GTK's notation in
/// the extension's settings, shown in the neutral one); null when none.
pub fn getShortcut(arena: std.mem.Allocator, env: Env, store: []const u8, name: []const u8) ?[]const u8 {
    var kbuf: [32]u8 = undefined;
    const v = gsettings.get(arena, env, store, gnome.ext_schema_id, mode_keys.settingsKey(&kbuf, name)) catch return null;
    const items = gsettings.parseStrv(arena, v) catch return null;
    if (items.len == 0) return null;
    const buf = arena.alloc(u8, 64) catch return items[0];
    return gtk_accel.display(buf, items[0]);
}

/// Bind `name` to `accel` (null: none), in GTK's notation.
pub fn setShortcut(gpa: std.mem.Allocator, env: Env, store: []const u8, name: []const u8, accel: ?Accel) !void {
    var gbuf: [64]u8 = undefined;
    const gtk: ?[]const u8 = if (accel) |a| gtk_accel.fromNeutral(a, &gbuf) orelse return error.BadShortcut else null;
    const value = if (gtk) |g| try gsettings.formatStrv(gpa, &.{g}) else try gpa.dupe(u8, "@as []");
    defer gpa.free(value);
    var kbuf: [32]u8 = undefined;
    try gsettings.set(gpa, env, store, gnome.ext_schema_id, mode_keys.settingsKey(&kbuf, name), value);
}

/// Its self-timer's seconds, kept with Shotlet's own.
pub fn setTimerSeconds(gpa: std.mem.Allocator, env: Env, store: []const u8, seconds: u32) !void {
    var buf: [16]u8 = undefined;
    try gsettings.set(gpa, env, store, gnome.ext_schema_id, "timer-seconds", try std.fmt.bufPrint(&buf, "{d}", .{seconds}));
}
