//! A bus connection: connect and authenticate, send calls, signals and
//! replies, wait for replies, and the org.freedesktop.DBus helpers.

const std = @import("std");
const sys = @import("../sys.zig");
const Marshal = @import("marshal.zig").Marshal;
const message = @import("message.zig");
const Message = message.Message;
const address = @import("address.zig");
const auth = @import("auth.zig");
const transport = @import("transport.zig");
const errors = @import("errors.zig");
const Reader = @import("reader.zig").Reader;
const Value = @import("reader.zig").Value;

pub const properties_iface = "org.freedesktop.DBus.Properties";

/// A property read with Connection.getProperty: its value when it is a
/// simple type (.other otherwise: read the variant with reader()).
pub const Property = struct {
    reply: Message,
    value: Value,

    /// Reader at the variant (its signature first).
    pub fn reader(self: *const Property) Reader {
        return self.reply.reader();
    }

    pub fn deinit(self: *Property, alloc: std.mem.Allocator) void {
        self.reply.deinit(alloc);
    }
};

/// The bus's NameOwnerChanged signal: a name got a new owner (empty
/// `new_owner`: it is gone).
pub const NameOwnerChange = struct { name: []const u8, old_owner: []const u8, new_owner: []const u8 };

/// NameOwnerChanged read from `msg`; null for any other message.
pub fn nameOwnerChange(msg: *const Message) ?NameOwnerChange {
    if (!msg.isSignal("org.freedesktop.DBus", "NameOwnerChanged")) return null;
    var r = msg.reader();
    const name = r.readString() catch return null;
    const old_owner = r.readString() catch return null;
    const new_owner = r.readString() catch return null;
    return .{ .name = name, .old_owner = old_owner, .new_owner = new_owner };
}

const default_reply_timeout_ms = transport.default_reply_timeout_ms;

