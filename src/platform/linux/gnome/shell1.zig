//! dev.shotlet.Shell1, the bus interface of the Shotlet GNOME Shell
//! extension (gnome-extension/: extension.js, modes.js, scroll.js,
//! recorder.js, windows.js): its names, its Version and what each
//! version can do, and Shotlet's side of every call.

const std = @import("std");
const dbus = @import("../dbus.zig");
const geom = @import("../../../geom.zig");
const mode = @import("../../../app/modes/mode.zig");
const region = @import("../../../record/region.zig");

/// owned by the extension while it is active
pub const bus_name = "dev.shotlet.Shell1";
pub const path = "/dev/shotlet/Shell1";
pub const iface = "dev.shotlet.Shell1";

/// What a version of the extension can do. Capture() and Place() are
/// in every version.
pub const Feature = enum {
    /// captures it reports on (Shortcuts, BlockedShortcuts)
    capture_info,
    /// RecordSelect, StartRecording
    recording,
};

/// The lowest Version with each Feature.
const min_version = std.EnumArray(Feature, u32).init(.{
    .capture_info = 2,
    .recording = 3,
});

/// The extension's Version property; null when it is not running (or
/// does not say).
pub fn version(bus: *dbus.Connection) ?u32 {
    if (!(bus.nameHasOwner(bus_name) catch false)) return null;
    var prop = bus.getProperty(bus_name, path, iface, "Version", 2000) catch return null;
    defer prop.deinit(bus.alloc);
    return switch (prop.value) {
        .u32_ => |v| v,
        else => null,
    };
}

/// The running extension is new enough for `f`.
pub fn supports(bus: *dbus.Connection, f: Feature) bool {
    const v = version(bus) orelse return false;
    return v >= min_version.get(f);
}

/// Call `member`: the reply, or the error reply as its CallError (Busy
/// for Busy and Locked, UnknownMethod from an older extension).
pub fn call(bus: *dbus.Connection, member: []const u8, sig: []const u8, body: []const u8, timeout_ms: i64) !dbus.Message {
    return bus.call(bus_name, path, iface, member, sig, body, timeout_ms);
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
/// An area capture with no delay uses Capture(), which every version has.
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
        var self: Scroll = .{ .gpa = gpa, .bus = bus };
        self.id_len = (try readStringInto(&reply, &self.id_buf)).len;
        return self;
    }

    /// Scroll `clicks` wheel notches (0: none), then grab the region. The
    /// capture id of its PNG goes into `out`.
    pub fn step(self: *Scroll, clicks: i32, out: []u8) ![]u8 {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        try m.putString(self.id());
        try m.putI32(clicks);
        var reply = try call(self.bus, "ScrollStep", "si", m.buf.items, 5000);
        defer reply.deinit(self.bus.alloc);
        return readStringInto(&reply, out);
    }

    pub fn end(self: *Scroll) void {
        var m = dbus.Marshal.init(self.gpa);
        defer m.deinit();
        m.putString(self.id()) catch return;
        var reply = call(self.bus, "ScrollEnd", "s", m.buf.items, 2000) catch return;
        reply.deinit(self.bus.alloc);
    }
};

/// A reply's first string, copied into `out`.
fn readStringInto(reply: *const dbus.Message, out: []u8) ![]u8 {
    var r = reply.reader();
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

test "the version table" {
    try std.testing.expectEqual(@as(u32, 2), min_version.get(.capture_info));
    try std.testing.expectEqual(@as(u32, 3), min_version.get(.recording));
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
