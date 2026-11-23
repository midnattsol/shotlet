//! Process environment handed down from main to every subsystem, and the
//! XDG base directories derived from it.

const std = @import("std");
const sys = @import("../platform/api.zig").sys;

pub const Env = struct {
    /// where the desktop session's services are: the backend's, opaque
    /// here (api.desktop.addresses fills it)
    session: @import("../platform/api.zig").desktop.Addresses,
    runtime_dir: []const u8,
    home: []const u8,
    /// the parent's complete environment, passed on to children unchanged
    envp: [*:null]const ?[*:0]const u8 = &empty_envp,
    /// TZ, when set (see clock.zig)
    tz: ?[]const u8 = null,
};

const empty_envp = [_:null]?[*:0]const u8{};

/// A buffer for any path (directories under $HOME, files in them).
pub const PathBuf = [std.fs.max_path_bytes]u8;

/// XDG base directories, set once by main (`Xdg.read`). Kept
/// process-wide because some callers (the Settings window, font
/// discovery) only receive `home`, or nothing.
pub const Xdg = struct {
    /// XDG_CONFIG_HOME, only when it is an absolute path (the spec says
    /// relative values are invalid and must be ignored)
    config_home: ?[]const u8 = null,
    /// XDG_STATE_HOME, same rule
    state_home: ?[]const u8 = null,
    /// XDG_CACHE_HOME, same rule
    cache_home: ?[]const u8 = null,
    /// XDG_DATA_HOME, same rule
    data_home: ?[]const u8 = null,
    /// XDG_PICTURES_DIR / XDG_VIDEOS_DIR from the environment, if exported
    pictures_dir: ?[]const u8 = null,
    videos_dir: ?[]const u8 = null,
    /// $HOME, for code that is handed no Env (font discovery)
    home: ?[]const u8 = null,
    /// XDG_CURRENT_DESKTOP: the desktops this session is, colon separated
    /// ("ubuntu:GNOME")
    current_desktop: ?[]const u8 = null,

    /// The variables from the process environment (`vars.get(name)`).
    pub fn read(vars: anytype) Xdg {
        return .{
            .config_home = absolute(vars.get("XDG_CONFIG_HOME")),
            .state_home = absolute(vars.get("XDG_STATE_HOME")),
            .cache_home = absolute(vars.get("XDG_CACHE_HOME")),
            .data_home = absolute(vars.get("XDG_DATA_HOME")),
            .pictures_dir = absolute(vars.get("XDG_PICTURES_DIR")),
            .videos_dir = absolute(vars.get("XDG_VIDEOS_DIR")),
            .home = absolute(vars.get("HOME")),
            .current_desktop = vars.get("XDG_CURRENT_DESKTOP"),
        };
    }
};

pub var xdg: Xdg = .{};

/// Keep a value only when it is a non-empty absolute path.
pub fn absolute(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    if (s.len == 0 or s[0] != '/') return null;
    return s;
}

/// `set`, or `home` + `fallback`, + `sub`.
fn baseDir(buf: []u8, set: ?[]const u8, home: []const u8, comptime fallback: []const u8, comptime sub: []const u8) ![]u8 {
    if (set) |d| return std.fmt.bufPrint(buf, "{s}" ++ sub, .{d});
    return std.fmt.bufPrint(buf, "{s}/" ++ fallback ++ sub, .{home});
}

/// $XDG_CONFIG_HOME, or ~/.config.
pub fn configHome(buf: []u8, home: []const u8) ![]u8 {
    return baseDir(buf, xdg.config_home, home, ".config", "");
}

/// $XDG_DATA_HOME, or ~/.local/share.
pub fn dataHome(buf: []u8, home: []const u8) ![]u8 {
    return baseDir(buf, xdg.data_home, home, ".local/share", "");
}

/// $XDG_CONFIG_HOME/shotlet, or ~/.config/shotlet.
pub fn configDir(buf: []u8, home: []const u8) ![]u8 {
    return baseDir(buf, xdg.config_home, home, ".config", "/shotlet");
}

/// $XDG_STATE_HOME/shotlet, or ~/.local/state/shotlet.
pub fn stateDir(buf: []u8, home: []const u8) ![]u8 {
    return baseDir(buf, xdg.state_home, home, ".local/state", "/shotlet");
}

