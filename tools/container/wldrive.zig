//! shotlet-wldrive: virtual keyboard, pointer and screenshots for the
//! container e2e suite (tools/container/run.sh), on wlroots compositors
//! (sway, labwc) and on KWin. The counterpart of tools/e2e/drive.zig,
//! which does the same through Mutter's RemoteDesktop API on GNOME; both
//! answer the drivers' commands (tools/drivers/common/commands.zig) one
//! per line. `monitors` answers "NAME:X,Y,WxH@SCALE ..." in the logical
//! layout, numbered left to right; `find` and `shot` work in the
//! monitor's buffer pixels; `keysym`, `film` and `cut` are Mutter's only.
//!
//! - wlroots: zwlr_virtual_pointer_v1 + zwp_virtual_keyboard_v1 for input
//!   (the keymap file in WLDRIVE_KEYMAP), zwlr_screencopy_v1 for pictures
//!   of an output.
//! - KWin: org_kde_kwin_fake_input for input and org.kde.KWin.ScreenShot2
//!   over D-Bus for pictures. Both are restricted, and KWin grants them as
//!   on a real desktop, through the desktop entry whose Exec is this
//!   binary (shotlet-wldrive.desktop, written by tools/container/inner.sh:
//!   X-KDE-Wayland-Interfaces and X-KDE-DBUS-Restricted-Interfaces); no
//!   KWIN_*_NO_PERMISSION_CHECKS.
//!
//! Refuses to run outside the e2e sandbox (sandbox.zig), so it can never
//! type into a real desktop by accident.

const std = @import("std");
const kit = @import("shotlet");
const wl = kit.wayland;
const dbus = kit.dbus;
const sys = kit.sys;
const common = @import("driver_common");
const loop = common.loop;
const proto = @import("wldrive/proto.zig");
const Driver = @import("wldrive/Driver.zig");

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const gpa = gpa_state.allocator();
    const vars = init.environ_map;
    common.sandbox.require(vars, "shotlet-wldrive", &.{.container});
    const runtime = vars.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    const display = vars.get("WAYLAND_DISPLAY") orelse "wayland-0";

    var d: Driver = .{ .gpa = gpa, .conn = try wl.Connection.connect(gpa, runtime, display), .bus_addr = vars.get("DBUS_SESSION_BUS_ADDRESS") };
    defer d.conn.deinit();
    d.registry = try d.conn.getRegistry();
    try d.roundtrip();
    try bindOutputs(&d);
    try setupInput(&d, vars);
    try d.roundtrip();
    loop.reply("ok ready", .{});
    try loop.serve(&d, common.commands.run);
}

/// Outputs: logical position, size and connector name, left to right.
fn bindOutputs(d: *Driver) !void {
    for (d.outputs.items) |*o| {
        o.id = try d.conn.bind(d.registry, o.global, "wl_output", 4);
        if (d.g.xdg_output_mgr != 0) {
            o.xdg = d.conn.newId();
            try d.conn.request(d.g.xdg_output_mgr, wl.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = o.xdg }, .{ .object = o.id } });
        }
    }
    try d.roundtrip();
    try d.roundtrip();
    d.sortOutputs();
}

/// KWin's fake input (and the session bus for its screenshots), else
/// wlroots' virtual pointer and keyboard.
fn setupInput(d: *Driver, vars: *const std.process.Environ.Map) !void {
    if (d.g.fake != 0) {
        d.kwin = true;
        try d.conn.request(d.g.fake, proto.fake.authenticate, &.{ .{ .string = "shotlet-wldrive" }, .{ .string = "e2e tests" } });
        if (d.g.fake_version < 4) return fail("org_kde_kwin_fake_input v{d}: no keyboard", .{d.g.fake_version});
        d.bus = try dbus.Connection.connectSession(d.gpa, d.bus_addr orelse return error.NoBus);
    } else if (d.g.vp_mgr != 0 and d.g.vk_mgr != 0 and d.g.seat != 0) {
        d.pointer = d.conn.newId();
        try d.conn.request(d.g.vp_mgr, proto.vp_mgr.create_virtual_pointer, &.{ .{ .object = d.g.seat }, .{ .new_id = d.pointer } });
        d.keyboard = d.conn.newId();
        try d.conn.request(d.g.vk_mgr, proto.vk_mgr.create_virtual_keyboard, &.{ .{ .object = d.g.seat }, .{ .new_id = d.keyboard } });
        const path = vars.get("WLDRIVE_KEYMAP") orelse return fail("WLDRIVE_KEYMAP: an xkb keymap file is needed", .{});
        try d.uploadKeymap(path);
    } else {
        return fail("no virtual input: neither wlroots' virtual pointer/keyboard nor KWin's fake input", .{});
    }
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    loop.reply("err " ++ fmt, args);
    return error.Setup;
}

test {
    _ = Driver;
}
