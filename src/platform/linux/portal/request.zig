//! Request-style portal calls: the method call, its Request object and
//! the Response signal that may take as long as a person looking at a
//! dialog. Every wait has a deadline, watches the portal's bus name so a
//! crashed portal fails fast, and reports an explicit Outcome.

const std = @import("std");
const log = std.log.scoped(.portal);
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const screencast = @import("screencast.zig"); // test fixtures

pub const Outcome = enum {
    /// the request succeeded (response 0)
    granted,
    /// the person dismissed the dialog (response 1)
    cancelled,
    /// refused by the portal or a stored permission (response 2, NotAllowed)
    denied,
    /// no portal, no such interface, or the portal went away mid-request
    unavailable,
    /// no answer before the deadline; the request was closed
    timeout,
};

/// Either the granted value or why there is none.
pub fn Result(comptime T: type) type {
    return union(Outcome) {
        granted: T,
        cancelled,
        denied,
        unavailable,
        timeout,
    };
}

/// Carry a not-granted outcome over to another Result type.
pub fn notGranted(comptime T: type, o: Outcome) Result(T) {
    return switch (o) {
        .granted => unreachable,
        .cancelled => .cancelled,
        .denied => .denied,
        .unavailable => .unavailable,
        .timeout => .timeout,
    };
}

/// A consent dialog may be on screen: a person may take a long time to
/// decide (or step away), so only give up after this long. A portal that
/// never accepts the call, or exits, still fails fast (see Request.wait).
pub const timeout_dialog_ms: i64 = 10 * 60_000;
/// A windowless Screenshot request: GNOME only shows its consent dialog to
/// the focused app, so with permission the answer is quick and without it
/// no dialog can come (GNOME 48 then never answers at all when no app has
/// focus, leaving the call to dbus' 25 s timeout).
pub const timeout_unfocused_screenshot_ms: i64 = 5_000;
/// Calls that never show UI. Long enough to cover the portal being
/// started by bus activation, which dbus itself bounds at 25 s.
pub const timeout_quick_ms: i64 = 30_000;
/// Picking a file name and folder can reasonably take a while.
pub const timeout_file_chooser_ms: i64 = 15 * 60_000;

pub const bus_name = "org.freedesktop.portal.Desktop";
pub const object_path = "/org/freedesktop/portal/desktop";

/// Subscribe to Response signals and to the portal's bus name changing
/// owner (once per connection).
pub fn watch(bus: *dbus.Connection) !void {
    try bus.addMatchOnce("type='signal',interface='" ++ request_iface ++ "',member='Response'");
    try bus.watchNameOwner(bus_name);
}

const request_iface = "org.freedesktop.portal.Request";