/// $XDG_CACHE_HOME/shotlet, or ~/.cache/shotlet.
pub fn cacheDir(buf: []u8, home: []const u8) ![]u8 {
    return baseDir(buf, xdg.cache_home, home, ".cache", "/shotlet");
}

/// `name` in Shotlet's state directory (stateDir).
pub fn statePath(buf: []u8, home: []const u8, name: []const u8) ![]u8 {
    var dir: PathBuf = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ try stateDir(&dir, home), name });
}

/// `name` in Shotlet's config directory (configDir).
pub fn configPath(buf: []u8, home: []const u8, name: []const u8) ![]u8 {
    var dir: PathBuf = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ try configDir(&dir, home), name });
}

/// `sub` (a file or a directory) in Shotlet's cache directory (cacheDir).
pub fn cachePath(buf: []u8, home: []const u8, sub: []const u8) ![]u8 {
    var dir: PathBuf = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ try cacheDir(&dir, home), sub });
}

/// Create the state directory (private, 0700) if needed; its path.
pub fn ensureStateDir(buf: []u8, home: []const u8) ![]u8 {
    const d = try stateDir(buf, home);
    sys.mkdirAll(d, 0o700);
    return d;
}

/// Create the config directory (private, 0700) if needed; its path.
pub fn ensureConfigDir(buf: []u8, home: []const u8) ![]u8 {
    const d = try configDir(buf, home);
    sys.mkdirAll(d, 0o700);
    return d;
}

/// Create the cache subdirectory `sub` (private, 0700) if needed; its path.
pub fn ensureCacheDir(buf: []u8, home: []const u8, sub: []const u8) ![]u8 {
    const d = try cachePath(buf, home, sub);
    sys.mkdirAll(d, 0o700);
    return d;
}

/// Expand a leading `~/`, `$HOME/` or `${HOME}/` (and a bare `~`/`$HOME`).
pub fn expandHome(buf: []u8, home: []const u8, path: []const u8) ![]u8 {
    const prefixes = [_][]const u8{ "~", "$HOME", "${HOME}" };
    for (prefixes) |p| {
        if (std.mem.eql(u8, path, p)) return std.fmt.bufPrint(buf, "{s}", .{home});
        if (path.len > p.len and std.mem.startsWith(u8, path, p) and path[p.len] == '/')
            return std.fmt.bufPrint(buf, "{s}{s}", .{ home, path[p.len..] });
    }
    return std.fmt.bufPrint(buf, "{s}", .{path});
}

/// The user directories Shotlet saves into.
pub const UserDir = enum {
    pictures,
    videos,

    fn variable(self: UserDir) []const u8 {
        return switch (self) {
            .pictures => "XDG_PICTURES_DIR",
            .videos => "XDG_VIDEOS_DIR",
        };
    }

    fn fallback(self: UserDir) []const u8 {
        return switch (self) {
            .pictures => "Pictures",
            .videos => "Videos",
        };
    }
};

/// The user's Pictures or Videos directory: $XDG_PICTURES_DIR /
/// $XDG_VIDEOS_DIR, then the entry in $XDG_CONFIG_HOME/user-dirs.dirs
/// (localized, e.g. "Imágenes"), then ~/Pictures or ~/Videos. A value
/// equal to $HOME means "disabled" per the spec, so it falls through to
/// the default rather than saving into $HOME.
pub fn userDir(alloc: std.mem.Allocator, buf: []u8, home: []const u8, which: UserDir) ![]u8 {
    const exported = switch (which) {
        .pictures => xdg.pictures_dir,
        .videos => xdg.videos_dir,
    };
    if (exported) |d| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, d, "/"), std.mem.trimEnd(u8, home, "/")))
            return std.fmt.bufPrint(buf, "{s}", .{d});
    }
    var path_buf: PathBuf = undefined;
    var cfg_home_buf: PathBuf = undefined;
    const cfg_home = try configHome(&cfg_home_buf, home);
    const dirs_path = try std.fmt.bufPrint(&path_buf, "{s}/user-dirs.dirs", .{cfg_home});
    if (sys.readFileAlloc(alloc, dirs_path, 64 * 1024)) |data| {
        defer alloc.free(data);
        if (parseUserDir(data, which.variable(), home, buf)) |p| return p;
    } else |_| {}
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, which.fallback() });
}

