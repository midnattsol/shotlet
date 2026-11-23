//! The Shotlet GNOME Shell extension itself: GNOME Shell's view of it
//! (org.gnome.Shell.Extensions), installing it from extensions.gnome.org
//! or from the copy bundled in the binary, and where its files live.

const std = @import("std");
const log = std.log.scoped(.gnome);
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const env_mod = @import("../../../app/env.zig");
const Env = env_mod.Env;

pub const uuid = "shotlet@midnattsol.github.io";
/// owned by the extension while it is active
pub const bus_name = @import("shell1.zig").bus_name;
/// the extension's own settings (schemas/ in its directory)
pub const ext_schema_id = "org.gnome.shell.extensions.shotlet";

const ext_js = @embedFile("gnome_ext_js");
const ext_metadata = @embedFile("gnome_ext_metadata");
/// extension.js's own modules: file name, contents
const ext_modules = [_][2][]const u8{
    .{ "modes.js", @embedFile("gnome_ext_modes_js") },
    .{ "windowpick.js", @embedFile("gnome_ext_windowpick_js") },
    .{ "scroll.js", @embedFile("gnome_ext_scroll_js") },
    .{ "util.js", @embedFile("gnome_ext_util_js") },
};
const ext_schema = @embedFile("gnome_ext_schema");
const ext_schema_compiled = @embedFile("gnome_ext_schema_compiled");
const schema_file = "org.gnome.shell.extensions.shotlet.gschema.xml";

const shell_dest = "org.gnome.Shell.Extensions";
const shell_path = "/org/gnome/Shell/Extensions";
const shell_iface = "org.gnome.Shell.Extensions";

/// XDG_CURRENT_DESKTOP names GNOME.
pub fn isGnome() bool {
    return namesGnome(env_mod.xdg.current_desktop orelse return false);
}

fn namesGnome(desktops: []const u8) bool {
    var it = std.mem.splitScalar(u8, desktops, ':');
    while (it.next()) |part| if (std.ascii.eqlIgnoreCase(part, "GNOME")) return true;
    return false;
}

/// The extension is loaded and running in this session.
pub fn extensionActive(bus: *dbus.Connection) bool {
    return bus.nameHasOwner(bus_name) catch false;
}

/// The GNOME integration runs here: GNOME, with the extension active.
pub fn integrationActive(bus: *dbus.Connection) bool {
    return isGnome() and extensionActive(bus);
}

/// Call `member` of org.gnome.Shell.Extensions with our uuid and wait up
/// to `timeout_ms` for the reply.
fn callShell(gpa: std.mem.Allocator, bus: *dbus.Connection, member: []const u8, timeout_ms: i64) !dbus.Message {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(uuid);
    return bus.call(shell_dest, shell_path, shell_iface, member, "s", m.buf.items, timeout_ms);
}

/// GNOME Shell's view of the extension: org.gnome.Shell.Extensions'
/// "state" (its ExtensionState numbers).
pub const ShellState = enum(u32) {
    active = 1,
    inactive = 2,
    failed = 3,
    out_of_date = 4,
    initialized = 6,
    /// GNOME Shell does not know it (not installed, or installed since
    /// it started)
    unknown = 99,
    _,

    fn of(v: anytype) ShellState {
        return @fromBackingInt(@intCast(@as(u32, @intCast(@max(0, v)))));
    }
};

/// GNOME Shell's view of the extension; null without GNOME Shell.
pub fn shellState(gpa: std.mem.Allocator, bus: *dbus.Connection) ?ShellState {
    var reply = callShell(gpa, bus, "GetExtensionInfo", 5000) catch return null;
    defer reply.deinit(gpa);
    var r = reply.reader();
    var it = r.readDictSV() catch return null;
    while (it.next() catch return null) |kv| {
        if (std.mem.eql(u8, kv.key, "state")) return switch (kv.value) {
            .f64_ => |v| .of(@as(i64, @intFromFloat(std.math.clamp(v, 0, std.math.maxInt(u32))))),
            .u32_ => |v| @fromBackingInt(@intCast(v)),
            .i32_ => |v| .of(v),
            else => null,
        };
    }
    return .unknown; // an empty dict
}

/// GNOME Shell's "path" for the extension (its schemas live there).
fn extensionPath(gpa: std.mem.Allocator, bus: *dbus.Connection, buf: []u8) ?[]const u8 {
    var reply = callShell(gpa, bus, "GetExtensionInfo", 5000) catch return null;
    defer reply.deinit(gpa);
    var r = reply.reader();
    var it = r.readDictSV() catch return null;
    while (it.next() catch return null) |kv| {
        if (std.mem.eql(u8, kv.key, "path") and kv.value == .string) {
            if (kv.value.string.len > buf.len) return null;
            @memcpy(buf[0..kv.value.string.len], kv.value.string);
            return buf[0..kv.value.string.len];
        }
    }
    return null;
}

/// EnableExtension, DisableExtension: GNOME Shell's yes or no.
pub fn callBool(gpa: std.mem.Allocator, bus: *dbus.Connection, member: []const u8, timeout_ms: i64) !bool {
    var reply = try callShell(gpa, bus, member, timeout_ms);
    defer reply.deinit(gpa);
    var r = reply.reader();
    return (try r.readU32()) != 0;
}

/// InstallRemoteExtension: "successful", "cancelled", or an error.
fn installRemote(gpa: std.mem.Allocator, bus: *dbus.Connection) !bool {
    // GNOME shows a confirmation dialog: give the person time
    var reply = try callShell(gpa, bus, "InstallRemoteExtension", 120_000);
    defer reply.deinit(gpa);
    var r = reply.reader();
    return std.mem.eql(u8, try r.readString(), "successful");
}

