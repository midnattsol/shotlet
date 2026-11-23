//! Path-based file operations (std.fs now requires an Io instance; raw
//! syscalls are simpler here).

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const io = @import("io.zig");
const time = @import("time.zig");

const fd_t = common.fd_t;
const check = common.check;
const pathZ = common.pathZ;
const openPath = common.openPath;

pub fn openRead(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
}

pub fn openRw(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
}

pub fn openAppend(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
}

pub fn createWrite(path: []const u8) !fd_t {
    return openPath(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
}

/// Create a new file that must not exist yet (O_EXCL, no symlink
/// following). Fails with error.PathAlreadyExists otherwise.
pub fn createExclusive(path: []const u8, mode: u32) !fd_t {
    return openPath(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, mode);
}

/// Write a whole new file with O_EXCL; removes the partial file on error.
pub fn writeFileExclusive(path: []const u8, data: []const u8, mode: u32) !void {
    const fd = try createExclusive(path, mode);
    errdefer unlink(path) catch {};
    defer io.close(fd);
    try io.writeAll(fd, data);
}

/// Replace the file at `path` with `data` atomically: written to a fresh
/// temp file beside it (O_EXCL, never through a symlink) with `mode`,
/// fsynced, then renamed over `path`. A symlink at `path` is replaced,
/// not followed. On error the temp file is gone and `path` is untouched.
pub fn writeAtomic(path: []const u8, data: []const u8, mode: u32) !void {
    var tmp_buf: [common.path_max]u8 = undefined;
    const tmp, const fd = try createTempBeside(path, &tmp_buf, mode);
    {
        errdefer unlink(tmp) catch {};
        defer io.close(fd);
        try io.writeAll(fd, data);
        io.fsync(fd);
    }
    rename(tmp, path) catch |err| {
        unlink(tmp) catch {};
        return err;
    };
}

/// A unique `.<name>.<pid>.<random>.tmp` beside `path`, created O_EXCL.
fn createTempBeside(path: []const u8, buf: []u8, mode: u32) !struct { []u8, fd_t } {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const dir = if (slash) |i| path[0 .. i + 1] else "";
    const base = if (slash) |i| path[i + 1 ..] else path;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var rnd: [6]u8 = undefined;
        time.getRandom(&rnd);
        const tmp = try std.fmt.bufPrint(buf, "{s}.{s}.{d}.{x}.tmp", .{ dir, base, linux.getpid(), std.mem.readInt(u48, &rnd, .little) });
        const fd = createExclusive(tmp, mode) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempt < 8) continue else return err,
            else => return err,
        };
        return .{ tmp, fd };
    }
}

/// Open `path` read-only when it is a regular file of this user that no
/// one else may read or write, and not a symlink; error.NotPrivate
/// otherwise. Never blocks on a FIFO planted there.
pub fn openPrivateRegular(path: []const u8) !fd_t {
    const fd = openPath(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0) catch |err| switch (err) {
        error.NotFound => return err,
        else => return error.NotPrivate,
    };
    errdefer io.close(fd);
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true }, &stx));
    if (!private(stx, linux.S.IFREG)) return error.NotPrivate;
    return fd;
}

/// `path` is a directory of this user, closed to everyone else, and not
/// a symlink; error.NotPrivate otherwise.
pub fn checkPrivateDir(path: []const u8) !void {
    var buf: [common.path_max]u8 = undefined;
    const p = try pathZ(&buf, path);
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stx)) != .SUCCESS)
        return error.NotPrivate;
    if (!private(stx, linux.S.IFDIR)) return error.NotPrivate;
}

