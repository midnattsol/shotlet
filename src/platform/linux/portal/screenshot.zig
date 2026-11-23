//! org.freedesktop.portal.Screenshot, and reading back the file a portal
//! answered with (a file:// URI, uri.zig).

const std = @import("std");
const dbus = @import("../dbus.zig");
const sys = @import("../sys.zig");
const request = @import("request.zig");
const uri_mod = @import("../uri.zig");

const Request = request.Request;
const Result = request.Result;

/// Take a full-screen screenshot via org.freedesktop.portal.Screenshot.
/// When granted, returns the PNG file contents and removes the temporary
/// file from disk. `timeout_ms`: timeout_dialog_ms when a consent dialog
/// may show, shorter when none can.
pub fn screenshot(alloc: std.mem.Allocator, bus: *dbus.Connection, interactive: bool, timeout_ms: i64) !Result([]u8) {
    var req = try beginScreenshot(alloc, bus, interactive);
    defer req.deinit(alloc);
    try req.wait(alloc, bus, timeout_ms);
    if (req.outcome.? != .granted) return request.notGranted([]u8, req.outcome.?);
    const uri = try screenshotUri(&req);
    return .{ .granted = try readAndUnlink(alloc, uri) };
}

/// Start a Screenshot request; pump messages into the returned Request.
pub fn beginScreenshot(alloc: std.mem.Allocator, bus: *dbus.Connection, interactive: bool) !Request {
    var tok_buf: [64]u8 = undefined;
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putString(""); // parent_window
    const opts = try m.beginDict();
    const token = try opts.token("handle_token", &tok_buf, "shotlet_");
    try opts.entry("interactive", interactive);
    opts.end();
    return Request.start(alloc, bus, "org.freedesktop.portal.Screenshot", "Screenshot", "sa{sv}", m.buf.items, token);
}

/// The "uri" result of a granted Screenshot request (borrowed).
pub fn screenshotUri(req: *const Request) ![]const u8 {
    var r = try req.results();
    var it = try r.readDictRaw();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.key, "uri") and std.mem.eql(u8, e.sig, "s")) return r.readString();
        try r.skipValue(e.sig);
    }
    return error.NoUri;
}

/// Read the file a file:// URI names (PNG-sized limit), then delete it.
pub fn readAndUnlink(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const path = try uri_mod.toFilePath(alloc, uri);
    defer alloc.free(path);

    const png = try sys.readFileAlloc(alloc, path, 256 * 1024 * 1024);
    // Honor "no files on disk": the portal wrote a temp screenshot; remove it.
    sys.unlink(path) catch {};
    return png;
}
