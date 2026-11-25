//! shotlet-drive: virtual keyboard and pointer for the end-to-end tests
//! on GNOME.
//!
//! Runs inside the private session of tools/e2e/session.sh (never on a real
//! desktop: it refuses to start outside the e2e sandbox, sandbox.zig). It
//! opens a org.gnome.Mutter.RemoteDesktop session plus a linked ScreenCast
//! session recording every monitor named on the command line, so absolute
//! pointer motion can target a monitor and `shot` can grab what the
//! compositor shows. Mutter ends the session when this process
//! disconnects, so it stays alive and answers the drivers' commands
//! (tools/drivers/common/commands.zig) one per line; `monitors` answers
//! the connectors, in command line order, and `film`/`cut` film a monitor
//! (drive/film.zig).

const std = @import("std");
const kit = @import("shotlet");
const dbus = kit.dbus;
const sys = kit.sys;
const common = @import("driver_common");
const loop = common.loop;
const images = common.images;
const movie = @import("drive/film.zig");
const eql = loop.eql;
const sleepMs = loop.sleepMs;

const rd_dest = "org.gnome.Mutter.RemoteDesktop";
const sc_dest = "org.gnome.Mutter.ScreenCast";
const rd_session_iface = "org.gnome.Mutter.RemoteDesktop.Session";
const sc_session_iface = "org.gnome.Mutter.ScreenCast.Session";

const Monitor = struct {
    connector: []const u8,
    stream: []u8,
    node: u32 = 0,
};

var gpa_state: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = gpa_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const vars = init.environ_map;
    common.sandbox.require(vars, "shotlet-drive", &.{.gnome});
    const bus = vars.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoBus;
    const runtime = vars.get("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;

    var conn = try dbus.Connection.connectSession(gpa, bus);
    defer conn.deinit();

    const rd_path = try createSession(gpa, &conn);
    const mons = try recordMonitors(gpa, arena, &conn, rd_path, args[1..]);
    try callVoid(&conn, rd_dest, rd_path, rd_session_iface, "Start", "", &.{});
    try waitStreams(gpa, &conn, mons);

    var d: Driver = .{ .gpa = gpa, .conn = &conn, .rd = rd_path, .mons = mons, .runtime = runtime };
    loop.reply("ok ready", .{});
    try loop.serve(&d, common.commands.run);
    callVoid(&conn, rd_dest, rd_path, rd_session_iface, "Stop", "", &.{}) catch {};
}

/// A remote desktop session (input); its object path.
fn createSession(gpa: std.mem.Allocator, conn: *dbus.Connection) ![]u8 {
    return callPath(gpa, conn, rd_dest, "/org/gnome/Mutter/RemoteDesktop", "org.gnome.Mutter.RemoteDesktop", "CreateSession", "", &.{});
}

/// A screencast session tied to the remote desktop session at `rd_path`,
/// recording each monitor in `connectors`.
fn recordMonitors(gpa: std.mem.Allocator, arena: std.mem.Allocator, conn: *dbus.Connection, rd_path: []const u8, connectors: []const [:0]const u8) ![]Monitor {
    const session_id = try getStringProp(gpa, conn, rd_dest, rd_path, rd_session_iface, "SessionId");
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    {
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("remote-desktop-session-id");
        try m.putVariantString(session_id);
        m.endArray(arr);
    }
    const sc_path = try callPath(gpa, conn, sc_dest, "/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast", "CreateSession", "a{sv}", m.buf.items);

    try conn.addMatch("type='signal',interface='org.gnome.Mutter.ScreenCast.Stream',member='PipeWireStreamAdded'");
    var mons: std.ArrayList(Monitor) = .empty;
    for (connectors) |connector| {
        m.buf.clearRetainingCapacity();
        try m.putString(connector);
        const arr = try m.beginArray(8);
        try m.beginStruct();
        try m.putString("cursor-mode");
        try m.putVariantU32(1); // embedded: screenshots show the pointer
        m.endArray(arr);
        const stream = try callPath(gpa, conn, sc_dest, sc_path, sc_session_iface, "RecordMonitor", "sa{sv}", m.buf.items);
        try mons.append(arena, .{ .connector = connector, .stream = stream });
    }
    return mons.items;
}