/// One in-flight request-style portal call. Feed it bus messages with
/// handle(), pump it with step(), or block in wait().
pub const Request = struct {
    serial: u32,
    /// object path of the Request; Response signals arrive on it
    path: []u8,
    /// method name, for log lines (static string)
    what: []const u8,
    /// when the call went out (monotonic): the deadlines count from here
    started_ms: i64 = 0,
    got_reply: bool = false,
    outcome: ?Outcome = null,
    /// the Response signal when granted; its body is "ua{sv}"
    response: ?dbus.Message = null,

    pub fn start(
        gpa: std.mem.Allocator,
        bus: *dbus.Connection,
        iface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
        handle_token: []const u8,
    ) !Request {
        try watch(bus);
        var path_buf: [256]u8 = undefined;
        const path = try gpa.dupe(u8, try senderPath(bus, &path_buf, "request", handle_token));
        errdefer gpa.free(path);
        const serial = try bus.callMethod(bus_name, object_path, iface, member, signature, body);
        return .{ .serial = serial, .path = path, .what = member, .started_ms = sys.monoMs() };
    }

    pub fn deinit(self: *Request, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        if (self.response) |*m| m.deinit(gpa);
        self.* = undefined;
    }

    pub fn done(self: *const Request) bool {
        return self.outcome != null;
    }

    /// Whether `msg` belongs to this request: the method reply, a
    /// Response on its path, the portal's bus name changing owner.
    pub fn concerns(self: *const Request, msg: *const dbus.Message) bool {
        if (self.isMethodReply(msg)) return true;
        if (dbus.nameOwnerChange(msg)) |c| return std.mem.eql(u8, c.name, bus_name);
        if (!msg.isSignal(request_iface, "Response")) return false;
        const path = msg.path orelse return false;
        return std.mem.eql(u8, path, self.path);
    }

    fn isMethodReply(self: *const Request, msg: *const dbus.Message) bool {
        return !self.got_reply and msg.reply_serial == self.serial and
            (msg.type == .method_return or msg.type == .@"error");
    }

    /// Look at one message. Returns true when it kept the message (it was
    /// the granted Response; ownership moved into self.response), false
    /// when the caller still owns it.
    pub fn handle(self: *Request, gpa: std.mem.Allocator, msg: *const dbus.Message) !bool {
        if (self.outcome != null) return false;
        if (self.isMethodReply(msg)) {
            try self.handleMethodReply(gpa, msg);
            return false;
        }
        if (dbus.nameOwnerChange(msg)) |c| {
            if (std.mem.eql(u8, c.name, bus_name) and c.new_owner.len == 0) {
                log.warn("the desktop portal exited during {s}", .{self.what});
                self.outcome = .unavailable;
            }
            return false;
        }
        if (msg.isSignal(request_iface, "Response")) return self.handleResponse(msg);
        return false;
    }

    /// The method call's reply: an error ends the request, a return
    /// carries the Request object path.
    fn handleMethodReply(self: *Request, gpa: std.mem.Allocator, msg: *const dbus.Message) !void {
        if (msg.type == .@"error") {
            const name = msg.error_name orelse "?";
            log.warn("portal {s} failed: {s}", .{ self.what, name });
            self.outcome = if (dbus.classify(name) == .denied) .denied else .unavailable;
            return;
        }
        var r = msg.reader();
        const handle_path = r.readString() catch {
            self.outcome = .unavailable;
            return;
        };
        // portals older than 0.9 do not use the predicted path
        if (!std.mem.eql(u8, handle_path, self.path)) {
            const copy = try gpa.dupe(u8, handle_path);
            gpa.free(self.path);
            self.path = copy;
        }
        self.got_reply = true;
    }

    /// A Response signal on our path sets the outcome; a granted one is
    /// kept (returns true).
    fn handleResponse(self: *Request, msg: *const dbus.Message) bool {
        const path = msg.path orelse return false;
        if (!std.mem.eql(u8, path, self.path)) return false;
        if (msg.signature == null or !std.mem.eql(u8, msg.signature.?, "ua{sv}")) {
            log.warn("portal {s}: malformed Response", .{self.what});
            self.outcome = .unavailable;
            return false;
        }
        var r = msg.reader();
        const code = r.readU32() catch {
            self.outcome = .unavailable;
            return false;
        };
        self.outcome = switch (code) {
            0 => .granted,
            1 => .cancelled,
            else => .denied,
        };
        if (code != 0) return false;
        self.response = msg.*;
        return true;
    }

    /// handle() a message this request took off the bus, freeing it
    /// unless it was kept.
    fn take(self: *Request, gpa: std.mem.Allocator, msg: *dbus.Message) void {
        const kept = self.handle(gpa, msg) catch false;
        if (!kept) msg.deinit(gpa);
    }

    /// When the request gives up: the portal must accept the call (reply
    /// with the Request handle) within timeout_quick_ms, else it counts
    /// as unavailable: only then can a dialog be on screen, and only then
    /// is the wait of `timeout_ms` worth it.
    fn deadline(self: *const Request, timeout_ms: i64) i64 {
        return self.started_ms + if (self.got_reply) timeout_ms else @min(timeout_ms, timeout_quick_ms);
    }

    /// The deadline passed without an outcome.
    fn expire(self: *Request, bus: *dbus.Connection, timeout_ms: i64) void {
        if (!self.got_reply) {
            log.warn("portal {s}: no reply from the portal; giving up", .{self.what});
            self.outcome = .unavailable;
            return;
        }
        log.warn("portal {s}: no answer after {d} min; giving up", .{ self.what, @divTrunc(timeout_ms, 60_000) });
        self.close(bus);
        self.outcome = .timeout;
    }

    /// Pump the connection until the request finishes or its deadline
    /// passes (see deadline). Messages for anyone else stay queued on
    /// the connection, never dropped.
    pub fn wait(self: *Request, gpa: std.mem.Allocator, bus: *dbus.Connection, timeout_ms: i64) !void {
        while (self.outcome == null) {
            const until = self.deadline(timeout_ms);
            var msg = (try bus.waitFor(until, @as(*const Request, self), concerns)) orelse {
                if (sys.monoMs() >= until) self.expire(bus, timeout_ms);
                continue;
            };
            self.take(gpa, &msg);
        }
    }

    /// Without blocking: handle what already arrived for this request,
    /// then apply wait()'s deadlines. The outcome, once there is one. For
    /// loops that also serve a window.
    pub fn step(self: *Request, gpa: std.mem.Allocator, bus: *dbus.Connection, timeout_ms: i64) !?Outcome {
        while (self.outcome == null) {
            var msg = (try bus.waitFor(sys.monoMs(), @as(*const Request, self), concerns)) orelse break;
            self.take(gpa, &msg);
        }
        if (self.outcome == null and sys.monoMs() >= self.deadline(timeout_ms)) self.expire(bus, timeout_ms);
        return self.outcome;
    }

    /// Dismiss whatever dialog belongs to this request. Fire-and-forget.
    pub fn close(self: *const Request, bus: *dbus.Connection) void {
        _ = bus.callMethod(bus_name, self.path, request_iface, "Close", "", &.{}) catch {};
    }

    /// Reader over the granted Response's results dict (after the code).
    pub fn results(self: *const Request) !dbus.Reader {
        const msg = &(self.response orelse return error.NoResponse);
        var r = msg.reader();
        _ = try r.readU32();
        return r;
    }
};

