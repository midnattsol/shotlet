//! `shotlet MODE [--delay S]`, `shotlet timer [S]` (see mode.zig): the
//! self-timer and the window mode where the GNOME extension does not
//! handle them, a scrolling capture only where one can run
//! (scroll/available.zig: else the person is told why and it exits with
//! status 1), then the usual capture flow (app/shot.zig) with the mode.

const std = @import("std");
const platform = @import("../../platform/api.zig");
const shell = platform.shell;
const env_mod = @import("../env.zig");
const shot = @import("../shot.zig");
const mode = @import("mode.zig");
const config = @import("../config.zig");
const scroll_available = @import("../scroll/available.zig");
const out = @import("../../cli/out.zig");
const Parsed = @import("../../cli/parse.zig").Parsed;

/// The GNOME extension is here to pick windows.
fn gnomeExtension(gpa: std.mem.Allocator, env: env_mod.Env) bool {
    return shell.activeNow(gpa, env);
}

pub fn run(gpa: std.mem.Allocator, env: env_mod.Env, p: *const Parsed) !void {
    var req = request(p, config.load(gpa, env.home).modes.timer_s);
    if (req.mode == .window and !gnomeExtension(gpa, env)) {
        if (!shell.applies() and try platform.capture.captureWindow(gpa, env, req)) return;
        std.log.info("window capture: not offered here; selecting an area instead", .{});
        req.mode = .area;
    }
    if (req.mode == .scroll and !scroll_available.ensure(gpa, env)) out.exit(.failure);
    try shot.run(gpa, env, .{ .req = req }, null, 0);
}

/// The capture a mode's command asks for; `timer` without SECONDS
/// counts `default_timer`.
pub fn request(p: *const Parsed, default_timer: u8) mode.Request {
    if (p.id() == .timer) return .{ .delay_s = p.argInt(u8, 0) orelse default_timer };
    return .{
        .mode = mode.Mode.parse(@tagName(p.id())).?,
        .delay_s = p.int(u8, "delay") orelse 0,
    };
}

test "mode commands ask for their capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parse = @import("../../cli/parse.zig");
    const Case = struct { args: []const [:0]const u8, mode: mode.Mode, delay: u8 };
    const cases = [_]Case{
        .{ .args = &.{"window"}, .mode = .window, .delay = 0 },
        .{ .args = &.{"timer"}, .mode = .area, .delay = 5 },
        .{ .args = &.{ "timer", "10" }, .mode = .area, .delay = 10 },
        .{ .args = &.{ "fullscreen", "--delay", "3" }, .mode = .fullscreen, .delay = 3 },
        .{ .args = &.{ "area", "--delay=60" }, .mode = .area, .delay = 60 },
        .{ .args = &.{ "scroll", "--delay", "0" }, .mode = .scroll, .delay = 0 },
        .{ .args = &.{ "screens", "--delay", "3", "--delay", "10" }, .mode = .screens, .delay = 10 },
        .{ .args = &.{"previous"}, .mode = .previous, .delay = 0 },
    };
    for (cases) |c| {
        const p = (try parse.parse(arena.allocator(), c.args)).run;
        const r = request(&p, 5);
        try std.testing.expectEqual(c.mode, r.mode);
        try std.testing.expectEqual(c.delay, r.delay_s);
    }
}

test "every mode command names a mode" {
    const commands = @import("../../cli/commands.zig");
    for (&commands.all) |*c| if (c.group == .capture and c.id != .shot and c.id != .text and c.id != .timer) {
        try std.testing.expect(mode.Mode.parse(@tagName(c.id)) != null);
    };
}
