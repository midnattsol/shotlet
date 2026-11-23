//! `shotlet shot|text [OPTION...]` (src/cli/cmds_capture.zig lists the
//! options; the parser checked them). Development options: --from FILE
//! (no portal), --sel X,Y,W,H (an area selected), --smoke MS (cancel by
//! itself, for leak runs), --from-monitors A.png,B.png (one image per
//! monitor, side by side). The GNOME extension's hand-off: --from-shell
//! ID and its companions.

const std = @import("std");
const shot = @import("shot.zig");
const shell = @import("../platform/api.zig").shell;
const mode = @import("modes/mode.zig");
const Parsed = @import("../cli/parse.zig").Parsed;
const Env = @import("env.zig").Env;

pub fn run(gpa: std.mem.Allocator, env: Env, p: *const Parsed) !void {
    const handed = handedCapture(p);
    // the extension's record shortcut: the picker on this capture
    if (handed != null and p.value("then") != null) return @import("../record/cli.zig").fromShell(gpa, env, handed.?);
    const src: shot.From = .{ .file = p.value("from"), .monitors = p.value("from-monitors"), .shell = handed, .req = request(p) };
    try shot.run(gpa, env, src, p.rect("sel"), p.int(i64, "smoke") orelse 0);
}

/// The GNOME Shell extension's capture (api.shell.loadHanded).
fn handedCapture(p: *const Parsed) ?shell.HandedCapture {
    return .{
        .id = p.value("from-shell") orelse return null,
        .monitors = p.value("monitors") orelse "",
        .pieces = p.value("pieces") orelse "",
        .t0_ms = p.int(i64, "t0"),
    };
}

/// The mode the extension started (an unknown one: an area capture).
fn request(p: *const Parsed) mode.Request {
    return .{
        .mode = if (p.value("mode")) |m| mode.Mode.parse(m) orelse .area else .area,
        .pointer = p.pair(i32, "pointer"),
    };
}

test "the extension's hand-off reads from the command line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parse = @import("../cli/parse.zig");
    const p = (try parse.parse(arena.allocator(), &.{ "--from-shell", "7", "--monitors", "M", "--pieces", "P", "--t0", "123", "--mode", "window", "--pointer", "-20,300" })).run;
    const h = handedCapture(&p).?;
    try std.testing.expectEqualStrings("7", h.id);
    try std.testing.expectEqualStrings("M", h.monitors);
    try std.testing.expectEqual(@as(?i64, 123), h.t0_ms);
    const r = request(&p);
    try std.testing.expectEqual(mode.Mode.window, r.mode);
    try std.testing.expectEqual([2]i32{ -20, 300 }, r.pointer.?);
    const q = (try parse.parse(arena.allocator(), &.{ "shot", "--mode", "bogus" })).run;
    try std.testing.expectEqual(mode.Mode.area, request(&q).mode);
    try std.testing.expect(handedCapture(&q) == null);
}
