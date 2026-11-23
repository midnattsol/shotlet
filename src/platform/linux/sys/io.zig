//! Operations on open file descriptors: read/write, pipes, poll, shared
//! memory, locks and file metadata.

const std = @import("std");
const linux = std.os.linux;
const common = @import("common.zig");
const time = @import("time.zig");

const fd_t = common.fd_t;
const check = common.check;
const retryIntr = common.retryIntr;

pub const pollfd = linux.pollfd;
pub const POLL = linux.POLL;

pub const MFD_CLOEXEC: u32 = 1;

pub fn read(fd: fd_t, buf: []u8) !usize {
    return retryIntr(linux.read, .{ fd, buf.ptr, buf.len });
}

pub fn write(fd: fd_t, buf: []const u8) !usize {
    return retryIntr(linux.write, .{ fd, buf.ptr, buf.len });
}

pub fn writeAll(fd: fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) off += try write(fd, buf[off..]);
}

/// Like writeAll, but waits for fds that temporarily reject writes. Wayland
/// clipboard pipes can be non-blocking; closing them after EAGAIN truncates
/// large PNG transfers.
pub fn writeAllBlocking(fd: fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(fd, buf[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = try poll(&fds, -1);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.BrokenPipe;
        off += n;
    }
}

/// A close-on-exec pipe: [read end, write end].
pub fn pipe() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    _ = try check(linux.pipe2(&fds, .{ .CLOEXEC = true }));
    return fds;
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn poll(fds: []linux.pollfd, timeout_ms: i32) !usize {
    return retryIntr(linux.poll, .{ fds.ptr, fds.len, timeout_ms });
}

/// Wait until `fd` is readable or the deadline passes. Returns false on
/// timeout. Hang-up and errors count as readable so the next read reports
/// them.
pub fn waitReadable(fd: fd_t, deadline_ms: ?i64) !bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const n = try poll(&fds, time.timeoutUntil(deadline_ms));
    return n > 0;
}

/// Read `fd` until EOF, `max` bytes or the deadline (monotonic ms; none:
/// wait as long as it takes), whichever comes first. Caller owns the
/// bytes. To fail on more than `max`, ask for max + 1 and check the length.
pub fn readBounded(gpa: std.mem.Allocator, fd: fd_t, max: usize, deadline_ms: ?i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (out.items.len < max) {
        if (!try waitReadable(fd, deadline_ms)) break; // timed out
        const n = try read(fd, buf[0..@min(buf.len, max - out.items.len)]);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Fill `buf` from `fd`: error.ShortRead at EOF first, error.Timeout once
/// the deadline (monotonic ms; none: no limit) passes.
pub fn readExact(fd: fd_t, buf: []u8, deadline_ms: ?i64) !void {
    var got: usize = 0;
    while (got < buf.len) {
        if (deadline_ms != null and !try waitReadable(fd, deadline_ms)) return error.Timeout;
        const n = try read(fd, buf[got..]);
        if (n == 0) return error.ShortRead;
        got += n;
    }
}

pub fn memfdCreate(name: [*:0]const u8, flags: u32) !fd_t {
    const rc = try check(linux.memfd_create(name, flags));
    return @intCast(rc);
}

pub fn ftruncate(fd: fd_t, len: u64) !void {
    _ = try check(linux.ftruncate(fd, @intCast(len)));
}

/// `fd` mapped shared, read and write, its pages made now (a buffer is
/// written whole soon after: the faults are taken here, at once, not
/// while drawing the first frame).
pub fn mmapRw(fd: fd_t, len: usize) ![]align(std.heap.page_size_min) u8 {
    const rc = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .POPULATE = true }, fd, 0);
    _ = try check(rc);
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
    return ptr[0..len];
}

pub fn munmap(mem: []align(std.heap.page_size_min) const u8) void {
    _ = linux.munmap(mem.ptr, mem.len);
}

pub fn fsync(fd: fd_t) void {
    _ = linux.fsync(fd);
}

pub fn fchmod(fd: fd_t, mode: u32) void {
    _ = linux.fchmod(fd, mode);
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) void {
    _ = linux.dup2(old_fd, new_fd);
}

/// Exclusive advisory lock; released by closing the fd.
pub fn lockExclusive(fd: fd_t) !void {
    _ = try retryIntr(linux.flock, .{ fd, 2 }); // LOCK_EX
}

/// Identity of an open file (device + inode).
pub const FileId = struct { dev_major: u32, dev_minor: u32, ino: u64 };

pub fn fileId(fd: fd_t) ?FileId {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .dev_major = stx.dev_major, .dev_minor = stx.dev_minor, .ino = stx.ino };
}

/// Size of an open file.
pub fn fdSize(fd: fd_t) !u64 {
    var stx: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stx));
    return stx.size;
}

/// Whether `fd` is a terminal (1: is standard output one?).
pub fn isTerminal(fd: fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.tcgetattr(fd, &t)) == .SUCCESS;
}

/// Map the whole file at `path` read-only; error.BadSize unless it holds
/// `min`..`max` bytes. Undo with unmapFile.
pub fn mapFile(path: []const u8, min: u64, max: u64) ![]const u8 {
    const fd = try @import("fs.zig").openRead(path);
    defer close(fd);
    const size = try fdSize(fd);
    if (size < min or size > max) return error.BadSize;
    return mapFd(fd, @intCast(size));
}

/// Map `len` bytes of the open file `fd` read-only and private (the fd
/// can be closed afterwards). Undo with unmapFile.
pub fn mapFd(fd: fd_t, len: usize) ![]const u8 {
    const rc = linux.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MmapFailed;
    const ptr: [*]const u8 = @ptrFromInt(rc);
    return ptr[0..len];
}

pub fn unmapFile(d: []const u8) void {
    const p: [*]align(std.heap.page_size_min) const u8 = @alignCast(d.ptr);
    _ = linux.munmap(p, d.len);
}

test "bounded and exact reads stop at EOF, the limit and the deadline" {
    const gpa = std.testing.allocator;
    const fds = try pipe();
    defer close(fds[0]);
    try writeAll(fds[1], "abcdef");
    const head = try readBounded(gpa, fds[0], 2, time.monoMs() + 1000);
    defer gpa.free(head);
    try std.testing.expectEqualStrings("ab", head);
    var three: [3]u8 = undefined;
    try readExact(fds[0], &three, time.monoMs() + 1000);
    try std.testing.expectEqualStrings("cde", &three);
    // the writer stays open: only the deadline ends these
    const rest = try readBounded(gpa, fds[0], 100, time.monoMs() + 50);
    defer gpa.free(rest);
    try std.testing.expectEqualStrings("f", rest);
    try std.testing.expectError(error.Timeout, readExact(fds[0], &three, time.monoMs() + 20));
    close(fds[1]);
    try std.testing.expectError(error.ShortRead, readExact(fds[0], &three, null));
}