/// The extension's directory under $XDG_DATA_HOME (or ~/.local/share).
pub fn extensionDir(buf: []u8, home: []const u8) ![]u8 {
    var data: env_mod.PathBuf = undefined;
    return std.fmt.bufPrint(buf, "{s}/gnome-shell/extensions/{s}", .{ try env_mod.dataHome(&data, home), uuid });
}

/// Copy the bundled extension into the user's extension directory.
pub fn writeBundled(home: []const u8) ![]const u8 {
    const S = struct {
        var dir_buf: [1024]u8 = undefined;
    };
    const dir = try extensionDir(&S.dir_buf, home);
    sys.mkdirAll(dir, 0o755);
    var p: [1100]u8 = undefined;
    try sys.writeFile(try std.fmt.bufPrint(&p, "{s}/extension.js", .{dir}), ext_js);
    try sys.writeFile(try std.fmt.bufPrint(&p, "{s}/metadata.json", .{dir}), ext_metadata);
    for (ext_modules ++ @import("bundle.zig").modules) |mod| try sys.writeFile(try std.fmt.bufPrint(&p, "{s}/{s}", .{ dir, mod[0] }), mod[1]);
    const schemas = try std.fmt.bufPrint(&p, "{s}/schemas", .{dir});
    sys.mkdirAll(schemas, 0o755);
    var q: [1200]u8 = undefined;
    try sys.writeFile(try std.fmt.bufPrint(&q, "{s}/" ++ schema_file, .{schemas}), ext_schema);
    try sys.writeFile(try std.fmt.bufPrint(&q, "{s}/gschemas.compiled", .{schemas}), ext_schema_compiled);
    return dir;
}

/// --schemadir for the extension's settings.
pub fn schemaDir(gpa: std.mem.Allocator, env: Env, bus: ?*dbus.Connection, buf: []u8) ![]const u8 {
    var pbuf: [1024]u8 = undefined;
    const dir = (if (bus) |b| extensionPath(gpa, b, &pbuf) else null) orelse try extensionDir(&pbuf, env.home);
    return std.fmt.bufPrint(buf, "{s}/schemas", .{dir});
}

pub const InstallResult = enum { active, installed_relogin, failed };

/// Install and enable the extension: from extensions.gnome.org when GNOME
/// Shell does not know it yet, otherwise (or when that fails) the bundled
/// copy, which GNOME Shell on Wayland may only load at the next login.
pub fn installExtension(gpa: std.mem.Allocator, env: Env, bus_opt: ?*dbus.Connection) InstallResult {
    const bus = bus_opt orelse return .failed;
    if (extensionActive(bus)) return .active;
    const state = shellState(gpa, bus);
    if (state == null) {
        log.warn("GNOME Shell is not running here", .{});
        return .failed;
    }
    if (state.? == .unknown) {
        if (installRemote(gpa, bus)) |ok| {
            if (ok and waitActive(bus)) return .active;
        } else |err| log.info("extensions.gnome.org install not possible ({t}); using the bundled copy", .{err});
    }
    const dir = writeBundled(env.home) catch |err| {
        log.warn("could not copy the extension: {t}", .{err});
        return .failed;
    };
    log.info("installed the GNOME Shell extension in {s}", .{dir});
    _ = callBool(gpa, bus, "EnableExtension", 5000) catch |err|
        log.warn("could not enable the extension: {t}", .{err});
    if (waitActive(bus)) return .active;
    return .installed_relogin;
}

/// Wait up to two seconds for the extension to come up.
fn waitActive(bus: *dbus.Connection) bool {
    const end = sys.monoMs() + 2000;
    while (sys.monoMs() < end) {
        if (extensionActive(bus)) return true;
        sys.sleepMs(100);
    }
    return false;
}

const testutil = @import("../../../testutil.zig");

test "the bundled extension declares the uuid and bus name we look for" {
    try testutil.expectContains(ext_metadata, "\"uuid\": \"" ++ uuid ++ "\"");
    try testutil.expectContains(ext_js, bus_name);
    try testutil.expectContains(ext_js, "shotlet:quick");
    // the settings schema the metadata names ships, compiled
    try testutil.expectContains(ext_metadata, "\"settings-schema\": \"" ++ ext_schema_id ++ "\"");
    try testutil.expectContains(ext_schema, "id=\"" ++ ext_schema_id ++ "\"");
    try testutil.expectContains(ext_schema_compiled, ext_schema_id);
    try testutil.expectContains(ext_js, "'--from-shell'");
}

test "GNOME is told from XDG_CURRENT_DESKTOP" {
    try std.testing.expect(namesGnome("GNOME"));
    try std.testing.expect(namesGnome("ubuntu:GNOME"));
    try std.testing.expect(namesGnome("gnome-classic:gnome"));
    try std.testing.expect(!namesGnome("KDE"));
    try std.testing.expect(!namesGnome("GNOME-Flashback-ish"));
    try std.testing.expect(!namesGnome(""));
    const saved = env_mod.xdg;
    defer env_mod.xdg = saved;
    env_mod.xdg = .read(struct {
        pub fn get(_: @This(), name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "XDG_CURRENT_DESKTOP")) "sway:GNOME" else null;
        }
    }{});
    try std.testing.expect(isGnome());
    env_mod.xdg = .{};
    try std.testing.expect(!isGnome());
}
