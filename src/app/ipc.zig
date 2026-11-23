//! Talking to another running shotlet: a unix stream socket in the
//! runtime directory, one request line per connection, answered (or
//! not) with one line. Quick access (quick_ipc.zig), the pins
//! (pin/ipc.zig) and the recording's control socket (record/ctlsock.zig)
//! are protocols on top of this.
//!
//! A socket file whose process died stays behind. Listening takes it
//! over only when nobody accepts a connection on it (`alive`): a
//! running instance keeps its socket.

const std = @import("std");
const sys = @import("../platform/api.zig").sys;

/// How long a server waits for a client's request line.
pub const read_ms = 500;

/// Room for a socket path (sockaddr_un holds 108 bytes).
pub const PathBuf = [108]u8;

/// `<runtime>/shotlet-<name>-<session tag><ext>`: per desktop session,
/// so two sessions of one user don't meet.
pub fn sessionPath(buf: []u8, runtime_dir: []const u8, tag: []const u8, name: []const u8, ext: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/shotlet-{s}-{s}{s}", .{ runtime_dir, name, tag, ext });
}

/// Something accepts connections at `path`.
pub fn alive(path: []const u8) bool {
    const fd = sys.socketUnixStream() catch return false;
    defer sys.close(fd);
    sys.connectUnix(fd, path) catch return false;
    return true;
}

/// Send `line` (a newline is added) to the server at `path`. With
/// `answer_ms`, wait that long for its answer and return it without the
/// newline; without, return "" once sent. Null when nobody listens or
/// answers.
pub fn request(path: []const u8, line: []const u8, ans: []u8, answer_ms: ?i64) ?[]const u8 {
    const fd = sys.socketUnixStream() catch return null;
    defer sys.close(fd);
    sys.connectUnix(fd, path) catch return null;
    sys.writeAll(fd, line) catch return null;
    sys.writeAll(fd, "\n") catch return null;
    const ms = answer_ms orelse return "";
    const got = readLine(fd, ans, sys.monoMs() + ms);
    if (got.len == 0) return null;
    return std.mem.trimEnd(u8, got, "\r\n");
}

/// Up to a newline (kept), the end of the stream, a full buffer or the
/// deadline.
fn readLine(fd: sys.fd_t, buf: []u8, deadline: i64) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        if (!(sys.waitReadable(fd, deadline) catch false)) break;
        const k = sys.read(fd, buf[n..]) catch break;
        if (k == 0) break;
        n += k;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
    }
    return buf[0..n];
}

/// A client's request; answer it with `reply`, or `close` it.
pub const Request = struct {
    fd: sys.fd_t,
    /// without its newline
    line: []const u8,

    /// `text` and a newline, then the connection closes.
    pub fn reply(r: Request, text: []const u8) void {
        sys.writeAll(r.fd, text) catch {};
        sys.writeAll(r.fd, "\n") catch {};
        r.close();
    }

    pub fn close(r: Request) void {
        sys.close(r.fd);
    }
};

/// A listening socket (non-blocking accept: poll `fd`, then `next`).
pub const Server = struct {
    fd: sys.fd_t = -1,
    path_buf: PathBuf = undefined,
    path_len: usize = 0,

    /// Listen at `path`, taking over a stale socket file there;
    /// error.AddressInUse when a live server has it.
    pub fn listen(at: []const u8) !Server {
        var s: Server = .{};
        if (at.len > s.path_buf.len) return error.NameTooLong;
        @memcpy(s.path_buf[0..at.len], at);
        s.path_len = at.len;
        s.fd = sys.listenUnix(at) catch |err| blk: {
            if (err != error.AddressInUse or alive(at)) return err;
            sys.unlink(at) catch {};
            break :blk try sys.listenUnix(at);
        };
        return s;
    }

    pub fn path(s: *const Server) []const u8 {
        return s.path_buf[0..s.path_len];
    }

    /// Stop listening and remove the socket file.
    pub fn close(s: *Server) void {
        if (s.fd < 0) return;
        sys.close(s.fd);
        s.fd = -1;
        sys.unlink(s.path()) catch {};
    }

    /// The next waiting client's request line, read into `buf`; null
    /// when nobody waits. A client that sends nothing in time (or only
    /// connects, as `alive` does) is dropped.
    pub fn next(s: *Server, buf: []u8) ?Request {
        if (s.fd < 0) return null;
        while (sys.accept(s.fd) catch null) |fd| {
            const got = readLine(fd, buf, sys.monoMs() + read_ms);
            if (got.len == 0) {
                sys.close(fd);
                continue;
            }
            return .{ .fd = fd, .line = std.mem.trimEnd(u8, got, "\r\n") };
        }
        return null;
    }
};

fn testDir(gpa: std.mem.Allocator) ![]const u8 {
    return sys.makeTempDir(gpa, "/tmp", "shotlet-ipc");
}

test "session paths" {
    var buf: PathBuf = undefined;
    try std.testing.expectEqualStrings("/run/user/1/shotlet-quick-wl0.sock", try sessionPath(&buf, "/run/user/1", "wl0", "quick", ".sock"));
    try std.testing.expectEqualStrings("/r/shotlet-pins-x", try sessionPath(&buf, "/r", "x", "pins", ""));
}

test "a request reaches the server and its answer comes back" {
    const gpa = std.testing.allocator;
    const dir = try testDir(gpa);
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    var pbuf: PathBuf = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/t.sock", .{dir});
    var s = try Server.listen(p);
    defer s.close();
    var ans: [16]u8 = undefined;
    // the client writes before the server reads: the socket buffers it
    try std.testing.expectEqualStrings("", request(p, "close", &ans, null).?);
    var buf: [64]u8 = undefined;
    const r = s.next(&buf).?;
    try std.testing.expectEqualStrings("close", r.line);
    r.close();
    try std.testing.expect(s.next(&buf) == null);
    // nobody answers: null after the wait
    try std.testing.expect(request(p, "status", &ans, 50) == null);
    s.next(&buf).?.close();
}

test "liveness: a live socket is kept, a stale one taken over" {
    const gpa = std.testing.allocator;
    const dir = try testDir(gpa);
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    var pbuf: PathBuf = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/live.sock", .{dir});
    try std.testing.expect(!alive(p));
    var first = try Server.listen(p);
    try std.testing.expect(alive(p));
    // the probe's empty connection is dropped, not taken as a request
    var buf: [64]u8 = undefined;
    try std.testing.expect(first.next(&buf) == null);
    // a second instance must not steal it
    try std.testing.expectError(error.AddressInUse, Server.listen(p));
    try std.testing.expect(alive(p));
    // the first one dies without cleaning up: its file stays, stale
    sys.close(first.fd);
    try std.testing.expect(!alive(p));
    try std.testing.expectError(error.AddressInUse, sys.listenUnix(p));
    var second = try Server.listen(p);
    defer second.close();
    try std.testing.expect(alive(p));
}

test "close removes the socket file" {
    const gpa = std.testing.allocator;
    const dir = try testDir(gpa);
    defer gpa.free(dir);
    defer sys.removeTree(dir);
    var pbuf: PathBuf = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/c.sock", .{dir});
    var s = try Server.listen(p);
    s.close();
    s.close();
    try std.testing.expect(!alive(p));
    const long: [200]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, Server.listen(&long));
}
