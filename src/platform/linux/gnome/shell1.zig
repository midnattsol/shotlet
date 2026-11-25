//! dev.shotlet.Shell1, the bus interface of the Shotlet GNOME Shell
//! extension (gnome-extension/: extension.js, modes.js, scroll.js,
//! recorder.js, windows.js): its names, and Shotlet's side of every call.

const std = @import("std");
const dbus = @import("../dbus.zig");
const geom = @import("../../../geom.zig");
const mode = @import("../../../app/modes/mode.zig");
const region = @import("../../../record/region.zig");

/// owned by the extension while it is active
pub const bus_name = "dev.shotlet.Shell1";
pub const path = "/dev/shotlet/Shell1";
pub const iface = "dev.shotlet.Shell1";

/// Call `member`: the reply, or the error reply as its CallError (Busy
/// for Busy and Locked, UnknownMethod from an older extension). A call
/// that checks its caller answered Denied: see `refused`.
pub fn call(bus: *dbus.Connection, member: []const u8, sig: []const u8, body: []const u8, timeout_ms: i64) !dbus.Message {
    return bus.call(bus_name, path, iface, member, sig, body, timeout_ms) catch |err| {
        if (err == error.Denied and checksCaller(member)) refused_caller.store(true, .monotonic);
        return err;
    };
}

/// The extension answers only the binary it would start itself (the
/// .desktop file's Exec, its `shotlet-path`, or PATH): it refused this
/// one at least once in this run (AccessDenied from a call that checks
/// the caller), as it does for a copy run from elsewhere
/// (zig-out/bin/shotlet).
pub fn refused() bool {
    return refused_caller.load(.monotonic);
}

var refused_caller = std.atomic.Value(bool).init(false);

/// The calls that check who asks (extension.js `_checkCaller`), and
/// answer AccessDenied for nothing else. (ScrollStep and ScrollEnd say
/// AccessDenied for other reasons: another caller's session, the control
/// not on screen.)
fn checksCaller(member: []const u8) bool {
    const checked = [_][]const u8{ "Capture", "CaptureMode", "CaptureWindows", "ScrollBegin", "StartRecording", "RecordSelect" };
    for (checked) |m| if (std.mem.eql(u8, m, member)) return true;
    return false;
}

/// A property of the extension (Shortcuts, BlockedShortcuts, ...).
pub fn getProperty(bus: *dbus.Connection, name: []const u8) !dbus.Property {
    return bus.getProperty(bus_name, path, iface, name, 2000);
}

/// The first u32/bool of a reply as a yes or no.
fn replyYes(bus: *dbus.Connection, reply: *dbus.Message) bool {
    defer reply.deinit(bus.alloc);
    var r = reply.reader();
    return (r.readU32() catch 0) != 0;
}

// --- captures

pub const CaptureRequest = enum {
    /// the extension took the screenshot and started the editor
    started,
    /// a capture is already under way, or the screen is locked: nothing
    /// else should capture now
    declined,
    /// not possible (an older extension, a failure): capture another way
    unavailable,
};

/// Ask the extension to take a screenshot and start Shotlet's editor on
/// it (Capture: no pixels come back over the bus).
pub fn capture(bus: *dbus.Connection) CaptureRequest {
    var reply = call(bus, "Capture", "", "", 5000) catch |err| return switch (err) {
        error.Busy => .declined,
        else => .unavailable,
    };
    return if (replyYes(bus, &reply)) .started else .unavailable;
}

pub const Handoff = @import("../../api/shell.zig").Handoff;

/// Ask the extension to capture in this mode (after its countdown).
/// An area capture with no delay uses Capture().
pub fn captureMode(bus: *dbus.Connection, req: mode.Request) Handoff {
    if (req.mode == .area and req.delay_s == 0) return switch (capture(bus)) {
        .started => .started,
        .declined => .declined,
        .unavailable => .unavailable,
    };
    var m = dbus.Marshal.init(bus.alloc);
    defer m.deinit();
    m.putString(@tagName(req.mode)) catch return .unavailable;
    m.putU32(req.delay_s) catch return .unavailable;
    var reply = call(bus, "CaptureMode", "su", m.buf.items, 5000) catch |err| return switch (err) {
        error.Busy => .declined,
        else => .unavailable,
    };
    return if (replyYes(bus, &reply)) .started else .unavailable;
}