pub const Connection = struct {
    fd: sys.fd_t,
    alloc: std.mem.Allocator,
    serial: u32 = 1,
    unique_name: []u8 = &.{},
    /// messages received while waiting for a specific reply
    pending: std.ArrayList(Message) = .empty,
    /// fds received via SCM_RIGHTS (consumed in arrival order)
    in_fds: std.ArrayList(sys.fd_t) = .empty,
    unix_fd_ok: bool = false,
    /// hashes of match rules already added, so helpers can call addMatchOnce
    matches: [16]u64 = @splat(0),
    n_matches: usize = 0,

    /// `addr_env` is the value of DBUS_SESSION_BUS_ADDRESS: a `;`-separated
    /// list tried in order. Supports unix:path= and unix:abstract=, with
    /// percent-escaped values.
    pub fn connectSession(alloc: std.mem.Allocator, addr_env: []const u8) !Connection {
        var buf: [2048]u8 = undefined;
        var list: [8]address.Address = undefined;
        const addrs = try address.parseAddresses(addr_env, &buf, &list);
        if (addrs.len == 0) return error.UnsupportedBusAddress;
        var last_err: anyerror = error.UnsupportedBusAddress;
        for (addrs) |addr| {
            const fd = try sys.socketUnixStream();
            connectAddress(fd, addr) catch |err| {
                sys.close(fd);
                last_err = err;
                continue;
            };
            return fromFd(alloc, fd);
        }
        return last_err;
    }

    fn connectAddress(fd: sys.fd_t, addr: address.Address) !void {
        return switch (addr) {
            .path => |p| sys.connectUnix(fd, p),
            .abstract => |name| sys.connectUnixAbstract(fd, name),
        };
    }

    /// Authenticate and say Hello over an already connected socket. Takes
    /// ownership of fd (closed on error).
    pub fn fromFd(alloc: std.mem.Allocator, fd: sys.fd_t) !Connection {
        var self = Connection{ .fd = fd, .alloc = alloc };
        errdefer self.deinit();
        self.unix_fd_ok = try auth.authenticate(fd, default_reply_timeout_ms);
        try self.hello();
        return self;
    }

    pub fn deinit(self: *Connection) void {
        for (self.pending.items) |*m| m.deinit(self.alloc);
        self.pending.deinit(self.alloc);
        for (self.in_fds.items) |fd| sys.close(fd);
        self.in_fds.deinit(self.alloc);
        sys.close(self.fd);
        self.alloc.free(self.unique_name);
    }

    fn hello(self: *Connection) !void {
        const serial = try self.callBus("Hello", "", &.{});
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        const name = try r.readString();
        self.unique_name = try self.alloc.dupe(u8, name);
    }

    pub fn nextSerial(self: *Connection) u32 {
        defer self.serial += 1;
        return self.serial;
    }

    /// Send a method call; returns the serial for matching the reply.
    pub fn callMethod(
        self: *Connection,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) !u32 {
        return self.callMethodFds(destination, path, interface, member, signature, body, &.{});
    }

    /// callMethod attaching file descriptors ('h' args are indexes into
    /// fds); the bus must have agreed to pass them (AGREE_UNIX_FD).
    pub fn callMethodFds(
        self: *Connection,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
        fds: []const sys.fd_t,
    ) !u32 {
        if (fds.len > 0 and !self.unix_fd_ok) return error.NoFdPassing;
        const serial = self.nextSerial();
        try transport.sendMessageFds(self, .method_call, serial, .{
            .path = path,
            .interface = interface,
            .member = member,
            .destination = destination,
            .signature = signature,
        }, body, null, fds);
        return serial;
    }

    pub fn emitSignal(
        self: *Connection,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) !void {
        try transport.sendMessage(self, .signal, self.nextSerial(), .{
            .path = path,
            .interface = interface,
            .member = member,
            .signature = signature,
        }, body, null);
    }

    pub fn replyTo(self: *Connection, request: *const Message, signature: []const u8, body: []const u8) !void {
        try self.replyToWithFds(request, signature, body, &.{});
    }

    /// Reply attaching file descriptors ('h' args are indexes into fds).
    pub fn replyToWithFds(self: *Connection, request: *const Message, signature: []const u8, body: []const u8, fds: []const sys.fd_t) !void {
        try transport.sendMessageFds(self, .method_return, self.nextSerial(), .{
            .destination = request.sender,
            .signature = signature,
        }, body, request.serial, fds);
    }

    pub fn replyError(self: *Connection, request: *const Message, error_name: []const u8, text: []const u8) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(text);
        try transport.sendMessage(self, .@"error", self.nextSerial(), .{
            .destination = request.sender,
            .error_name = error_name,
            .signature = "s",
        }, m.buf.items, request.serial);
    }

    /// Blocking read of the next complete message.
    pub fn readMessage(self: *Connection) !Message {
        return (try self.readMessageDeadline(null)) orelse unreachable;
    }

    /// Read the next complete message, or null if none starts arriving
    /// before `deadline_ms` (monotonic). Malformed messages are consumed
    /// whole and reported as a non-fatal error (see isFatal).
    pub fn readMessageDeadline(self: *Connection, deadline_ms: ?i64) !?Message {
        return transport.readMessageDeadline(self, deadline_ms);
    }

    /// Call a method and wait up to `timeout_ms` for its reply. An error
    /// reply is logged once (name and message) and returned as the
    /// CallError of its kind (errors.classify).
    pub fn call(
        self: *Connection,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
        timeout_ms: i64,
    ) !Message {
        const serial = try self.callMethod(destination, path, interface, member, signature, body);
        return self.checkReply(try self.awaitReply(serial, timeout_ms), member);
    }

    /// Wait for the reply to `serial`, up to default_reply_timeout_ms.
    /// Unrelated messages (e.g. incoming method calls while we block) are
    /// queued for nextMessage, not dropped.
    pub fn waitReply(self: *Connection, serial: u32) !Message {
        return self.waitReplyTimeout(serial, default_reply_timeout_ms);
    }

    /// The reply to a call already sent (callMethodFds), as call() takes it.
    pub fn waitReplyTimeout(self: *Connection, serial: u32, timeout_ms: i64) !Message {
        return self.checkReply(try self.awaitReply(serial, timeout_ms), "reply");
    }

    /// Like waitReplyTimeout, but an error reply is returned as is (type
    /// .@"error", error_name set).
    /// TODO(wave 2): remove once record/portal_rec.zig and
    /// capture/winrects.zig call call()/waitReplyTimeout.
    pub fn waitReplyOrError(self: *Connection, serial: u32, timeout_ms: i64) !Message {
        return self.awaitReply(serial, timeout_ms);
    }

    /// A reply as is, or an error reply logged, freed and classified.
    fn checkReply(self: *Connection, reply: Message, what: []const u8) errors.CallError!Message {
        if (reply.type != .@"error") return reply;
        var msg = reply;
        defer msg.deinit(self.alloc);
        const name = msg.error_name orelse "?";
        var r = msg.reader();
        const has_text = msg.signature != null and std.mem.startsWith(u8, msg.signature.?, "s");
        const text = if (has_text) r.readString() catch "" else "";
        std.log.info("dbus {s}: {s} ({s})", .{ what, name, text });
        return errors.toError(errors.classify(name));
    }

    /// Read until the message replying to `serial` arrives (whatever its
    /// type); everything else stays queued.
    fn awaitReply(self: *Connection, serial: u32, timeout_ms: i64) !Message {
        const isReply = struct {
            fn f(s: u32, m: *const Message) bool {
                return m.reply_serial == s;
            }
        }.f;
        return (try self.waitFor(sys.monoMs() + timeout_ms, serial, isReply)) orelse error.Timeout;
    }

    /// Wait until `deadline_ms` (monotonic; null: no deadline) for the
    /// message `match(ctx, msg)` accepts: queued messages first, then the
    /// socket. Every message it does not take is queued for later readers
    /// (nextMessage, other waits), never dropped; malformed ones are
    /// skipped. Null when the deadline passes first.
    pub fn waitFor(self: *Connection, deadline_ms: ?i64, ctx: anytype, comptime match: fn (@TypeOf(ctx), *const Message) bool) !?Message {
        for (self.pending.items, 0..) |*m, i| {
            if (match(ctx, m)) return self.pending.orderedRemove(i);
        }
        while (true) {
            var msg = (self.readMessageDeadline(deadline_ms) catch |err| {
                if (transport.isFatal(err)) return err;
                std.log.warn("dropped malformed bus message: {t}", .{err});
                continue;
            }) orelse return null;
            if (match(ctx, &msg)) return msg;
            self.pending.append(self.alloc, msg) catch msg.deinit(self.alloc);
        }
    }

    /// Handle what has already arrived, without waiting: up to `max`
    /// messages, queued ones first. `handler(ctx, msg)` returns true when
    /// it kept the message (took ownership); the others are freed. Stops
    /// at the first read error.
    pub fn drain(self: *Connection, max: usize, ctx: anytype, comptime handler: fn (@TypeOf(ctx), *const Message) bool) void {
        var n: usize = 0;
        while (n < max) : (n += 1) {
            var msg = (self.nextMessageDeadline(sys.monoMs()) catch return) orelse return;
            if (!handler(ctx, &msg)) msg.deinit(self.alloc);
        }
    }

    /// Read property `name` of `interface` on an object (Properties.Get).
    pub fn getProperty(
        self: *Connection,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        name: []const u8,
        timeout_ms: i64,
    ) !Property {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(interface);
        try m.putString(name);
        var reply = try self.call(destination, path, properties_iface, "Get", "ss", m.buf.items, timeout_ms);
        errdefer reply.deinit(self.alloc);
        var r = reply.reader();
        const value = try r.readVariant();
        return .{ .reply = reply, .value = value };
    }

    /// Next message: drains the pending queue before reading the socket.
    pub fn nextMessage(self: *Connection) !Message {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return self.readMessage();
    }

    /// Like nextMessage, but returns null when nothing arrives before
    /// `deadline_ms` (monotonic).
    pub fn nextMessageDeadline(self: *Connection, deadline_ms: ?i64) !?Message {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return self.readMessageDeadline(deadline_ms);
    }

    /// True if a queued or buffered message may be available without blocking.
    pub fn hasPending(self: *const Connection) bool {
        return self.pending.items.len > 0;
    }

    /// Call a method of the bus itself (org.freedesktop.DBus).
    fn callBus(self: *Connection, member: []const u8, signature: []const u8, body: []const u8) !u32 {
        return self.callMethod("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", member, signature, body);
    }

    /// addMatch, skipped when this connection already added the same rule.
    pub fn addMatchOnce(self: *Connection, rule: []const u8) !void {
        const h = std.hash.Wyhash.hash(0, rule);
        for (self.matches[0..self.n_matches]) |m| if (m == h) return;
        try self.addMatch(rule);
        if (self.n_matches < self.matches.len) {
            self.matches[self.n_matches] = h;
            self.n_matches += 1;
        }
    }

    /// Hear NameOwnerChanged for `name` (nameOwnerChange reads it).
    pub fn watchNameOwner(self: *Connection, name: []const u8) !void {
        var buf: [320]u8 = undefined;
        const rule = try std.fmt.bufPrint(&buf, "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='{s}'", .{name});
        try self.addMatchOnce(rule);
    }

    pub fn addMatch(self: *Connection, rule: []const u8) !void {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(rule);
        const serial = try self.callBus("AddMatch", "s", m.buf.items);
        var reply = try self.waitReply(serial);
        reply.deinit(self.alloc);
    }

    pub fn nameHasOwner(self: *Connection, name: []const u8) !bool {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(name);
        const serial = try self.callBus("NameHasOwner", "s", m.buf.items);
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        return (try r.readU32()) != 0;
    }

    /// Request a well-known name (DO_NOT_QUEUE). Returns true if we are
    /// the primary owner; false means another instance already holds it.
    pub fn requestName(self: *Connection, name: []const u8) !bool {
        var m = Marshal.init(self.alloc);
        defer m.deinit();
        try m.putString(name);
        try m.putU32(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
        const serial = try self.callBus("RequestName", "su", m.buf.items);
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.alloc);
        var r = reply.reader();
        const code = try r.readU32();
        return code == 1; // PRIMARY_OWNER
    }
};