fn private(stx: linux.Statx, file_type: u32) bool {
    return stx.mode & linux.S.IFMT == file_type and stx.uid == linux.getuid() and stx.mode & 0o077 == 0;
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const fd = try createWrite(path);
    defer io.close(fd);
    try io.writeAll(fd, data);
}

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = try openRead(path);
    defer io.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try io.read(fd, &buf);
        if (n == 0) break;
        if (list.items.len + n > max) return error.FileTooBig;
        try list.appendSlice(alloc, buf[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

/// Read a small file into `buf`, with no allocator; error.FileTooBig
/// when it does not fit.
pub fn readFileBuf(path: []const u8, buf: []u8) ![]u8 {
    const fd = try openRead(path);
    defer io.close(fd);
    var len: usize = 0;
    while (true) {
        if (len == buf.len) {
            var probe: [1]u8 = undefined;
            if (try io.read(fd, &probe) != 0) return error.FileTooBig;
            break;
        }
        const n = try io.read(fd, buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

pub fn unlink(path: []const u8) !void {
    var buf: [common.path_max]u8 = undefined;
    const p = try pathZ(&buf, path);
    _ = try check(linux.unlinkat(linux.AT.FDCWD, p.ptr, 0));
}

pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    var oldz: [common.path_max]u8 = undefined;
    var newz: [common.path_max]u8 = undefined;
    const old = try pathZ(&oldz, old_path);
    const new = try pathZ(&newz, new_path);
    _ = try check(linux.renameat(linux.AT.FDCWD, old.ptr, linux.AT.FDCWD, new.ptr));
}

/// Seconds since the epoch of a file's last change; null when missing.
pub fn mtimeSec(path: []const u8) ?i64 {
    var buf: [common.path_max]u8 = undefined;
    const p = pathZ(&buf, path) catch return null;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.mtime.sec;
}

pub fn fileSize(path: []const u8) !u64 {
    var buf: [common.path_max]u8 = undefined;
    const p = try pathZ(&buf, path);
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .SIZE = true }, &stx));
    return stx.size;
}

/// The permission bits of `path` (0o777 and the like); null when it
/// cannot be read.
pub fn fileMode(path: []const u8) ?u32 {
    var buf: [common.path_max]u8 = undefined;
    const p = pathZ(&buf, path) catch return null;
    var stx: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .MODE = true }, &stx)) != .SUCCESS) return null;
    return stx.mode & 0o7777;
}

/// Create a symbolic link at `path` pointing to `target`.
pub fn symlink(target: []const u8, path: []const u8) !void {
    var tbuf: [common.path_max]u8 = undefined;
    var pbuf: [common.path_max]u8 = undefined;
    const t = try pathZ(&tbuf, target);
    const p = try pathZ(&pbuf, path);
    _ = try check(linux.symlinkat(t.ptr, linux.AT.FDCWD, p.ptr));
}

const testutil = @import("../../../testutil.zig");

test "writeAtomic replaces a file, and a symlink without following it" {
    const alloc = std.testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-atomic");
    defer tmp.deinit();
    const dir = tmp.path;
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const target = try std.fmt.bufPrint(&a, "{s}/target", .{dir});
    const link = try std.fmt.bufPrint(&b, "{s}/link", .{dir});
    try writeAtomic(target, "one", 0o600);
    try writeAtomic(target, "two", 0o600);
    var rb: [16]u8 = undefined;
    try std.testing.expectEqualStrings("two", try readFileBuf(target, &rb));
    try std.testing.expectEqual(@as(?u32, 0o600), fileMode(target));
    try symlink(target, link);
    try writeAtomic(link, "new", 0o644);
    try std.testing.expectEqualStrings("two", try readFileBuf(target, &rb));
    try std.testing.expectEqualStrings("new", try readFileBuf(link, &rb));
    // nothing but the two files is left behind
    const names = try @import("dir.zig").listDir(alloc, dir);
    defer alloc.free(names);
    defer @import("dir.zig").freeNames(alloc, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
}

test "private files and directories are told apart" {
    var tmp = try testutil.TmpDir.init("shotlet-private");
    defer tmp.deinit();
    const dir = tmp.path;
    try checkPrivateDir(dir);
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const mine = try std.fmt.bufPrint(&a, "{s}/mine", .{dir});
    const open = try std.fmt.bufPrint(&b, "{s}/open", .{dir});
    try writeAtomic(mine, "x", 0o600);
    try writeAtomic(open, "x", 0o644);
    io.close(try openPrivateRegular(mine));
    try std.testing.expectError(error.NotPrivate, openPrivateRegular(open));
    try std.testing.expectError(error.NotPrivate, checkPrivateDir(mine));
}
