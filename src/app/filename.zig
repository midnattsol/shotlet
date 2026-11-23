//! The names of the files shotlet writes, screenshots and recordings
//! alike: `shotlet-YYYYMMDD-HHMMSS` in local time, written so that no
//! existing file is ever replaced unless the save dialog asked first.

const std = @import("std");
const clock = @import("clock.zig");
const env_mod = @import("env.zig");
const sys = @import("../platform/api.zig").sys;

/// "shotlet-20260701-140501" for `utc_s` (seconds since the epoch) in
/// local time.
pub fn baseName(gpa: std.mem.Allocator, env: env_mod.Env, utc_s: i64, buf: []u8) ![]u8 {
    return format(buf, clock.localTime(gpa, env.tz, utc_s));
}

/// baseName for the current time.
pub fn baseNameNow(gpa: std.mem.Allocator, env: env_mod.Env, buf: []u8) ![]u8 {
    return baseName(gpa, env, sys.realtimeSec(), buf);
}

fn format(buf: []u8, lt: clock.LocalTime) ![]u8 {
    return std.fmt.bufPrint(buf, "shotlet-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        lt.year, lt.month, lt.day, lt.hour, lt.minute, lt.second,
    });
}

/// `<dir>/<base><ext>`, or `<base>-2<ext>`, `-3`, ... (owned).
fn candidate(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8, n: u32) ![]u8 {
    if (n == 1) return std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, base, ext });
    return std.fmt.allocPrint(gpa, "{s}/{s}-{d}{s}", .{ dir, base, n, ext });
}

const max_tries = 10_000;

/// Write `data` to `<dir>/<base><ext>`, or `<base>-2<ext>`, `-3`, ...
/// when taken. Never overwrites: each attempt is an O_EXCL create (a
/// symlink in the way is not followed). Returns the path written (owned).
pub fn writeUnique(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8, data: []const u8) ![]u8 {
    return writeFirstFree(gpa, dir, base, ext, data, false);
}

/// Reserve a new, empty `<dir>/<base><ext>` (or -2 ...) for a writer that
/// opens it later (the encoder, ffmpeg). Owned.
pub fn reserveUnique(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8) ![:0]u8 {
    const p = try writeUnique(gpa, dir, base, ext, "");
    defer gpa.free(p);
    return gpa.dupeSentinel(u8, p, 0);
}

/// writeUnique, but a file of that name already holding exactly `data`
/// is taken as it is (the same capture dragged out twice reuses its copy
/// rather than piling up -2, -3 ...).
pub fn writeOrReuse(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8, data: []const u8) ![]u8 {
    return writeFirstFree(gpa, dir, base, ext, data, true);
}

fn writeFirstFree(gpa: std.mem.Allocator, dir: []const u8, base: []const u8, ext: []const u8, data: []const u8, reuse: bool) ![]u8 {
    var n: u32 = 1;
    while (n < max_tries) : (n += 1) {
        const path = try candidate(gpa, dir, base, ext, n);
        errdefer gpa.free(path);
        sys.writeFileExclusive(path, data, 0o644) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (reuse and holds(gpa, path, data)) return path;
                gpa.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.TooManyCollisions;
}

/// The file at `path` holds exactly `data`.
fn holds(gpa: std.mem.Allocator, path: []const u8, data: []const u8) bool {
    const size = sys.fileSize(path) catch return false;
    if (size != data.len) return false;
    const got = sys.readFileAlloc(gpa, path, data.len) catch return false;
    defer gpa.free(got);
    return std.mem.eql(u8, got, data);
}

/// The file to write for a save dialog's answer `chosen` (consumed) and a
/// file of type `ext` (".png"): `chosen` itself when it ends in `ext`
/// (the dialog already asked before replacing it), else `<chosen><ext>`
/// reserved as a new file, never over one the dialog did not ask about.
/// Owned.
pub fn completeChosen(gpa: std.mem.Allocator, chosen: []u8, ext: []const u8) ![]u8 {
    if (std.ascii.endsWithIgnoreCase(chosen, ext)) return chosen;
    defer gpa.free(chosen);
    const slash = std.mem.lastIndexOfScalar(u8, chosen, '/') orelse return error.BadPath;
    return writeUnique(gpa, chosen[0..slash], chosen[slash + 1 ..], ext, "");
}

/// The extension of `path` (".mp4"), or "" without one.
pub fn extension(path: []const u8) []const u8 {
    const name = path[(if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0)..];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return if (dot == 0) "" else name[dot..];
}

// --- tests ---

const testing = std.testing;

const testutil = @import("../testutil.zig");

test "names read shotlet-date-time, zero-padded" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("shotlet-20260701-140501", try format(&buf, clock.breakDown(1782914701)));
    try testing.expectEqualStrings("shotlet-19700101-000000", try format(&buf, clock.breakDown(0)));
    // TZ=UTC: local time is UTC
    const env: env_mod.Env = .{ .session = undefined, .runtime_dir = "", .home = "", .tz = "UTC" };
    try testing.expectEqualStrings("shotlet-20260701-140501", try baseName(testing.allocator, env, 1782914701, &buf));
}