// --- tests

const testing = std.testing;

/// Two ends of one socket, as if each were the other's bus.
fn testPair() ![2]Connection {
    const fds = try sys.socketPair();
    return .{ .{ .fd = fds[0], .alloc = testing.allocator }, .{ .fd = fds[1], .alloc = testing.allocator } };
}

fn isMember(member: []const u8, m: *const Message) bool {
    return m.member != null and std.mem.eql(u8, m.member.?, member);
}

test "waitFor takes its message and queues every other one" {
    var pair = try testPair();
    defer for (&pair) |*c| c.deinit();
    const peer = &pair[0];
    const ours = &pair[1];
    for ([_][]const u8{ "One", "Two", "Three" }) |name| try peer.emitSignal("/t", "org.example", name, "", &.{});

    const soon = sys.monoMs() + 1000;
    var two = (try ours.waitFor(soon, @as([]const u8, "Two"), isMember)).?;
    two.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), ours.pending.items.len); // One
    // nothing matches: the deadline passes and nothing is lost
    try testing.expectEqual(@as(?Message, null), try ours.waitFor(sys.monoMs() + 20, @as([]const u8, "Nope"), isMember));
    try testing.expectEqual(@as(usize, 2), ours.pending.items.len); // One, Three
    // a queued message is found without reading
    var three = (try ours.waitFor(soon, @as([]const u8, "Three"), isMember)).?;
    three.deinit(testing.allocator);
    var one = try ours.nextMessage();
    defer one.deinit(testing.allocator);
    try testing.expectEqualStrings("One", one.member.?);
    try testing.expect(!ours.hasPending());
}

