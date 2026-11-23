//! One recording at a time, controlled from outside: the recording
//! listens on $XDG_RUNTIME_DIR/shotlet-record-<session>.sock (the
//! session's tag, api.desktop.Addresses.tag); `shotlet
//! record` while one runs (the same shortcut again), `shotlet record
//! --stop` and the tray send it a command instead of starting another.
//!
//!     stop | pause | resume | discard | status    ->  "ok ..." or "err"

const std = @import("std");
const ipc = @import("../app/ipc.zig");
const sys = @import("../platform/api.zig").sys;

pub const Command = enum { stop, pause, resume_, discard, status };

pub fn parse(line: []const u8) ?Command {
    const l = std.mem.trim(u8, line, " \r\n");
    if (std.mem.eql(u8, l, "resume")) return .resume_;
    const c = std.meta.stringToEnum(Command, l) orelse return null;
    return if (c == .resume_) null else c;
}

pub fn path(buf: []u8, runtime_dir: []const u8, session: []const u8) ![]u8 {
    return ipc.sessionPath(buf, runtime_dir, session, "record", ".sock");
}

/// Send a command to the running recording; its answer, or null when
/// none is running.
pub fn send(runtime_dir: []const u8, session: []const u8, cmd: []const u8, ans: []u8) ?[]const u8 {
    var pbuf: ipc.PathBuf = undefined;
    const p = path(&pbuf, runtime_dir, session) catch return null;
    return ipc.request(p, cmd, ans, 3000);
}

pub const Server = struct {
    server: ipc.Server,
    /// server.fd, to poll
    fd: sys.fd_t,

    /// Listen; error.AddressInUse when another recording answers there
    /// (a socket left by one that crashed is taken over).
    pub fn listen(runtime_dir: []const u8, session: []const u8) !Server {
        var pbuf: ipc.PathBuf = undefined;
        const s = try ipc.Server.listen(try path(&pbuf, runtime_dir, session));
        return .{ .server = s, .fd = s.fd };
    }

    pub fn close(self: *Server) void {
        self.server.close();
        self.fd = -1;
    }

    /// A waiting command, if any; `reply` answers it on `conn_out`.
    pub fn poll(self: *Server, conn_out: *sys.fd_t) ?Command {
        var buf: [64]u8 = undefined;
        while (self.server.next(&buf)) |req| {
            const cmd = parse(req.line) orelse {
                req.reply("err");
                continue;
            };
            conn_out.* = req.fd;
            return cmd;
        }
        return null;
    }

    pub fn reply(conn: sys.fd_t, text: []const u8) void {
        (ipc.Request{ .fd = conn, .line = "" }).reply(text);
    }
};

test "commands parse" {
    try std.testing.expectEqual(Command.stop, parse("stop\n").?);
    try std.testing.expectEqual(Command.resume_, parse("resume").?);
    try std.testing.expect(parse("resume_") == null);
    try std.testing.expect(parse("rm -rf") == null);
}
