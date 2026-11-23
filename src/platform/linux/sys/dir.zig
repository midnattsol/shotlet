//! Directories: open, create (including private temp dirs), list and
//! remove recursively.

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const io = @import("io.zig");
const fs = @import("fs.zig");
const time = @import("time.zig");

const fd_t = common.fd_t;
const pathZ = common.pathZ;

/// Open a directory for flock() or fsync().
pub fn openDir(path: []const u8) !fd_t {
    return common.openPath(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
}

pub fn mkdir(path: []const u8) void {
    mkdirMode(path, 0o755);
}

/// Best-effort mkdir with an explicit mode (existing directories are fine).
pub fn mkdirMode(path: []const u8, mode: u32) void {
    var buf: [common.path_max]u8 = undefined;
    const p = pathZ(&buf, path) catch return;
    _ = linux.mkdirat(linux.AT.FDCWD, p.ptr, mode);
}

/// mkdir -p: creates missing parents (0755) and the leaf with `mode`.
pub fn mkdirAll(path: []const u8, mode: u32) void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') mkdirMode(path[0..i], 0o755);
    }
    mkdirMode(path, mode);
}

/// Create a fresh private directory `<TMPDIR or /tmp>/<prefix>-<random>`.
/// Used by tests so parallel or repeated runs never share state.
pub fn makeTempDir(alloc: std.mem.Allocator, base: []const u8, prefix: []const u8) ![]u8 {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        time.getRandom(&rnd);
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}-{x}", .{ base, prefix, std.mem.readInt(u64, &rnd, .little) });
        var buf: [common.path_max]u8 = undefined;
        const p = pathZ(&buf, path) catch |err| {
            alloc.free(path);
            return err;
        };
        const rc = linux.mkdirat(linux.AT.FDCWD, p.ptr, 0o700);
        if (linux.errno(rc) == .SUCCESS) return path;
        alloc.free(path);
        if (linux.errno(rc) != .EXIST) return error.CannotCreateTempDir;
    }
    return error.CannotCreateTempDir;
}

/// What a directory entry is, as the directory itself says (`other`
/// includes "unknown": some file systems do not tell).
pub const EntryKind = enum { file, dir, symlink, other };

const Dirent = struct {
    name: []const u8,
    kind: EntryKind,
    is_dir: bool,
};

/// Next entry of a getdents64 batch at `off.*`, skipping "." and "..".
fn nextDirent(batch: []align(8) const u8, off: *usize) ?Dirent {
    while (off.* < batch.len) {
        const ent: *const linux.dirent64 = @ptrCast(@alignCast(&batch[off.*]));
        if (ent.reclen == 0) return null;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&batch[off.* + @offsetOf(linux.dirent64, "name")])), 0);
        off.* += ent.reclen;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const kind: EntryKind = switch (ent.type) {
            linux.DT.REG => .file,
            linux.DT.DIR => .dir,
            linux.DT.LNK => .symlink,
            else => .other,
        };
        return .{ .name = name, .kind = kind, .is_dir = kind == .dir };
    }
    return null;
}

/// Call `visit(ctx, name, kind)` for every entry of the directory `path`
/// ("." and ".." left out), without allocating; `name` is only valid
/// during the call.
pub fn eachEntry(path: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), []const u8, EntryKind) void) !void {
    const dfd = try openDir(path);
    defer io.close(dfd);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.SyscallFailed;
        if (n == 0) return;
        var off: usize = 0;
        while (nextDirent(buf[0..n], &off)) |e| visit(ctx, e.name, e.kind);
    }
}

/// rm -rf for a directory we created (tests only; does not follow symlinks).
pub fn removeTree(path: []const u8) void {
    removeTreeDepth(path, 0);
}

/// Up to 64 child names copied out of a getdents64 batch.
const NameBatch = struct {
    names: [64][256]u8 = undefined,
    lens: [64]usize = undefined,
    dirs: [64]bool = undefined,
    count: usize = 0,

    fn fill(self: *NameBatch, batch: []align(8) const u8) void {
        self.count = 0;
        var off: usize = 0;
        while (self.count < self.names.len) {
            const e = nextDirent(batch, &off) orelse break;
            if (e.name.len >= 256) continue;
            @memcpy(self.names[self.count][0..e.name.len], e.name);
            self.lens[self.count] = e.name.len;
            self.dirs[self.count] = e.is_dir;
            self.count += 1;
        }
    }
};

fn removeTreeDepth(path: []const u8, depth: usize) void {
    if (depth > 16) return;
    const dfd = openDir(path) catch {
        fs.unlink(path) catch {};
        return;
    };
    var buf: [4096]u8 align(8) = undefined;
    var batch: NameBatch = .{};
    while (true) {
        // collect a batch, close nothing yet; then delete and re-read
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        batch.fill(buf[0..n]);
        if (batch.count == 0) continue;
        for (0..batch.count) |i| {
            var child: [4096]u8 = undefined;
            const cp = std.fmt.bufPrint(&child, "{s}/{s}", .{ path, batch.names[i][0..batch.lens[i]] }) catch continue;
            if (batch.dirs[i]) removeTreeDepth(cp, depth + 1) else fs.unlink(cp) catch {};
        }
        _ = linux.lseek(dfd, 0, 0); // SEEK_SET: rescan after deletions
    }
    io.close(dfd);
    var pbuf: [common.path_max]u8 = undefined;
    const p = pathZ(&pbuf, path) catch return;
    _ = linux.unlinkat(linux.AT.FDCWD, p.ptr, linux.AT.REMOVEDIR);
}

/// Names in a directory (no "." or ".."), each with whether it is a
/// directory. Caller frees with freeNames.
pub const DirEntry = struct { name: []u8, is_dir: bool };

pub fn listDir(alloc: std.mem.Allocator, path: []const u8) ![]DirEntry {
    const dfd = try openDir(path);
    defer io.close(dfd);
    var out: std.ArrayList(DirEntry) = .empty;
    errdefer freeNames(alloc, out.items);
    errdefer out.deinit(alloc);
    var buf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.SyscallFailed;
        if (n == 0) break;
        var off: usize = 0;
        while (nextDirent(buf[0..n], &off)) |e| {
            const copy = try alloc.dupe(u8, e.name);
            out.append(alloc, .{ .name = copy, .is_dir = e.is_dir }) catch |err| {
                alloc.free(copy);
                return err;
            };
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeNames(alloc: std.mem.Allocator, list: []const DirEntry) void {
    for (list) |e| alloc.free(e.name);
}

test "eachEntry reports every entry with its kind" {
    const alloc = std.testing.allocator;
    const dir = try makeTempDir(alloc, "/tmp", "shotlet-each");
    defer alloc.free(dir);
    defer removeTree(dir);
    var a: [256]u8 = undefined;
    mkdirMode(try std.fmt.bufPrint(&a, "{s}/sub", .{dir}), 0o700);
    try fs.writeFile(try std.fmt.bufPrint(&a, "{s}/file", .{dir}), "x");
    const Seen = struct {
        files: usize = 0,
        dirs: usize = 0,
        fn visit(self: *@This(), name: []const u8, kind: EntryKind) void {
            _ = name;
            switch (kind) {
                .file => self.files += 1,
                .dir => self.dirs += 1,
                else => {},
            }
        }
    };
    var seen: Seen = .{};
    try eachEntry(dir, &seen, Seen.visit);
    try std.testing.expectEqual(@as(usize, 1), seen.files);
    try std.testing.expectEqual(@as(usize, 1), seen.dirs);
}
