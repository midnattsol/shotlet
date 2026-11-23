//! org.freedesktop.portal.ScreenCast: a session over every monitor
//! (create, select + start, open the PipeWire remote), the streams it
//! hands out, and its restore token. Screenshots keep one for a single
//! grab, recordings for the whole recording.

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const request = @import("request.zig");

const Outcome = request.Outcome;
const Result = request.Result;
const notGranted = request.notGranted;
const iface = "org.freedesktop.portal.ScreenCast";

/// cursor_mode values (AvailableCursorModes is a mask of them)
pub const cursor_hidden: u32 = 1;
pub const cursor_embedded: u32 = 2;

/// One captured monitor, as the portal describes it.
pub const Stream = struct {
    node_id: u32,
    /// top-left in the compositor's logical layout
    position: ?[2]i32 = null,
    /// logical size (not pixels: a 2x monitor reports half its pixel size)
    size: ?[2]i32 = null,
    source_type: u32 = 0,
};

/// What Start started: the streams and a restore token.
pub const Started = struct {
    streams: []Stream,
    /// new restore token to persist for silent future sessions (owned)
    restore_token: ?[]u8 = null,

    pub fn deinit(self: *Started, alloc: std.mem.Allocator) void {
        alloc.free(self.streams);
        if (self.restore_token) |t| alloc.free(t);
        self.* = undefined;
    }
};

/// How SelectSources asks: every monitor, persisted until revoked.
pub const SelectOptions = struct {
    /// cursor_hidden for screenshots; recordings embed it when they can
    /// (availableCursorModes)
    cursor_mode: u32 = cursor_hidden,
    /// a previous session's token: no picker while it still matches
    restore_token: ?[]const u8 = null,
};

/// An open ScreenCast session.
pub const Session = struct {
    /// the portal's session object
    path: []u8,
    start: Started,
    /// the PipeWire remote; whoever streams from it owns it
    /// (pw.grabFrames, pwstream.Capture.open), never closed here
    fd: sys.fd_t,
    ended: bool = false,

    /// Close the portal session (GNOME's screen-sharing indicator goes
    /// away). Once; fire-and-forget.
    pub fn end(self: *Session, bus: *dbus.Connection) void {
        if (self.ended) return;
        self.ended = true;
        _ = bus.callMethod(request.bus_name, self.path, "org.freedesktop.portal.Session", "Close", "", &.{}) catch {};
    }

    /// end(), then free it.
    pub fn close(self: *Session, alloc: std.mem.Allocator, bus: *dbus.Connection) void {
        self.end(bus);
        alloc.free(self.path);
        self.start.deinit(alloc);
        self.* = undefined;
    }
};

/// Open a session over every monitor: create, select + start, open the
/// PipeWire remote. With a valid restore token this is silent; otherwise
/// the compositor shows its source picker (the choice is remembered).
pub fn open(alloc: std.mem.Allocator, bus: *dbus.Connection, opts: SelectOptions) !Result(Session) {
    var session: Session = .{ .path = undefined, .start = undefined, .fd = -1 };
    session.path = switch (try scCreateSession(alloc, bus)) {
        .granted => |p| p,
        else => |o| return notGranted(Session, o),
    };
    var started = false;
    errdefer {
        session.end(bus);
        alloc.free(session.path);
        if (started) session.start.deinit(alloc);
    }
    switch (try selectAndStart(alloc, bus, session.path, opts)) {
        .granted => |st| session.start = st,
        else => |o| {
            session.end(bus);
            alloc.free(session.path);
            return notGranted(Session, o);
        },
    }
    started = true;
    session.fd = try scOpenRemote(alloc, bus, session.path);
    return .{ .granted = session };
}

/// The cursor modes the portal offers (a mask of cursor_*); 0 when it
/// does not say.
pub fn availableCursorModes(bus: *dbus.Connection) u32 {
    var prop = bus.getProperty(request.bus_name, request.object_path, iface, "AvailableCursorModes", 2000) catch return 0;
    defer prop.deinit(bus.alloc);
    return switch (prop.value) {
        .u32_ => |x| x,
        else => 0,
    };
}

// --- the stages (open() runs them; portal_test.zig drives them one by one)

/// Stage 1: create a ScreenCast session. Returns the session path (owned).
pub fn scCreateSession(alloc: std.mem.Allocator, bus: *dbus.Connection) !Result([]u8) {
    var tok_buf: [64]u8 = undefined;
    var stok_buf: [64]u8 = undefined;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    const opts = try m.beginDict();
    const tok = try opts.token("handle_token", &tok_buf, "shotlet_r");
    _ = try opts.token("session_handle_token", &stok_buf, "shotlet_s");
    opts.end();

    var req = try request.call(alloc, bus, iface, "CreateSession", "a{sv}", m.buf.items, tok, request.timeout_quick_ms);
    defer req.deinit(alloc);
    if (req.outcome.? != .granted) return notGranted([]u8, req.outcome.?);
    var r = try req.results();
    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        // spec says 's'; some versions send 'o'
        if (std.mem.eql(u8, e.key, "session_handle") and (std.mem.eql(u8, e.sig, "s") or std.mem.eql(u8, e.sig, "o")))
            return .{ .granted = try alloc.dupe(u8, try r.readString()) };
        try r.skipValue(e.sig);
    }
    return error.NoSessionHandle;
}