test "drain handles at most max messages, queued ones first" {
    var pair = try testPair();
    defer for (&pair) |*c| c.deinit();
    const peer = &pair[0];
    const ours = &pair[1];
    for ([_][]const u8{ "A", "B", "C" }) |name| try peer.emitSignal("/t", "org.example", name, "", &.{});
    // queue A and B by waiting for C; D stays on the socket
    var c = (try ours.waitFor(sys.monoMs() + 1000, @as([]const u8, "C"), isMember)).?;
    c.deinit(testing.allocator);
    try peer.emitSignal("/t", "org.example", "D", "", &.{});

    const Seen = struct {
        names: [4]u8 = undefined,
        n: usize = 0,
        fn take(self: *@This(), m: *const Message) bool {
            self.names[self.n] = m.member.?[0];
            self.n += 1;
            return false;
        }
    };
    var seen: Seen = .{};
    ours.drain(2, &seen, Seen.take);
    try testing.expectEqualStrings("AB", seen.names[0..seen.n]);
    ours.drain(16, &seen, Seen.take);
    try testing.expectEqualStrings("ABD", seen.names[0..seen.n]);
    ours.drain(16, &seen, Seen.take); // nothing left: returns at once
    try testing.expectEqual(@as(usize, 3), seen.n);
}

test "call returns an error reply as its kind" {
    var pair = try testPair();
    defer for (&pair) |*c| c.deinit();
    const peer = &pair[0];
    const ours = &pair[1];
    const saved_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_level;
    // the reply is waiting before the call goes out (serials are predictable)
    const Case = struct { name: []const u8, want: anyerror };
    for ([_]Case{
        .{ .name = "dev.shotlet.Shell1.Error.Busy", .want = error.Busy },
        .{ .name = "org.freedesktop.DBus.Error.ServiceUnknown", .want = error.ServiceUnknown },
        .{ .name = "org.freedesktop.portal.Error.Failed", .want = error.DBusError },
    }) |case| {
        const fake: Message = .{ .type = .method_call, .serial = ours.serial };
        try peer.replyError(&fake, case.name, "no");
        try testing.expectError(case.want, ours.call("org.example", "/t", "org.example", "Do", "", &.{}, 1000));
    }
    try testing.expectError(error.Timeout, ours.call("org.example", "/t", "org.example", "Do", "", &.{}, 20));
}

test "NameOwnerChanged is read; other messages are not" {
    var m = Marshal.init(testing.allocator);
    defer m.deinit();
    for ([_][]const u8{ "org.kde.StatusNotifierWatcher", ":1.4", "" }) |s| try m.putString(s);
    var msg: Message = .{ .type = .signal, .serial = 3, .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .body = m.buf.items };
    const c = nameOwnerChange(&msg).?;
    try testing.expectEqualStrings("org.kde.StatusNotifierWatcher", c.name);
    try testing.expectEqualStrings(":1.4", c.old_owner);
    try testing.expectEqual(@as(usize, 0), c.new_owner.len);
    msg.member = "NameLost";
    try testing.expectEqual(@as(?NameOwnerChange, null), nameOwnerChange(&msg));
    msg.member = "NameOwnerChanged";
    msg.body = m.buf.items[0..8]; // truncated
    try testing.expectEqual(@as(?NameOwnerChange, null), nameOwnerChange(&msg));
}