test "saved names never overwrite" {
    const gpa = testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-test");
    defer tmp.deinit();
    const dir = tmp.path;

    const a = try writeUnique(gpa, dir, "shot", ".png", "one");
    defer gpa.free(a);
    const b = try writeUnique(gpa, dir, "shot", ".png", "two");
    defer gpa.free(b);
    const c = try reserveUnique(gpa, dir, "shot", ".png");
    defer gpa.free(c);
    try testing.expect(std.mem.endsWith(u8, a, "/shot.png"));
    try testing.expect(std.mem.endsWith(u8, b, "/shot-2.png"));
    try testing.expect(std.mem.endsWith(u8, c, "/shot-3.png"));
    const first = try sys.readFileAlloc(gpa, a, 64);
    defer gpa.free(first);
    try testing.expectEqualStrings("one", first);
    try testing.expectEqual(@as(u64, 0), try sys.fileSize(c));

    // a symlink in the way is not followed
    var link_buf: [512]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/l.png", .{dir});
    try sys.symlink("/nonexistent-target", link);
    const d = try writeUnique(gpa, dir, "l", ".png", "x");
    defer gpa.free(d);
    try testing.expect(std.mem.endsWith(u8, d, "/l-2.png"));
}

test "a copy with the same bytes is reused, a different one is not overwritten" {
    const gpa = testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-test");
    defer tmp.deinit();
    const dir = tmp.path;

    const a = try writeOrReuse(gpa, dir, "drag", ".png", "first capture");
    defer gpa.free(a);
    const again = try writeOrReuse(gpa, dir, "drag", ".png", "first capture");
    defer gpa.free(again);
    try testing.expectEqualStrings(a, again);
    // another capture taken in the same second: its own file
    const b = try writeOrReuse(gpa, dir, "drag", ".png", "second capture");
    defer gpa.free(b);
    try testing.expect(std.mem.endsWith(u8, b, "/drag-2.png"));
    const kept = try sys.readFileAlloc(gpa, a, 64);
    defer gpa.free(kept);
    try testing.expectEqualStrings("first capture", kept);
}

test "a chosen name gets its extension without replacing a file" {
    const gpa = testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-test");
    defer tmp.deinit();
    const dir = tmp.path;

    const as_typed = try completeChosen(gpa, try std.fmt.allocPrint(gpa, "{s}/x.PNG", .{dir}), ".png");
    defer gpa.free(as_typed);
    try testing.expect(std.mem.endsWith(u8, as_typed, "/x.PNG"));

    var buf: [512]u8 = undefined;
    try sys.writeFile(try std.fmt.bufPrint(&buf, "{s}/clip.mp4", .{dir}), "theirs");
    const added = try completeChosen(gpa, try std.fmt.allocPrint(gpa, "{s}/clip", .{dir}), ".mp4");
    defer gpa.free(added);
    try testing.expect(std.mem.endsWith(u8, added, "/clip-2.mp4"));
    try testing.expectError(error.BadPath, completeChosen(gpa, try gpa.dupe(u8, "noslash"), ".png"));

    try testing.expectEqualStrings(".mp4", extension("/v/shotlet-1.mp4"));
    try testing.expectEqualStrings("", extension("/v.d/name"));
    try testing.expectEqualStrings("", extension("/v/.hidden"));
}