/// Stage 3: get the PipeWire socket fd for a started session.
pub fn scOpenRemote(alloc: std.mem.Allocator, bus: *dbus.Connection, session_path: []const u8) !sys.fd_t {
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    (try m.beginDict()).end();
    var reply = try bus.call(request.bus_name, request.object_path, iface, "OpenPipeWireRemote", "oa{sv}", m.buf.items, request.timeout_quick_ms);
    defer reply.deinit(alloc);
    return reply.takeFd() orelse error.NoPipeWireFd;
}

/// Stage 2 as screenshots ask: select every monitor, cursor hidden, and
/// start the cast. GNOME shows its picker here unless `prev_token` still
/// matches.
pub fn scSelectAndStart(alloc: std.mem.Allocator, bus: *dbus.Connection, session_path: []const u8, prev_token: ?[]const u8) !Result(Started) {
    return selectAndStart(alloc, bus, session_path, .{ .restore_token = prev_token });
}

fn selectAndStart(alloc: std.mem.Allocator, bus: *dbus.Connection, session_path: []const u8, opts: SelectOptions) !Result(Started) {
    const selected = try selectSources(alloc, bus, session_path, opts);
    if (selected != .granted) return notGranted(Started, selected);
    return startCast(alloc, bus, session_path);
}

/// SelectSources: every monitor (so the whole desktop is one capture),
/// the choice persisted until revoked.
fn selectSources(alloc: std.mem.Allocator, bus: *dbus.Connection, session_path: []const u8, opts: SelectOptions) !Outcome {
    var tok_buf: [64]u8 = undefined;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    const d = try m.beginDict();
    const tok = try d.token("handle_token", &tok_buf, "shotlet_r");
    try d.entry("types", @as(u32, 1)); // MONITOR
    try d.entry("multiple", true);
    try d.entry("cursor_mode", opts.cursor_mode);
    try d.entry("persist_mode", @as(u32, 2)); // until revoked
    if (opts.restore_token) |t| try d.entry("restore_token", t);
    d.end();

    var req = try request.call(alloc, bus, iface, "SelectSources", "oa{sv}", m.buf.items, tok, request.timeout_dialog_ms);
    defer req.deinit(alloc);
    return req.outcome.?;
}

/// Start the cast and parse what it started.
fn startCast(alloc: std.mem.Allocator, bus: *dbus.Connection, session_path: []const u8) !Result(Started) {
    var tok_buf: [64]u8 = undefined;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putObjectPath(session_path);
    try m.putString(""); // parent window
    const d = try m.beginDict();
    const tok = try d.token("handle_token", &tok_buf, "shotlet_r");
    d.end();

    var req = try request.call(alloc, bus, iface, "Start", "osa{sv}", m.buf.items, tok, request.timeout_dialog_ms);
    defer req.deinit(alloc);
    if (req.outcome.? != .granted) return notGranted(Started, req.outcome.?);
    var r = try req.results();
    return .{ .granted = try parseStartResults(alloc, &r) };
}

/// Parse the a{sv} results of ScreenCast.Start: every stream with its node
/// id, logical position and size, and the restore token. Values with an
/// unexpected signature are skipped, never misread.
pub fn parseStartResults(alloc: std.mem.Allocator, r: *dbus.Reader) !Started {
    var streams: std.ArrayList(Stream) = .empty;
    errdefer streams.deinit(alloc);
    var token: ?[]u8 = null;
    errdefer if (token) |t| alloc.free(t);

    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.key, "streams") and std.mem.eql(u8, e.sig, "a(ua{sv})")) {
            try parseStreams(alloc, r, &streams);
        } else if (std.mem.eql(u8, e.key, "restore_token") and std.mem.eql(u8, e.sig, "s")) {
            const t = try r.readString();
            if (token) |old| alloc.free(old);
            token = try alloc.dupe(u8, t);
        } else {
            try r.skipValue(e.sig);
        }
    }
    if (streams.items.len == 0) return error.NoStream;
    return .{ .streams = try streams.toOwnedSlice(alloc), .restore_token = token };
}

