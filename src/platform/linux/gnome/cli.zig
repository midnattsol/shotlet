//! `shotlet gnome-integration status|install|uninstall|shortcut`.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const gsettings = @import("gsettings.zig");
const Env = @import("../../../app/env.zig").Env;
const extension = @import("extension.zig");
const capture = @import("capture.zig");
const custom = @import("custom.zig");
const screenshot_keys = @import("screenshot_keys.zig");
const setup = @import("setup.zig");
const install_state = @import("install_state.zig");
const gnome_keys = @import("mode_keys.zig");
const cli_out = @import("../../../cli/out.zig");
const Cli = @import("../../api/shell.zig").Cli;

const ext_schema_id = extension.ext_schema_id;
const out = cli_out.say;

pub fn runCli(gpa: std.mem.Allocator, env: Env, cmd: Cli) !void {
    var bus = try dbus.Connection.connectSession(gpa, env.session.bus);
    defer bus.deinit();
    switch (cmd) {
        .status => runStatus(gpa, env, &bus),
        .install => |how| runInstall(gpa, env, &bus, moveFor(how)),
        .uninstall => try runUninstall(gpa, env, &bus),
        .shortcut => |keys| try runShortcut(gpa, env, &bus, keys),
    }
}

/// What install does with the desktop's screenshot key.
fn moveFor(how: Cli.Install) setup.MoveShortcuts {
    return switch (how) {
        .ask => .ask,
        .move_shortcut => .yes,
        .keep_shortcut => .no,
    };
}

fn runInstall(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, move: setup.MoveShortcuts) void {
    switch (setup.install(gpa, env, bus, move)) {
        .active => out("GNOME integration is active: captures need no permission prompt.\n", .{}),
        .installed_relogin => out("Installed {s}. It loads at your next login (GNOME Shell only finds new\n" ++
            "extensions then). Shotlet finishes the setup with your answer the first time it\n" ++
            "runs through it; `shotlet gnome-integration install` after logging in does it at once.\n", .{extension.uuid}),
        .failed => cli_out.fail(.failure, "could not install the GNOME integration (see the messages above)", .{}),
    }
}

/// Give back what install took, reset the extension's settings, disable
/// it and remove its files.
fn runUninstall(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) !void {
    @import("pending_setup.zig").clear(env.home);
    restoreTakenShortcuts(gpa, env);
    var sd_buf: [1100]u8 = undefined;
    if (extension.schemaDir(gpa, env, bus, &sd_buf)) |sd| {
        for ([_][]const u8{ "capture-shortcut", "shotlet-path" }) |k| gsettings.reset(gpa, env, sd, ext_schema_id, k) catch {};
    } else |_| {}
    _ = extension.callBool(gpa, bus, "DisableExtension", 5000) catch false;
    var buf: [1024]u8 = undefined;
    const dir = try extension.extensionDir(&buf, env.home);
    sys.removeTree(dir);
    out("Removed {s}.\n", .{dir});
}

/// GNOME's screenshot shortcuts and the moved custom shortcuts go back.
fn restoreTakenShortcuts(gpa: std.mem.Allocator, env: Env) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    if (screenshot_keys.restoreKeys(arena_state.allocator(), env)) |n| {
        if (n > 0) out("Gave {d} of GNOME's screenshot shortcut(s) back.\n", .{n});
    } else |err| cli_out.warn("could not give GNOME's screenshot shortcuts back ({t}); see ~/.config/shotlet/gnome-moved-keys", .{err});
    if (custom.restoreShortcuts(arena_state.allocator(), env)) |n| {
        if (n > 0) out("Put {d} custom shortcut(s) running shotlet back.\n", .{n});
    } else |err| cli_out.warn("could not put the moved shortcuts back ({t}); see ~/.config/shotlet/gnome-moved-shortcuts", .{err});
}

/// Show or set the capture shortcut, or a capture mode's own key.
fn runShortcut(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, rest: []const []const u8) !void {
    var sd_buf: [1100]u8 = undefined;
    const sd = try extension.schemaDir(gpa, env, bus, &sd_buf);
    // a capture mode's own key (gnome/mode_keys.zig)
    if (rest.len > 0 and @import("../../../app/modes/mode.zig").shortcutNamed(rest[0]) != null)
        return gnome_keys.cli(gpa, env, sd, rest);
    if (rest.len > 0) try setCaptureShortcut(gpa, env, sd, rest);
    const info = capture.captureInfo(gpa, bus);
    if (!info.capture) {
        const cur = gsettings.get(gpa, env, sd, ext_schema_id, "capture-shortcut") catch "";
        defer if (cur.len > 0) gpa.free(cur);
        out("capture-shortcut: {s}(the GNOME integration is not active)\n", .{cur});
    } else capture.printShortcut(&info);
    if (rest.len == 0) {
        out("Capture modes (shotlet gnome-integration shortcut MODE KEY):\n", .{});
        try gnome_keys.list(gpa, env, sd, null);
    }
}

/// Bind the extension's shortcut to `accels` (either notation; "none"
/// unbinds it), then give it a moment to pick that up.
fn setCaptureShortcut(gpa: std.mem.Allocator, env: Env, sd: []const u8, accels: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try gsettings.set(arena, env, sd, ext_schema_id, "capture-shortcut", try gnome_keys.userStrv(arena, accels));
    sys.sleepMs(200);
}

fn runStatus(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection) void {
    out("desktop: {s}\nextension {s}: {s}\n", .{
        if (extension.isGnome()) "GNOME" else "not GNOME",
        extension.uuid,
        install_state.read(gpa, env, bus).text(),
    });
    const info = capture.captureInfo(gpa, bus);
    out("capture: {s}\n", .{if (info.capture) "through the GNOME integration (no prompts)" else "through the screen-sharing portal"});
    capture.printShortcut(&info);
}

test "install's choice about the screenshot key reaches setup" {
    try std.testing.expectEqual(setup.MoveShortcuts.ask, moveFor(.ask));
    try std.testing.expectEqual(setup.MoveShortcuts.yes, moveFor(.move_shortcut));
    try std.testing.expectEqual(setup.MoveShortcuts.no, moveFor(.keep_shortcut));
}