/// start() + wait(): the finished request (caller deinits).
pub fn call(
    gpa: std.mem.Allocator,
    bus: *dbus.Connection,
    iface: []const u8,
    member: []const u8,
    signature: []const u8,
    body: []const u8,
    handle_token: []const u8,
    timeout_ms: i64,
) !Request {
    var req = try Request.start(gpa, bus, iface, member, signature, body, handle_token);
    errdefer req.deinit(gpa);
    try req.wait(gpa, bus, timeout_ms);
    return req;
}

fn senderPath(bus: *const dbus.Connection, buf: []u8, kind: []const u8, token: []const u8) ![]u8 {
    var sender_buf: [64]u8 = undefined;
    var n: usize = 0;
    for (bus.unique_name) |c| {
        if (c == ':') continue;
        if (n == sender_buf.len) return error.NameTooLong;
        sender_buf[n] = if (c == '.') '_' else c;
        n += 1;
    }
    return std.fmt.bufPrint(buf, "/org/freedesktop/portal/desktop/{s}/{s}/{s}", .{ kind, sender_buf[0..n], token });
}

fn fakeSignal(body: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8) dbus.Message {
    return .{ .type = .signal, .serial = 99, .path = path, .interface = iface, .member = member, .signature = sig, .body = body };
}

test "Request outcomes from Response codes, errors and a vanished portal" {
    const gpa = std.testing.allocator;
    // the failures below are expected; keep their warnings out of the output
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    const path = "/org/freedesktop/portal/desktop/request/1_5/tok";

    const Case = struct { code: u32, want: Outcome };
    for ([_]Case{
        .{ .code = 0, .want = .granted },
        .{ .code = 1, .want = .cancelled },
        .{ .code = 2, .want = .denied },
    }) |c| {
        var req = Request{ .serial = 7, .path = try gpa.dupe(u8, path), .what = "Start" };
        defer req.deinit(gpa);
        var m = dbus.Marshal.init(gpa);
        defer m.deinit();
        try screencast.startResponseBody(&m, c.code, "s");

        // a Response for someone else's request changes nothing
        var other = fakeSignal(m.buf.items, "/elsewhere", "org.freedesktop.portal.Request", "Response", "ua{sv}");
        try std.testing.expect(!try req.handle(gpa, &other));
        try std.testing.expect(req.outcome == null);

        const raw = try gpa.dupe(u8, m.buf.items);
        var sig = fakeSignal(raw, path, "org.freedesktop.portal.Request", "Response", "ua{sv}");
        sig.raw = raw;
        const kept = try req.handle(gpa, &sig);
        if (!kept) sig.deinit(gpa);
        try std.testing.expectEqual(c.want, req.outcome.?);
        try std.testing.expectEqual(c.code == 0, kept);
        if (c.code == 0) {
            var r = try req.results();
            var st = try screencast.parseStartResults(gpa, &r);
            st.deinit(gpa);
        }
    }

    // malformed Response signature: unavailable, not misread
    {
        var req = Request{ .serial = 7, .path = try gpa.dupe(u8, path), .what = "Start" };
        defer req.deinit(gpa);
        var bad = fakeSignal(&.{ 0, 0, 0, 0 }, path, "org.freedesktop.portal.Request", "Response", "u");
        try std.testing.expect(!try req.handle(gpa, &bad));
        try std.testing.expectEqual(Outcome.unavailable, req.outcome.?);
    }

    // the portal loses its bus name mid-request
    {
        var req = Request{ .serial = 7, .path = try gpa.dupe(u8, path), .what = "Start" };
        defer req.deinit(gpa);
        var m = dbus.Marshal.init(gpa);
        defer m.deinit();
        try m.putString(bus_name);
        try m.putString(":1.5");
        try m.putString("");
        var noc = fakeSignal(m.buf.items, "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged", "sss");
        _ = try req.handle(gpa, &noc);
        try std.testing.expectEqual(Outcome.unavailable, req.outcome.?);
    }

    // an error reply: NotAllowed is a denial, anything else unavailable
    for ([_]struct { name: []const u8, want: Outcome }{
        .{ .name = "org.freedesktop.portal.Error.NotAllowed", .want = .denied },
        .{ .name = "org.freedesktop.DBus.Error.UnknownMethod", .want = .unavailable },
    }) |c| {
        var req = Request{ .serial = 7, .path = try gpa.dupe(u8, path), .what = "Start" };
        defer req.deinit(gpa);
        var e = dbus.Message{ .type = .@"error", .serial = 3, .reply_serial = 7, .error_name = c.name };
        _ = try req.handle(gpa, &e);
        try std.testing.expectEqual(c.want, req.outcome.?);
    }

    // the method reply may name a different request path (old portals)
    {
        var req = Request{ .serial = 7, .path = try gpa.dupe(u8, path), .what = "Start" };
        defer req.deinit(gpa);
        var m = dbus.Marshal.init(gpa);
        defer m.deinit();
        try m.putObjectPath("/other/request");
        var reply = dbus.Message{ .type = .method_return, .serial = 3, .reply_serial = 7, .signature = "o", .body = m.buf.items };
        _ = try req.handle(gpa, &reply);
        try std.testing.expectEqualStrings("/other/request", req.path);
        try std.testing.expect(req.outcome == null);
    }
}

