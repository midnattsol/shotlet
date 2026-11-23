//! GNOME Settings' custom shortcuts that run shotlet: finding them,
//! moving them to the extension's own shortcut (remembered in
//! ~/.config/shotlet/gnome-moved-shortcuts) and putting them back.

const std = @import("std");
const statefile = @import("../../../app/statefile.zig");
const env_mod = @import("../../../app/env.zig");
const gsettings = @import("gsettings.zig");
const extension = @import("extension.zig");
const Env = env_mod.Env;

pub const media_keys = "org.gnome.settings-daemon.plugins.media-keys";
const custom_schema = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";

/// A custom shortcut's command runs this shotlet, with no arguments (or
/// "shot"): "shotlet", "/usr/bin/shotlet", "~/.local/bin/shotlet shot".
pub fn isShotletCommand(command: []const u8, exe: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    var prog = it.next() orelse return false;
    if (prog.len >= 2 and (prog[0] == '\'' or prog[0] == '"') and prog[prog.len - 1] == prog[0]) prog = prog[1 .. prog.len - 1];
    const base = if (std.mem.lastIndexOfScalar(u8, prog, '/')) |i| prog[i + 1 ..] else prog;
    if (!std.mem.eql(u8, base, "shotlet") and !std.mem.eql(u8, prog, exe)) return false;
    if (it.next()) |arg| {
        if (!std.mem.eql(u8, arg, "shot")) return false;
        if (it.next() != null) return false;
    }
    return true;
}

/// A custom shortcut as GNOME Settings keeps it.
pub const Custom = struct { path: []const u8, name: []const u8, command: []const u8, binding: []const u8 };

/// The relocatable schema of the custom shortcut at `path`.
pub fn customPathSchema(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, custom_schema ++ ":{s}", .{path});
}

pub fn getString(arena: std.mem.Allocator, env: Env, schema: []const u8, key: []const u8) ![]u8 {
    const out = try gsettings.get(arena, env, null, schema, key);
    return gsettings.parseString(arena, out);
}

/// The paths of GNOME's custom shortcuts.
pub fn customList(arena: std.mem.Allocator, env: Env) ![][]u8 {
    return gsettings.parseStrv(arena, try gsettings.get(arena, env, null, media_keys, "custom-keybindings"));
}

/// Custom shortcuts whose command runs shotlet.
pub fn findShotletShortcuts(arena: std.mem.Allocator, env: Env, exe: []const u8) ![]Custom {
    const list = try customList(arena, env);
    var found: std.ArrayList(Custom) = .empty;
    for (list) |path| {
        const schema = customPathSchema(arena, path) catch continue;
        const command = getString(arena, env, schema, "command") catch continue;
        if (!isShotletCommand(command, exe)) continue;
        const c: Custom = .{
            .path = path,
            .name = getString(arena, env, schema, "name") catch "",
            .command = command,
            .binding = getString(arena, env, schema, "binding") catch "",
        };
        // kept one per line, tab separated (backup_name)
        if (hasTabOrNewline(c.name) or hasTabOrNewline(c.command) or
            hasTabOrNewline(c.binding) or hasTabOrNewline(c.path)) continue;
        try found.append(arena, c);
    }
    return found.toOwnedSlice(arena);
}

fn hasTabOrNewline(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\t\n") != null;
}

/// Where moved shortcuts are remembered (beside the config), for uninstall.
const backup_name = "gnome-moved-shortcuts";

/// The most a backup of moved shortcuts or keys holds.
pub const backup_max = 1024 * 1024;

/// `s` is one of `list`.
pub fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Move the shortcuts to the extension's: remembered first, then taken
/// off GNOME's custom list.
pub fn moveShortcuts(arena: std.mem.Allocator, env: Env, schemadir: []const u8, moved: []const Custom) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList(u8) = .empty;
    for (moved) |c| {
        try records.print(arena, "{s}\t{s}\t{s}\t{s}\n", .{ c.path, c.name, c.command, c.binding });
        if (c.binding.len > 0 and !contains(keys.items, c.binding)) try keys.append(arena, c.binding);
    }
    try statefile.append(arena, env.home, .config, backup_name, records.items, backup_max);
    try gsettings.set(arena, env, schemadir, extension.ext_schema_id, "capture-shortcut", try gsettings.formatStrv(arena, keys.items));
    try dropCustoms(arena, env, moved);
}

/// Take `moved` off GNOME's custom list and clear their settings.
fn dropCustoms(arena: std.mem.Allocator, env: Env, moved: []const Custom) !void {
    const list = try customList(arena, env);
    var keep: std.ArrayList([]const u8) = .empty;
    for (list) |p| {
        for (moved) |c| {
            if (std.mem.eql(u8, c.path, p)) break;
        } else try keep.append(arena, p);
    }
    try gsettings.set(arena, env, null, media_keys, "custom-keybindings", try gsettings.formatStrv(arena, keep.items));
    for (moved) |c| {
        const schema = try customPathSchema(arena, c.path);
        for ([_][]const u8{ "name", "command", "binding" }) |k| gsettings.reset(arena, env, null, schema, k) catch {};
    }
}

/// Put moved shortcuts back on GNOME's custom list (uninstall).
pub fn restoreShortcuts(arena: std.mem.Allocator, env: Env) !usize {
    const data = statefile.read(arena, env.home, .config, backup_name, backup_max) catch return 0;
    const list = try customList(arena, env);
    var paths: std.ArrayList([]const u8) = .empty;
    for (list) |p| try paths.append(arena, p);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const c: Custom = .{
            .path = f.next() orelse continue,
            .name = f.next() orelse continue,
            .command = f.next() orelse continue,
            .binding = f.next() orelse continue,
        };
        if (c.path.len == 0 or c.path[0] != '/') continue;
        try restoreCustom(arena, env, c);
        if (!contains(paths.items, c.path)) try paths.append(arena, c.path);
        n += 1;
    }
    try gsettings.set(arena, env, null, media_keys, "custom-keybindings", try gsettings.formatStrv(arena, paths.items));
    _ = statefile.remove(env.home, .config, backup_name);
    return n;
}

/// Write one custom shortcut's name, command and binding back.
fn restoreCustom(arena: std.mem.Allocator, env: Env, c: Custom) !void {
    const schema = try customPathSchema(arena, c.path);
    try gsettings.set(arena, env, null, schema, "name", try gsettings.formatString(arena, c.name));
    try gsettings.set(arena, env, null, schema, "command", try gsettings.formatString(arena, c.command));
    try gsettings.set(arena, env, null, schema, "binding", try gsettings.formatString(arena, c.binding));
}

test "custom shortcuts that run shotlet" {
    const exe = "/opt/x/shotlet-bin";
    try std.testing.expect(isShotletCommand("shotlet", exe));
    try std.testing.expect(isShotletCommand("/home/u/.local/bin/shotlet", exe));
    try std.testing.expect(isShotletCommand("  shotlet shot ", exe));
    try std.testing.expect(isShotletCommand("'/usr/bin/shotlet'", exe));
    try std.testing.expect(isShotletCommand("/opt/x/shotlet-bin", exe));
    try std.testing.expect(!isShotletCommand("shotlet history", exe));
    try std.testing.expect(!isShotletCommand("shotlet shot --from x.png", exe));
    try std.testing.expect(!isShotletCommand("sh -c shotlet", exe));
    try std.testing.expect(!isShotletCommand("notshotlet", exe));
    try std.testing.expect(!isShotletCommand("", exe));
}