/// Every stream announces its PipeWire node once started: note each.
fn waitStreams(gpa: std.mem.Allocator, conn: *dbus.Connection, mons: []Monitor) !void {
    const deadline = sys.monoMs() + 10_000;
    var missing = mons.len;
    while (missing > 0) {
        var msg = (try conn.nextMessageDeadline(deadline)) orelse return error.NoPipeWireStream;
        defer msg.deinit(gpa);
        if (!msg.isSignal("org.gnome.Mutter.ScreenCast.Stream", "PipeWireStreamAdded")) continue;
        var r = msg.reader();
        const node = try r.readU32();
        for (mons) |*mon| {
            if (mon.node == 0 and std.mem.eql(u8, mon.stream, msg.path orelse "")) {
                mon.node = node;
                missing -= 1;
            }
        }
    }
}

const Driver = struct {
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    rd: []const u8,
    mons: []Monitor,
    runtime: []const u8,
    out: [512]u8 = undefined,
    filming: ?*movie.Film = null,

    // the backend half of common.commands, through the remote desktop
    // session's Notify* methods

    pub fn key(self: *Driver, code: u32, pressed: bool) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putU32(code);
        try m.putBool(pressed);
        try self.notify("NotifyKeyboardKeycode", "ub", &m);
        // give the compositor a beat so clients see distinct events
        sleepMs(15);
    }

    pub fn keysym(self: *Driver, sym: u32) !void {
        for ([_]bool{ true, false }) |state| {
            var m = dbus.Marshal.init(self.gpa);
            defer m.deinit();
            try m.putU32(sym);
            try m.putBool(state);
            try self.notify("NotifyKeyboardKeysym", "ub", &m);
        }
    }

    pub fn button(self: *Driver, btn: u32, pressed: bool) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putI32(@intCast(btn));
        try m.putBool(pressed);
        try self.notify("NotifyPointerButton", "ib", &m);
        sleepMs(15);
    }

    pub fn move(self: *Driver, name: []const u8, x: f64, y: f64) !void {
        const mon = try self.monitor(name);
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putString(mon.stream);
        try putDouble(&m, x);
        try putDouble(&m, y);
        try self.notify("NotifyPointerMotionAbsolute", "sdd", &m);
        // let the client see enter/motion before a following click
        sleepMs(40);
    }

    pub fn rel(self: *Driver, dx: f64, dy: f64) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try putDouble(&m, dx);
        try putDouble(&m, dy);
        try self.notify("NotifyPointerMotionRelative", "dd", &m);
    }

    pub fn wheel(self: *Driver, steps: i32) !void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putU32(0); // vertical
        try m.putI32(steps);
        try self.notify("NotifyPointerAxisDiscrete", "ui", &m);
    }

    /// The connectors, in command line order.
    pub fn monitors(self: *Driver) []const u8 {
        var w: usize = 0;
        for (self.mons) |mon| {
            const s = std.fmt.bufPrint(self.out[w..], "{s}{s}", .{ if (w > 0) " " else "", mon.connector }) catch break;
            w += s.len;
        }
        return self.out[0..w];
    }

    /// The monitor's current picture, over a fresh PipeWire connection.
    pub fn grab(self: *Driver, name: []const u8) !images.Frame {
        const f = try self.grabNode(try self.monitor(name));
        return .{ .pixels = f.pixels, .width = f.width, .height = f.height, .alloc = std.heap.page_allocator };
    }

    /// A frame of `mon`. The screencast gives none now and then (a screen
    /// where nothing moves): asked again, or a check that something is not
    /// there would pass on no frame at all.
    fn grabNode(self: *Driver, mon: *const Monitor) !kit.pw.Frame {
        for (0..8) |_| return self.grabOnce(mon) catch |err| switch (err) {
            error.NoFrame => continue,
            else => return err,
        };
        return error.NoFrame;
    }

    fn grabOnce(self: *Driver, mon: *const Monitor) !kit.pw.Frame {
        var sock_path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&sock_path, "{s}/pipewire-0", .{self.runtime});
        const fd = try sys.socketUnixStream();
        sys.connectUnix(fd, p) catch |err| {
            sys.close(fd);
            return err;
        };
        var frame: [1]kit.pw.Frame = undefined;
        try kit.pw.grabFrames(fd, &.{mon.node}, &frame, 800);
        return frame[0];
    }

    /// Film until `cut`, from the first frame on.
    pub fn film(self: *Driver, name: []const u8) !void {
        if (self.filming != null) return error.Filming;
        const mon = try self.monitor(name);
        var probe = try self.grabNode(mon);
        const w = probe.width;
        const h = probe.height;
        probe.deinit();
        const f = try movie.Film.start(self.gpa, mon.node, w, h);
        self.filming = f;
        const deadline = sys.monoMs() + 5000;
        while (f.count() == 0) {
            if (sys.monoMs() > deadline) return error.NoFrames;
            sleepMs(5);
        }
    }

    /// Stop filming; judge the frames (`box`, monitor pixels, left out)
    /// and write them to `dir` unless it is "-".
    pub fn cut(self: *Driver, dir: []const u8, box: ?[4]u32) ![]const u8 {
        const f = self.filming orelse return error.NotFilming;
        self.filming = null;
        f.stop();
        defer f.deinit();
        const n = f.count();
        var mask: ?movie.Mask = null;
        if (box) |b| {
            var m: movie.Mask = undefined;
            for (&m, b) |*v, c| v.* = c / movie.shrink;
            mask = m;
        }
        if (!eql(dir, "-")) for (0..n) |i| {
            var name: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&name, "{s}/f{d:0>4}.png", .{ dir, i });
            const data = try kit.png.encode(self.gpa, f.frame(@intCast(i)), f.fw, f.fh);
            defer self.gpa.free(data);
            try sys.writeFile(path, data);
        };
        const v = movie.judge(f, n, mask);
        return std.fmt.bufPrint(&self.out, "frames {d} ghosts {d} blends {d} worst {d} {d}{s}", .{ v.frames, v.ghosts, v.blends, v.worst, v.worst_permille, if (f.full) " full" else "" });
    }

    pub fn sniWatcher(self: *Driver, ms: u32) ![]const u8 {
        return common.sni.watch(self.gpa, self.conn, ms, &self.out);
    }

    /// Drop signals and stray replies queued meanwhile.
    pub fn idle(self: *Driver) !void {
        while (self.conn.hasPending()) {
            var msg = (try self.conn.nextMessageDeadline(0)) orelse break;
            msg.deinit(self.gpa);
        }
    }

    fn monitor(self: *Driver, name: []const u8) !*Monitor {
        for (self.mons) |*mon| if (eql(mon.connector, name)) return mon;
        const i = std.fmt.parseInt(usize, name, 10) catch return error.UnknownMonitor;
        if (i >= self.mons.len) return error.UnknownMonitor;
        return &self.mons[i];
    }

    /// Call a method of the remote desktop session.
    fn notify(self: *Driver, member: []const u8, sig: []const u8, m: *const dbus.Marshal) !void {
        try callVoid(self.conn, rd_dest, self.rd, rd_session_iface, member, sig, m.buf.items);
    }
};

