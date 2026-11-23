//! Capture through the ScreenCast portal and PipeWire: one frame from
//! every monitor, stitched.

const std = @import("std");
const capture = @import("../../../app/capture.zig");
const config = @import("../../../app/config.zig");
const dbus = @import("../dbus.zig");
const portal = @import("../portal.zig");
const pw = @import("../pw.zig");
const sys = @import("../sys.zig");
const Env = @import("../../../app/env.zig").Env;

/// ScreenCast + PipeWire: one frame from every monitor, stitched. Errors
/// after the portal said yes count as "unavailable" so the caller can fall
/// back to the Screenshot portal.
pub fn screencast(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, cfg: *config.Config) portal.Result(capture.Capture) {
    return screencastInner(gpa, env, bus, cfg) catch |err| {
        std.log.info("screencast capture failed ({t})", .{err});
        return .unavailable;
    };
}

fn screencastInner(gpa: std.mem.Allocator, env: Env, bus: *dbus.Connection, cfg: *config.Config) !portal.Result(capture.Capture) {
    const ts0 = sys.monoMs();
    var session = switch (try portal.openScreenCast(gpa, bus, .{ .restore_token = cfg.scToken() })) {
        .granted => |s| s,
        else => |o| return portal.notGranted(capture.Capture, o),
    };
    defer session.close(gpa, bus);
    if (session.start.restore_token) |t| rememberToken(gpa, env.home, cfg, t);
    for (session.start.streams) |st| std.log.debug("screencast stream: node {d} position {?any} size {?any}", .{ st.node_id, st.position, st.size });

    const ts1 = sys.monoMs();
    const cap = try grabStitched(gpa, bus, &session);
    std.log.info("  capture detail: monitors={d} session={d} grab+close+stitch={d}ms", .{
        @min(session.start.streams.len, pw.max_nodes), ts1 - ts0, sys.monoMs() - ts1,
    });
    return .{ .granted = cap };
}

/// One frame of each of the session's streams (it takes the PipeWire
/// fd), the session ended as soon as they are in (GNOME's screen-sharing
/// indicator must only blink during the grab), stitched.
pub fn grabStitched(gpa: std.mem.Allocator, bus: *dbus.Connection, session: *portal.ScreenCastSession) !capture.Capture {
    const streams = session.start.streams[0..@min(session.start.streams.len, pw.max_nodes)];
    var ids: [pw.max_nodes]u32 = undefined;
    for (streams, 0..) |st, i| ids[i] = st.node_id;
    var frames: [pw.max_nodes]pw.Frame = undefined;
    const grabbed = pw.grabFrames(session.fd, ids[0..streams.len], frames[0..streams.len], 5000);
    session.end(bus);
    try grabbed;
    defer for (frames[0..streams.len]) |*f| f.deinit();
    return stitchStreams(gpa, streams, frames[0..streams.len]);
}

/// Keeps a new restore token so the next capture or recording skips the
/// dialog.
pub fn rememberToken(gpa: std.mem.Allocator, home: []const u8, cfg: *config.Config, t: []const u8) void {
    cfg.setScToken(t);
    // only this key: never write back a stale snapshot of the rest
    config.saveScreencastToken(gpa, home, t) catch |err|
        std.log.warn("could not store the screencast token: {t}", .{err});
}

/// Stitches one grabbed frame per stream, placed where the portal says
/// each monitor is (when it says).
fn stitchStreams(gpa: std.mem.Allocator, streams: []const portal.Stream, frames: []const pw.Frame) !capture.Capture {
    var parts: [pw.max_nodes]capture.Part = undefined;
    for (streams, frames, 0..) |st, f, i| {
        parts[i] = .{ .pixels = f.pixels, .width = f.width, .height = f.height };
        if (st.position != null and st.size != null) {
            parts[i].logical = .{
                .x = st.position.?[0],
                .y = st.position.?[1],
                .w = @intCast(st.size.?[0]),
                .h = @intCast(st.size.?[1]),
            };
        }
    }
    return capture.stitch(gpa, parts[0..streams.len]);
}