test "a request takes only its own messages; the rest stay queued" {
    const gpa = std.testing.allocator;
    const fds = try sys.socketPair();
    var peer: dbus.Connection = .{ .fd = fds[0], .alloc = gpa };
    defer peer.deinit();
    var ours: dbus.Connection = .{ .fd = fds[1], .alloc = gpa };
    defer ours.deinit();
    const path = "/org/freedesktop/portal/desktop/request/1_5/tok";
    var req = Request{ .serial = 7, .path = try gpa.dupe(u8, path), .what = "Start", .got_reply = true, .started_ms = sys.monoMs() };
    defer req.deinit(gpa);

    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try screencast.startResponseBody(&m, 1, "s");
    // someone else's Response, an unrelated signal, then ours
    try peer.emitSignal("/org/freedesktop/portal/desktop/request/1_5/other", request_iface, "Response", "ua{sv}", m.buf.items);
    try peer.emitSignal("/t", "org.example", "Changed", "", &.{});
    try std.testing.expectEqual(@as(?Outcome, null), try req.step(gpa, &ours, timeout_dialog_ms));
    try peer.emitSignal(path, request_iface, "Response", "ua{sv}", m.buf.items);
    try req.wait(gpa, &ours, timeout_dialog_ms);
    try std.testing.expectEqual(Outcome.cancelled, req.outcome.?);
    try std.testing.expectEqual(@as(usize, 2), ours.pending.items.len);
    try std.testing.expectEqualStrings("Response", ours.pending.items[0].member.?);
    try std.testing.expectEqualStrings("Changed", ours.pending.items[1].member.?);
}

test "a request past its deadline gives up" {
    const gpa = std.testing.allocator;
    const saved_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_level;
    const fds = try sys.socketPair();
    var peer: dbus.Connection = .{ .fd = fds[0], .alloc = gpa };
    defer peer.deinit();
    var ours: dbus.Connection = .{ .fd = fds[1], .alloc = gpa };
    defer ours.deinit();
    // never accepted by the portal: unavailable after timeout_quick_ms
    var mute = Request{ .serial = 7, .path = try gpa.dupe(u8, "/r/1"), .what = "Start", .started_ms = sys.monoMs() - timeout_quick_ms };
    defer mute.deinit(gpa);
    try std.testing.expectEqual(Outcome.unavailable, (try mute.step(gpa, &ours, timeout_dialog_ms)).?);
    // accepted, never answered: closed, timeout
    var silent = Request{ .serial = 8, .path = try gpa.dupe(u8, "/r/2"), .what = "Start", .got_reply = true, .started_ms = sys.monoMs() - 50 };
    defer silent.deinit(gpa);
    try std.testing.expectEqual(@as(?Outcome, null), try silent.step(gpa, &ours, 1000));
    try std.testing.expectEqual(Outcome.timeout, (try silent.step(gpa, &ours, 10)).?);
    var close = try peer.readMessage();
    defer close.deinit(gpa);
    try std.testing.expectEqualStrings("Close", close.member.?);
}