test {
    _ = movie;
}

fn putDouble(m: *dbus.Marshal, v: f64) !void {
    try m.putU64(@bitCast(v));
}

fn callPath(gpa: std.mem.Allocator, conn: *dbus.Connection, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) ![]u8 {
    const serial = try conn.callMethod(dest, path, iface, member, sig, body);
    var msg = try conn.waitReply(serial);
    defer msg.deinit(gpa);
    var r = msg.reader();
    return gpa.dupe(u8, try r.readString());
}

fn callVoid(conn: *dbus.Connection, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !void {
    const serial = try conn.callMethod(dest, path, iface, member, sig, body);
    var msg = try conn.waitReply(serial);
    msg.deinit(conn.alloc);
}

fn getStringProp(gpa: std.mem.Allocator, conn: *dbus.Connection, dest: []const u8, path: []const u8, iface: []const u8, prop: []const u8) ![]u8 {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    try m.putString(iface);
    try m.putString(prop);
    const serial = try conn.callMethod(dest, path, "org.freedesktop.DBus.Properties", "Get", "ss", m.buf.items);
    var msg = try conn.waitReply(serial);
    defer msg.deinit(gpa);
    var r = msg.reader();
    return switch (try r.readVariant()) {
        .string => |s| gpa.dupe(u8, s),
        else => error.BadProperty,
    };
}
