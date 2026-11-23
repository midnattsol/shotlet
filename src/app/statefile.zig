//! Shotlet's small files of its own: state ($XDG_STATE_HOME/shotlet:
//! last area, capture path, pending setup, flags, the daemon log) and
//! the records kept beside the config ($XDG_CONFIG_HOME/shotlet: moved
//! GNOME shortcuts). The directory is created private (0700) when
//! needed; every write replaces the file atomically, 0600, never through
//! a symlink (sys.writeAtomic).

const std = @import("std");
const env = @import("env.zig");
const sys = @import("../platform/api.zig").sys;

pub const Dir = enum { state, config };

/// Where `name` lives in `dir`.
pub fn path(buf: []u8, home: []const u8, dir: Dir, name: []const u8) ![]u8 {
    return switch (dir) {
        .state => env.statePath(buf, home, name),
        .config => env.configPath(buf, home, name),
    };
}

/// Where `name` lives in `dir`, the directory created (0700) if needed:
/// for files written some other way (the daemon's log).
pub fn prepare(buf: []u8, home: []const u8, dir: Dir, name: []const u8) ![]u8 {
    var dbuf: env.PathBuf = undefined;
    _ = try switch (dir) {
        .state => env.ensureStateDir(&dbuf, home),
        .config => env.ensureConfigDir(&dbuf, home),
    };
    return path(buf, home, dir, name);
}

/// The whole file (owned), at most `max` bytes; error.NotFound when absent.
pub fn read(gpa: std.mem.Allocator, home: []const u8, dir: Dir, name: []const u8, max: usize) ![]u8 {
    var pbuf: env.PathBuf = undefined;
    return sys.readFileAlloc(gpa, try path(&pbuf, home, dir, name), max);
}

/// A small file into `buf`, without allocating.
pub fn readBuf(home: []const u8, dir: Dir, name: []const u8, buf: []u8) ![]u8 {
    var pbuf: env.PathBuf = undefined;
    return sys.readFileBuf(try path(&pbuf, home, dir, name), buf);
}

/// Replace the file with `data`.
pub fn write(home: []const u8, dir: Dir, name: []const u8, data: []const u8) !void {
    var pbuf: env.PathBuf = undefined;
    try sys.writeAtomic(try prepare(&pbuf, home, dir, name), data, 0o600);
}

/// Add `extra` after what the file holds (created when missing); the
/// result replaces it at once, so a crash never leaves half a record.
pub fn append(gpa: std.mem.Allocator, home: []const u8, dir: Dir, name: []const u8, extra: []const u8, max: usize) !void {
    const old = read(gpa, home, dir, name, max) catch |err| switch (err) {
        error.NotFound => try gpa.dupe(u8, ""),
        else => return err,
    };
    defer gpa.free(old);
    const all = try std.mem.concat(gpa, u8, &.{ old, extra });
    defer gpa.free(all);
    try write(home, dir, name, all);
}

/// Remove the file; true when it was there and is now gone.
pub fn remove(home: []const u8, dir: Dir, name: []const u8) bool {
    var pbuf: env.PathBuf = undefined;
    sys.unlink(path(&pbuf, home, dir, name) catch return false) catch return false;
    return true;
}

test "state files are written atomically, private, and appended to" {
    const gpa = std.testing.allocator;
    var tmp = try @import("../testutil.zig").TmpDir.home();
    defer tmp.deinit();
    const home = tmp.path;
    try std.testing.expectError(error.NotFound, read(gpa, home, .state, "x", 64));
    try write(home, .state, "x", "one\n");
    try append(gpa, home, .state, "x", "two\n", 64);
    const got = try read(gpa, home, .state, "x", 64);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("one\ntwo\n", got);
    var pbuf: env.PathBuf = undefined;
    try std.testing.expectEqual(@as(?u32, 0o600), sys.fileMode(try path(&pbuf, home, .state, "x")));
    try append(gpa, home, .config, "y", "a", 64);
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a", try readBuf(home, .config, "y", &b));
    try std.testing.expect(remove(home, .state, "x"));
    try std.testing.expect(!remove(home, .state, "x"));
}
