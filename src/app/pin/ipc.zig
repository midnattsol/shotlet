//! Every pin is a process of its own; Close All Pins reaches the others
//! through a directory of sockets in the runtime directory, one per pin
//! (named after its process), each answering "close".

const std = @import("std");
const log = std.log.scoped(.pin);
const env_mod = @import("../env.zig");
const ipc = @import("../ipc.zig");
const sys = @import("../../platform/api.zig").sys;
const Env = env_mod.Env;

/// This pin's socket, listening; `fd` -1 when there is none (the pin
/// still works, Close All Pins just does not reach it).
pub const Listener = struct {
    server: ipc.Server = .{},
    /// server.fd, which pin.zig polls
    fd: sys.fd_t = -1,

    pub fn open(env: Env) Listener {
        var dir_buf: ipc.PathBuf = undefined;
        const dir = dirPath(&dir_buf, env) catch return .{};
        sys.mkdirMode(dir, 0o700);
        var pbuf: ipc.PathBuf = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{d}.sock", .{ dir, sys.processId() }) catch return .{};
        const server = ipc.Server.listen(path) catch |err| {
            log.warn("Close All Pins will not reach this pin: {t}", .{err});
            return .{};
        };
        return .{ .server = server, .fd = server.fd };
    }

    pub fn close(l: *Listener) void {
        l.server.close();
        l.fd = -1;
    }

    /// True when another pin asked this one to close.
    pub fn closeAsked(l: *Listener) bool {
        var asked = false;
        var buf: [16]u8 = undefined;
        while (l.server.next(&buf)) |req| {
            if (isClose(req.line)) asked = true;
            req.close();
        }
        return asked;
    }
};

fn dirPath(buf: []u8, env: Env) ![]u8 {
    return ipc.sessionPath(buf, env.runtime_dir, env.session.tag(), "pins", "");
}

fn isClose(msg: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, msg, "\r\n"), "close");
}

/// Ask every other pin to close; returns how many were asked. Sockets
/// nobody answers on are stale and go.
pub fn closeOthers(gpa: std.mem.Allocator, env: Env, own: *const Listener) usize {
    var dir_buf: ipc.PathBuf = undefined;
    const dir = dirPath(&dir_buf, env) catch return 0;
    const list = sys.listDir(gpa, dir) catch return 0;
    defer sys.freeNames(gpa, list);
    var n: usize = 0;
    for (list) |e| {
        if (e.is_dir or !std.mem.endsWith(u8, e.name, ".sock")) continue;
        var pbuf: ipc.PathBuf = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, e.name }) catch continue;
        if (std.mem.eql(u8, path, own.server.path())) continue;
        var ans: [1]u8 = undefined;
        if (ipc.request(path, "close", &ans, null) != null) n += 1 else sys.unlink(path) catch {};
    }
    return n;
}

test "only a close message closes a pin" {
    try std.testing.expect(isClose("close\n"));
    try std.testing.expect(isClose("close"));
    try std.testing.expect(!isClose("closed\n"));
    try std.testing.expect(!isClose(""));
}