/// Find `NAME="$HOME/x"` or `NAME="/abs"` in a user-dirs.dirs file.
pub fn parseUserDir(data: []const u8, name: []const u8, home: []const u8, buf: []u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, name)) continue;
        var rest = std.mem.trimStart(u8, trimmed[name.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len >= 2 and rest[0] == '"') {
            const close = std.mem.lastIndexOfScalar(u8, rest, '"') orelse continue;
            if (close == 0) continue;
            rest = rest[1..close];
        }
        // the file is shell syntax: unescape \" \\ \$ \`
        var tmp: PathBuf = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < rest.len and n < tmp.len) : (i += 1) {
            if (rest[i] == '\\' and i + 1 < rest.len) i += 1;
            tmp[n] = rest[i];
            n += 1;
        }
        const value = tmp[0..n];
        if (std.mem.eql(u8, std.mem.trimEnd(u8, value, "/"), "$HOME")) return null;
        if (std.mem.startsWith(u8, value, "$HOME/"))
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, value["$HOME/".len..] }) catch null;
        if (value.len > 0 and value[0] == '/') return std.fmt.bufPrint(buf, "{s}", .{value}) catch null;
        return null;
    }
    return null;
}

const testutil = @import("../testutil.zig");

test "user-dirs parsing" {
    var buf: [256]u8 = undefined;
    const data =
        \\# comment
        \\XDG_DESKTOP_DIR="$HOME/Escritorio"
        \\XDG_PICTURES_DIR="$HOME/Im\"ágenes"
        \\
    ;
    try std.testing.expectEqualStrings("/home/u/Im\"ágenes", parseUserDir(data, "XDG_PICTURES_DIR", "/home/u", &buf).?);
    try std.testing.expectEqualStrings("/data/pics", parseUserDir("XDG_PICTURES_DIR=\"/data/pics\"", "XDG_PICTURES_DIR", "/h", &buf).?);
    try std.testing.expect(parseUserDir("XDG_PICTURES_DIR=\"$HOME/\"", "XDG_PICTURES_DIR", "/h", &buf) == null);
    try std.testing.expect(parseUserDir("XDG_PICTURES_DIRX=\"/x\"", "XDG_PICTURES_DIR", "/h", &buf) == null);
}

test "home expansion" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/h/shots", try expandHome(&buf, "/h", "~/shots"));
    try std.testing.expectEqualStrings("/h/shots", try expandHome(&buf, "/h", "$HOME/shots"));
    try std.testing.expectEqualStrings("/h", try expandHome(&buf, "/h", "~"));
    try std.testing.expectEqualStrings("~x/y", try expandHome(&buf, "/h", "~x/y"));
}

test "state, cache and config paths follow the XDG variables" {
    const saved = testutil.useXdg(.{ .cache_home = "/c" });
    defer saved.restore();
    var buf: PathBuf = undefined;
    try std.testing.expectEqualStrings("/h/.local/state/shotlet/last-area", try statePath(&buf, "/h", "last-area"));
    try std.testing.expectEqualStrings("/c/shotlet/drop", try cachePath(&buf, "/h", "drop"));
    try std.testing.expectEqualStrings("/h/.config/shotlet/x", try configPath(&buf, "/h", "x"));
    try std.testing.expectEqualStrings("/h/.local/share", try dataHome(&buf, "/h"));
}

test "a user directory equal to $HOME counts as unset" {
    const saved = testutil.useXdg(.{ .videos_dir = "/h/", .config_home = "/nonexistent-shotlet" });
    defer saved.restore();
    var buf: PathBuf = undefined;
    try std.testing.expectEqualStrings("/h/Videos", try userDir(std.testing.allocator, &buf, "/h", .videos));
    xdg.pictures_dir = "/data/pics";
    try std.testing.expectEqualStrings("/data/pics", try userDir(std.testing.allocator, &buf, "/h", .pictures));
}