/// CaptureWindows(id): the windows where capture `id` was taken, as
/// [x, y, w, h, ...] logical, into `out` (whole rectangles, topmost
/// first); empty when the extension has none to give.
pub fn captureWindows(bus: *dbus.Connection, id: []const u8, out: []i32) []const i32 {
    var m = dbus.Marshal.init(bus.alloc);
    defer m.deinit();
    m.putString(id) catch return &.{};
    var reply = call(bus, "CaptureWindows", "s", m.buf.items, 1000) catch return &.{};
    defer reply.deinit(bus.alloc);
    var r = reply.reader();
    return readInts(&r, out) catch &.{};
}

/// Unfreeze(id): Shotlet shows capture `id` (or never will): the
/// extension's frozen frame of it goes, and the reply says what the
/// pointer and keyboard did meanwhile (null from an older extension, or
/// when it does not answer soon).
pub fn unfreeze(bus: *dbus.Connection, id: []const u8) ?FrozenInput {
    var m = dbus.Marshal.init(bus.alloc);
    defer m.deinit();
    m.putString(id) catch return null;
    var reply = call(bus, "Unfreeze", "s", m.buf.items, 500) catch return null;
    defer reply.deinit(bus.alloc);
    var r = reply.reader();
    return readFrozenInput(&r) catch null;
}

pub const FrozenInput = @import("../../api/shell.zig").FrozenInput;

/// Unfreeze's reply, (bbiibiib): pressed, x, y, released, rx, ry, escaped.
fn readFrozenInput(r: *dbus.Reader) !FrozenInput {
    var in: FrozenInput = .{};
    in.pressed = try r.readU32() != 0;
    in.x = @bitCast(try r.readU32());
    in.y = @bitCast(try r.readU32());
    in.released = try r.readU32() != 0;
    in.rx = @bitCast(try r.readU32());
    in.ry = @bitCast(try r.readU32());
    in.escaped = try r.readU32() != 0;
    return in;
}

/// An `ai` array into `out` (whole rectangles only, the topmost ones).
fn readInts(r: *dbus.Reader, out: []i32) ![]const i32 {
    const bytes = try r.readU32();
    const n = @min(bytes / 4, out.len) / 4 * 4;
    for (out[0..n]) |*v| v.* = @bitCast(try r.readU32());
    return out[0..n];
}

/// Move one of Shotlet's tagged windows (Place): false when the extension
/// does not know it (yet).
pub fn place(gpa: std.mem.Allocator, bus: *dbus.Connection, title: []const u8, x: i32, y: i32) bool {
    var m = dbus.Marshal.init(gpa);
    defer m.deinit();
    m.putString(title) catch return false;
    m.putI32(x) catch return false;
    m.putI32(y) catch return false;
    var reply = call(bus, "Place", "sii", m.buf.items, 2000) catch return false;
    return replyYes(bus, &reply);
}