/// The "streams" a(ua{sv}) array; streams without a node id are dropped.
fn parseStreams(alloc: std.mem.Allocator, r: *dbus.Reader, streams: *std.ArrayList(Stream)) !void {
    const len = try r.readU32();
    r.pad(8);
    if (r.pos > r.data.len or len > r.data.len - r.pos) return error.ShortRead;
    const end = r.pos + len;
    while (r.pos < end) {
        r.pad(8);
        if (r.pos >= end) break;
        const st = try parseStream(r);
        if (st.node_id != 0) try streams.append(alloc, st);
    }
    if (r.pos != end) return error.BadArrayLength;
}

/// One (ua{sv}) stream: node id, then position, size and source_type.
fn parseStream(r: *dbus.Reader) !Stream {
    var st = Stream{ .node_id = try r.readU32() };
    var props = try r.readDictRaw();
    while (try props.next()) |p| {
        if (std.mem.eql(u8, p.sig, "(ii)") and
            (std.mem.eql(u8, p.key, "position") or std.mem.eql(u8, p.key, "size")))
        {
            r.pad(8);
            const a: i32 = @bitCast(try r.readU32());
            const b: i32 = @bitCast(try r.readU32());
            if (p.key[0] == 'p') st.position = .{ a, b } else st.size = .{ a, b };
        } else if (std.mem.eql(u8, p.key, "source_type") and std.mem.eql(u8, p.sig, "u")) {
            st.source_type = try r.readU32();
        } else {
            try r.skipValue(p.sig);
        }
    }
    if (st.size) |sz| {
        if (sz[0] <= 0 or sz[1] <= 0) st.size = null;
    }
    return st;
}

fn putStream(m: *dbus.Marshal, node: u32, pos: ?[2]i32, size: ?[2]i32) !void {
    try m.beginStruct();
    try m.putU32(node);
    const props = try m.beginArray(8);
    if (pos) |p| {
        try m.beginStruct();
        try m.putString("position");
        try m.putSignature("(ii)");
        try m.beginStruct();
        try m.putI32(p[0]);
        try m.putI32(p[1]);
    }
    if (size) |sz| {
        try m.beginStruct();
        try m.putString("size");
        try m.putSignature("(ii)");
        try m.beginStruct();
        try m.putI32(sz[0]);
        try m.putI32(sz[1]);
    }
    try m.putEntry("source_type", @as(u32, 1));
    try m.putEntry("id", "monitor-x");
    m.endArray(props);
}

/// Test fixture: the body of a Start Response (code, then {streams,
/// restore_token}); `token_sig` "s" is well-formed, anything else is not.
pub fn startResponseBody(m: *dbus.Marshal, code: u32, token_sig: []const u8) !void {
    try m.putU32(code);
    const dict = try m.beginArray(8);
    try m.beginStruct();
    try m.putString("streams");
    try m.putSignature("a(ua{sv})");
    const streams = try m.beginArray(8);
    try putStream(m, 41, .{ 0, 0 }, .{ 1280, 720 });
    try putStream(m, 42, .{ 1280, -100 }, .{ 1600, 900 });
    try putStream(m, 43, null, null);
    m.endArray(streams);
    if (std.mem.eql(u8, token_sig, "s")) {
        try m.putEntry("restore_token", "tok-1");
    } else {
        try m.putEntry("restore_token", @as(u32, 5));
    }
    m.endArray(dict);
}

test "Start results: every stream with position and size" {
    const alloc = std.testing.allocator;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try startResponseBody(&m, 0, "s");

    var r = dbus.Reader{ .data = m.buf.items, .pos = 0 };
    try std.testing.expectEqual(@as(u32, 0), try r.readU32());
    var st = try parseStartResults(alloc, &r);
    defer st.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), st.streams.len);
    try std.testing.expectEqual(@as(u32, 41), st.streams[0].node_id);
    try std.testing.expectEqual([2]i32{ 1280, -100 }, st.streams[1].position.?);
    try std.testing.expectEqual([2]i32{ 1600, 900 }, st.streams[1].size.?);
    try std.testing.expectEqual(@as(u32, 1), st.streams[1].source_type);
    try std.testing.expect(st.streams[2].position == null and st.streams[2].size == null);
    try std.testing.expectEqualStrings("tok-1", st.restore_token.?);
}

test "Start results: a restore token of the wrong type is ignored" {
    const alloc = std.testing.allocator;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try startResponseBody(&m, 0, "u");
    var r = dbus.Reader{ .data = m.buf.items, .pos = 0 };
    _ = try r.readU32();
    var st = try parseStartResults(alloc, &r);
    defer st.deinit(alloc);
    try std.testing.expect(st.restore_token == null);
    try std.testing.expectEqual(@as(usize, 3), st.streams.len);

    // truncated anywhere: an error, never a crash or a leak
    var cut: usize = 4;
    while (cut < m.buf.items.len) : (cut += 1) {
        var rr = dbus.Reader{ .data = m.buf.items[0..cut], .pos = 4 };
        if (parseStartResults(alloc, &rr)) |res| {
            var x = res;
            x.deinit(alloc);
        } else |_| {}
    }
}
