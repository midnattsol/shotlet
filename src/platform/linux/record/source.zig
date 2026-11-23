//! Where a recording's pictures come from: the GNOME Shell extension
//! (no prompt; a screencast of exactly the area) or the ScreenCast portal
//! (a monitor, cropped to the area; consent once, then the restore token).

const std = @import("std");
const log = std.log.scoped(.recording);
const dbus = @import("../dbus.zig");
const pwstream = @import("../pwstream.zig");
const config = @import("../../../app/config.zig");
const gnome = @import("../gnome.zig");
const shell1 = @import("../gnome/shell1.zig");
const portal = @import("../portal.zig");
const region = @import("../../../record/region.zig");
const geom = @import("../../../geom.zig");
const switches = @import("../../api/switches.zig");
const rememberToken = @import("../capture/screencast.zig").rememberToken;
const sys = @import("../sys.zig");
const max_outputs = @import("../../api/window.zig").max_outputs;

pub const Want = @import("../../api/record.zig").Want;

pub const Source = struct {
    kind: enum { shell, portal },
    cap: *pwstream.Capture,
    node: u32,
    /// the stream's logical rectangle, and the part of it to keep
    stream_rect: geom.Rect,
    crop: ?geom.Rect,
    session: ?portal.ScreenCastSession = null,

    pub fn label(self: *const Source) []const u8 {
        return switch (self.kind) {
            .shell => "GNOME integration",
            .portal => "ScreenCast portal",
        };
    }

    /// After the engine stopped.
    pub fn close(self: *Source, gpa: std.mem.Allocator, bus: *dbus.Connection) void {
        self.cap.close(gpa);
        switch (self.kind) {
            .shell => shell1.stopRecording(bus),
            .portal => if (self.session) |*s| s.close(gpa, bus),
        }
    }
};

pub const Opened = union(enum) { ok: Source, cancelled, failed: anyerror };

pub fn open(gpa: std.mem.Allocator, bus: *dbus.Connection, home: []const u8, cfg: *config.Config, want: Want) Opened {
    if (!switches.get().no_shell_record and gnome.isGnome() and shell1.supports(bus, .recording)) {
        if (openShell(gpa, bus, want)) |s| return .{ .ok = s } else |err| log.info("GNOME integration: {t}; the portal", .{err});
    }
    return openPortal(gpa, bus, home, cfg, want) catch |err| .{ .failed = err };
}

fn openShell(gpa: std.mem.Allocator, bus: *dbus.Connection, want: Want) !Source {
    const node = try shell1.startRecording(bus, .{ .area = want.area, .clicks = want.clicks, .keys = want.keys });
    errdefer shell1.stopRecording(bus);
    const cap = try pwstream.Capture.open(gpa, null);
    log.info("source GNOME integration (node {d})", .{node});
    return .{ .kind = .shell, .cap = cap, .node = node, .stream_rect = want.area, .crop = null };
}

fn openPortal(gpa: std.mem.Allocator, bus: *dbus.Connection, home: []const u8, cfg: *config.Config, want: Want) !Opened {
    portal.registerApp(gpa, bus);
    var session = switch (try openSession(gpa, bus, cfg.scToken())) {
        .granted => |s| s,
        .cancelled, .timeout => return .cancelled,
        .denied => return error.Denied,
        .unavailable => return error.NoScreenCast,
    };
    errdefer session.close(gpa, bus);
    if (session.start.restore_token) |t| rememberToken(gpa, home, cfg, t);
    // the PipeWire fd is ours until Capture.open takes it
    const pick = pickStream(session.start.streams, want.area) orelse {
        sys.close(session.fd);
        return error.NoStream;
    };
    const cap = try pwstream.Capture.open(gpa, session.fd);
    log.info("source ScreenCast portal (node {d}, monitor {d},{d} {d}x{d})", .{ pick.node, pick.rect.x, pick.rect.y, pick.rect.w, pick.rect.h });
    return .{ .ok = .{ .kind = .portal, .cap = cap, .node = pick.node, .stream_rect = pick.rect, .crop = want.area, .session = session } };
}

/// A ScreenCast session over every monitor, as screenshots open it (one
/// restore token serves both, so consent is asked once), kept for the
/// whole recording, with the cursor drawn in when the portal can.
fn openSession(gpa: std.mem.Allocator, bus: *dbus.Connection, prev_token: ?[]const u8) !portal.Result(portal.ScreenCastSession) {
    const embedded = portal.availableCursorModes(bus) & portal.cursor_embedded != 0;
    return portal.openScreenCast(gpa, bus, .{
        .cursor_mode = if (embedded) portal.cursor_embedded else portal.cursor_hidden,
        .restore_token = prev_token,
    });
}

/// The stream showing most of the area. A portal that gives no position
/// (or size) has one monitor at the origin, as the screenshots saw it
/// (the first stream is taken when none overlaps).
fn pickStream(streams: []const portal.Stream, area: geom.Rect) ?struct { node: u32, rect: geom.Rect } {
    if (streams.len == 0) return null;
    var rects: [max_outputs]geom.Rect = undefined;
    const n = @min(streams.len, rects.len);
    for (streams[0..n], 0..) |s, i| {
        const pos = s.position orelse .{ 0, 0 };
        // no size: frames.zig takes the frame's pixels as logical
        const size = s.size orelse .{ 0, 0 };
        rects[i] = .{ .x = pos[0], .y = pos[1], .w = size[0], .h = size[1] };
    }
    const best = region.bestMonitor(area, rects[0..n]) orelse 0;
    return .{ .node = streams[best].node_id, .rect = rects[best] };
}

test "the stream holding the area is picked" {
    const streams = [_]portal.Stream{
        .{ .node_id = 7, .position = .{ 0, 0 }, .size = .{ 1600, 900 } },
        .{ .node_id = 9, .position = .{ 1600, 0 }, .size = .{ 1280, 720 } },
    };
    const p = pickStream(&streams, .{ .x = 1700, .y = 100, .w = 300, .h = 200 }).?;
    try std.testing.expectEqual(@as(u32, 9), p.node);
    const lone = [_]portal.Stream{.{ .node_id = 3 }};
    const q = pickStream(&lone, .{ .x = 10, .y = 10, .w = 30, .h = 20 }).?;
    try std.testing.expectEqual(geom.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, q.rect);
}