/// A scrolling capture session in the extension.
pub const Scroll = struct {
    gpa: std.mem.Allocator,
    bus: *dbus.Connection,
    id_buf: [32]u8 = undefined,
    id_len: usize = 0,
    rect: geom.Rect,
    pieces_buf: [1024]u8 = undefined,
    pieces_len: usize = 0,

    /// The strips its frames come in (shellcap.loadRegion).
    pub fn pieces(self: *const Scroll) []const u8 {
        return self.pieces_buf[0..self.pieces_len];
    }

    fn id(self: *const Scroll) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    /// `rect` in logical coordinates; `auto`: the extension turns the
    /// wheel for each step.
    pub fn begin(gpa: std.mem.Allocator, bus: *dbus.Connection, rect: geom.Rect, auto: bool) !Scroll {
        var m = dbus.Marshal.init(gpa);
        defer m.deinit();
        for (rect.array()) |v| try m.putI32(v);
        try m.putBool(auto);
        var reply = try call(bus, "ScrollBegin", "iiiib", m.buf.items, 5000);
        defer reply.deinit(bus.alloc);
        var self: Scroll = .{ .gpa = gpa, .bus = bus, .rect = rect };
        var r = reply.reader();
        self.id_len = (try readStringInto(&r, &self.id_buf)).len;
        // (none from an older extension)
        self.pieces_len = if (readStringInto(&r, &self.pieces_buf)) |p| p.len else |err| switch (err) {
            error.ShortRead => 0,
            else => return err,
        };
        return self;
    }

    /// Scroll `clicks` wheel notches (0: none), then grab the region. Its
    /// capture id goes into `out`.
    pub fn step(self: *Scroll, clicks: i32, out: []u8) ![]u8 {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putString(self.id());
        try m.putI32(clicks);
        var reply = try call(self.bus, "ScrollStep", "si", m.buf.items, 5000);
        defer reply.deinit(self.bus.alloc);
        var r = reply.reader();
        return readStringInto(&r, out);
    }

    pub fn end(self: *Scroll) void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        m.putString(self.id()) catch return;
        var reply = call(self.bus, "ScrollEnd", "s", m.buf.items, 2000) catch return;
        reply.deinit(self.bus.alloc);
    }
};

/// A reply's next string, copied into `out`.
fn readStringInto(r: *dbus.Reader, out: []u8) ![]u8 {
    const s = try r.readString();
    if (s.len > out.len) return error.BadReply;
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

// --- recording (recorder.js): StartRecording gives the PipeWire node of
// a screencast of the area that mutter makes for the shell;
// StopRecording ends it (so does Shotlet leaving the bus).
// RecordingStopRequested comes from the top bar's stop button and the
// record shortcut.

pub const RecordOptions = struct {
    area: geom.Rect,
    cursor: bool = true,
    clicks: bool = false,
    keys: bool = false,
};

/// Start the screencast; the PipeWire node to read.
pub fn startRecording(bus: *dbus.Connection, o: RecordOptions) !u32 {
    var m = dbus.Marshal.init(bus.alloc);
    defer m.deinit();
    const d = try m.beginDict();
    try d.entry("x", o.area.x);
    try d.entry("y", o.area.y);
    try d.entry("w", o.area.w);
    try d.entry("h", o.area.h);
    try d.entry("cursor", o.cursor);
    try d.entry("clicks", o.clicks);
    try d.entry("keys", o.keys);
    d.end();
    var reply = try call(bus, "StartRecording", "a{sv}", m.buf.items, 10_000);
    defer reply.deinit(bus.alloc);
    var r = reply.reader();
    return try r.readU32();
}

/// Ask the extension to capture the desktop and start the picker on it
/// (`shotlet --from-shell ... --then record`).
pub fn recordSelect(bus: *dbus.Connection) !void {
    var reply = try call(bus, "RecordSelect", "", "", 10_000);
    reply.deinit(bus.alloc);
}

/// End the screencast (fire-and-forget).
pub fn stopRecording(bus: *dbus.Connection) void {
    _ = bus.callMethod(bus_name, path, iface, "StopRecording", "", "") catch {};
}

/// Hear the stop button and the shortcut.
pub fn watchStop(bus: *dbus.Connection) !void {
    try bus.addMatch("type='signal',interface='" ++ iface ++ "',member='RecordingStopRequested'");
}

pub fn isStopRequest(msg: *const dbus.Message) bool {
    return msg.isSignal(iface, "RecordingStopRequested");
}

test "only the calls that check the caller tell of a refusal" {
    try std.testing.expect(checksCaller("Capture") and checksCaller("ScrollBegin") and checksCaller("StartRecording"));
    try std.testing.expect(!checksCaller("ScrollStep") and !checksCaller("ScrollEnd") and !checksCaller("Place"));
}

test "CaptureWindows' ai keeps whole rectangles" {
    var m = dbus.Marshal.init(std.testing.allocator);
    defer m.deinit();
    const a = try m.beginArray(4);
    for ([_]i32{ 1, 2, 3, 4, 5, 6 }) |v| try m.putI32(v);
    m.endArray(a);
    var r: dbus.Reader = .{ .data = m.buf.items, .pos = 0 };
    var out: [8]i32 = undefined;
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, try readInts(&r, &out));
}
