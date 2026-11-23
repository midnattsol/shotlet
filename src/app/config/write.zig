//! Writing the config file: given key=value changes are merged into the
//! current file under a directory lock and the result replaces it
//! atomically (a private temp file renamed over it).

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const env = @import("../env.zig");
const parse = @import("parse.zig");
const keys = @import("keys.zig");
const location = @import("location.zig");
const model = @import("model.zig");
const Config = model.Config;

pub const Change = struct { key: []const u8, value: []const u8 };

/// Keys that are no longer used and are dropped when the file is written.
const legacy_keys = [_][]const u8{"screencast_token"};

/// Set `changes` in `dir`'s config file, leaving every other line as it is.
pub fn updateDir(gpa: std.mem.Allocator, dir: []const u8, changes: []const Change) !void {
    sys.mkdirAll(dir, 0o700);
    // serialize writers (shot, settings, daemon) on the directory
    const dfd = try sys.openDir(dir);
    defer sys.close(dfd);
    try sys.lockExclusive(dfd);

    var path_buf: env.PathBuf = undefined;
    const path = try location.configFile(dir, &path_buf);
    const old: []u8 = sys.readFileAlloc(gpa, path, 64 * 1024) catch |err| switch (err) {
        error.NotFound => try gpa.dupe(u8, "# shotlet configuration\n"),
        else => return err,
    };
    defer gpa.free(old);

    const content = try mergeContent(gpa, old, changes);
    defer gpa.free(content);
    try sys.writeAtomic(path, content, 0o600);
}

/// Rewrite `old` with `changes` applied: matching lines get the new value
/// (later duplicates are dropped), untouched lines and comments are kept
/// byte for byte, and keys not present yet are appended.
pub fn mergeContent(gpa: std.mem.Allocator, old: []const u8, changes: []const Change) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var done: [64]bool = @splat(false);
    if (changes.len > done.len) return error.TooManyChanges;

    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break; // trailing newline
        if (keys.parseLine(line)) |kv| {
            if (isLegacyKey(kv.key) or replaced(kv.key, changes)) continue;
            if (findChange(changes, kv.key)) |ci| {
                if (!done[ci]) {
                    try appendKv(gpa, &out, changes[ci]);
                    done[ci] = true;
                }
                continue;
            }
        }
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    for (changes, 0..) |ch, ci| {
        if (!done[ci] and findChange(changes[0..ci], ch.key) == null) try appendKv(gpa, &out, ch);
    }
    return out.toOwnedSlice(gpa);
}

fn isLegacyKey(key: []const u8) bool {
    for (legacy_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// An older file's key whose replacement is being written: a
/// `bind_<action>` for `shortcut_<action>` (config/parse.zig reads the old
/// one only without the new), a parse.superseded key for its new one.
fn replaced(key: []const u8, changes: []const Change) bool {
    for (parse.superseded) |s| {
        if (std.mem.eql(u8, key, s.old) and findChange(changes, s.new) != null) return true;
    }
    if (!std.mem.startsWith(u8, key, parse.legacy_prefix)) return false;
    const action = key[parse.legacy_prefix.len..];
    for (changes) |ch| {
        if (std.mem.startsWith(u8, ch.key, model.bind_prefix) and std.mem.eql(u8, ch.key[model.bind_prefix.len..], action)) return true;
    }
    return false;
}

fn findChange(changes: []const Change, key: []const u8) ?usize {
    // the last change for a key wins
    var i = changes.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, changes[i].key, key)) return i;
    }
    return null;
}

/// "key=value\n", with CR/LF dropped from the value.
fn appendKv(gpa: std.mem.Allocator, out: *std.ArrayList(u8), ch: Change) !void {
    try out.appendSlice(gpa, ch.key);
    try out.append(gpa, '=');
    for (ch.value) |c| {
        if (c != '\n' and c != '\r') try out.append(gpa, c);
    }
    try out.append(gpa, '\n');
}

test "merge keeps comments, replaces in place, drops duplicates" {
    const gpa = std.testing.allocator;
    const out = try mergeContent(gpa, "# c\nnotify=true\nx=1\nnotify=false\n", &.{
        .{ .key = "notify", .value = "false" },
        .{ .key = "save_dir", .value = "/a\nb" },
    });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("# c\nnotify=false\nx=1\nsave_dir=/ab\n", out);
}

test "single-monitor restore tokens are dropped" {
    const gpa = std.testing.allocator;
    const out = try mergeContent(gpa, "screencast_token=old\nnotify=true\n", &.{
        .{ .key = "screencast_restore_token", .value = "new" },
    });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("notify=true\nscreencast_restore_token=new\n", out);
    var cfg = Config{};
    parse.applyValue(&cfg, "screencast_token", "old");
    try std.testing.expect(cfg.scToken() == null);
}

test "a thumbnail written anew drops the quick_access switch it replaced" {
    const gpa = std.testing.allocator;
    const out = try mergeContent(gpa, "quick_access=false\nnotify=true\n", &.{
        .{ .key = "thumbnail", .value = "never" },
    });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("notify=true\nthumbnail=never\n", out);
}

test "a bind written anew drops the older file's line for it" {
    const gpa = std.testing.allocator;
    const out = try mergeContent(gpa, "bind_pen=33\nbind_line=38\nnotify=true\n", &.{
        .{ .key = "shortcut_pen", .value = "Ctrl+F" },
    });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("bind_line=38\nnotify=true\nshortcut_pen=Ctrl+F\n", out);
}
