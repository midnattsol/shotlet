//! Telling xdg-desktop-portal who we are: the host Registry on 1.19+, a
//! transient `app-<id>-<pid>.scope` on older portals, nothing in Flatpak.

const std = @import("std");
const log = std.log.scoped(.portal);
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");

pub const app_id = @import("../../../app_id.zig").app_id;

/// Connect to the session bus and tell xdg-desktop-portal who we are,
/// before anything on that connection talks to a portal.
pub fn connectApp(gpa: std.mem.Allocator, bus_addr: []const u8) !dbus.Connection {
    var bus = try dbus.Connection.connectSession(gpa, bus_addr);
    registerApp(gpa, &bus);
    return bus;
}

pub const Identity = enum { registry, scope, sandbox, unknown };

/// Give the portal our app id, so stored consent (screen cast restore,
/// screenshot permission) is found again whatever started us: a GNOME
/// custom shortcut, a terminal, the tray daemon. xdg-desktop-portal 1.19+
/// has org.freedesktop.host.portal.Registry.Register for unsandboxed apps;
/// it applies to this bus connection and must come before any other
/// portal call on it. Older portals derive the id from the systemd unit,
/// so without Registry we move into an `app-<id>-<pid>.scope`. Inside
/// Flatpak the sandbox already names us.
pub fn registerApp(gpa: std.mem.Allocator, bus: *dbus.Connection) void {
    const how = registerAppInner(gpa, bus);
    log.info("portal identity: {s} ({t})", .{ app_id, how });
}

fn registerAppInner(gpa: std.mem.Allocator, bus: *dbus.Connection) Identity {
    if (sys.fileSize("/.flatpak-info")) |_| return .sandbox else |_| {}
    switch (registerWithRegistry(gpa, bus)) {
        .ok => return .registry,
        .unsupported => {},
        .failed => return .unknown,
    }
    ensureAppScope(gpa, bus);
    return .scope;
}

const RegisterOutcome = enum { ok, unsupported, failed };

fn registerWithRegistry(gpa: std.mem.Allocator, bus: *dbus.Connection) RegisterOutcome {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(app_id) catch return .failed;
    const opts = m.beginDict() catch return .failed;
    opts.end();
    // the first call may start the portal (bus activation)
    var reply = bus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.host.portal.Registry",
        "Register",
        "sa{sv}",
        m.buf.items,
        15_000,
    ) catch |err| return registerFailure(err);
    reply.deinit(bus.alloc);
    return .ok;
}

/// A Registry call that failed: no Registry here (an older portal, or
/// none) falls back to a scope; anything else is a refusal.
fn registerFailure(err: anyerror) RegisterOutcome {
    switch (err) {
        error.UnknownMethod, error.ServiceUnknown => return .unsupported,
        else => {
            log.warn("portal registration: {t}", .{err});
            return .failed;
        },
    }
}

test "a missing Registry falls back; a refusal does not" {
    try std.testing.expectEqual(RegisterOutcome.unsupported, registerFailure(error.UnknownMethod));
    try std.testing.expectEqual(RegisterOutcome.unsupported, registerFailure(error.ServiceUnknown));
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    try std.testing.expectEqual(RegisterOutcome.failed, registerFailure(error.DBusError));
    try std.testing.expectEqual(RegisterOutcome.failed, registerFailure(error.Timeout));
}

/// The scope a portal older than 1.19 reads our app id from.
const scope_prefix = "app-" ++ app_id ++ "-";

/// Move this process into its own `app-<app id>-<pid>.scope` transient
/// systemd scope (as `systemd-run --user --scope` does): xdg-desktop-portal
/// before 1.19 derives the caller's app id from the unit name. Fallback
/// for registerApp.
pub fn ensureAppScope(gpa: std.mem.Allocator, bus: *dbus.Connection) void {
    ensureAppScopeInner(gpa, bus) catch |err| {
        log.warn("could not move into an app scope: {t}", .{err});
    };
}

fn ensureAppScopeInner(gpa: std.mem.Allocator, bus: *dbus.Connection) !void {
    if (try inAppScope(gpa)) return; // already there
    if (!systemdOnBus(bus)) return;
    const pid: u32 = @intCast(std.os.linux.getpid());
    try startScopeUnit(gpa, bus, pid);
    try waitForScopeMove(gpa);
}

/// Whether /proc/self/cgroup already names our app scope.
fn inAppScope(gpa: std.mem.Allocator) !bool {
    const cg = try sys.readFileAlloc(gpa, "/proc/self/cgroup", 4096);
    defer gpa.free(cg);
    return std.mem.indexOf(u8, cg, scope_prefix) != null;
}

/// Whether systemd's user manager owns its bus name (logs why not).
fn systemdOnBus(bus: *dbus.Connection) bool {
    const systemd_name = "org.freedesktop.systemd1";
    const has_systemd = bus.nameHasOwner(systemd_name) catch |err| {
        log.debug("skipping app scope: could not query {s}: {t}", .{ systemd_name, err });
        return false;
    };
    if (!has_systemd) {
        // dbus-daemon may list systemd1 as activatable even when activating it
        // only spawns a child that exits. Do not pay that cost on every shot.
        log.debug("skipping app scope: {s} has no bus owner", .{systemd_name});
        return false;
    }
    return true;
}

/// StartTransientUnit for `app-<id>-<pid>.scope` holding `pid`, in
/// app.slice; waits for the reply.
fn startScopeUnit(gpa: std.mem.Allocator, bus: *dbus.Connection, pid: u32) !void {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, scope_prefix ++ "{d}.scope", .{pid});

    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(name);
    try m.putString("fail"); // mode
    const props = try m.beginArray(8); // a(sv)
    {
        try m.beginStruct();
        try m.putString("PIDs");
        try m.putSignature("au");
        const pids = try m.beginArray(4);
        try m.putU32(pid);
        m.endArray(pids);

        try m.putEntry("Slice", "app.slice");
    }
    m.endArray(props);
    const aux = try m.beginArray(8); // a(sa(sv))
    m.endArray(aux);

    var reply = try bus.call(
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        "ssa(sv)a(sa(sv))",
        m.buf.items,
        dbus.default_reply_timeout_ms,
    );
    reply.deinit(bus.alloc);
}

/// The cgroup move is asynchronous; wait (up to ~1 s) for it to land.
fn waitForScopeMove(gpa: std.mem.Allocator) !void {
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        if (try inAppScope(gpa)) return;
        sys.sleepMs(50);
    }
    return error.ScopeMoveTimedOut;
}
