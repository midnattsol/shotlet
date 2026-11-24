//! The desktop integration refused this Shotlet. GNOME's answers only the
//! binary it would start itself (the installed one), so a copy run from
//! elsewhere (zig-out/bin/shotlet, say) gets no prompt-free captures
//! (they fall back to the portal) and no scrolling capture at all. The
//! person is told plainly, once a run however many calls were refused,
//! through report.zig (a card on the screen, stderr, the log).

const std = @import("std");
const log = std.log.scoped(.capture);
const platform = @import("../platform/api.zig");
const shell = platform.shell;
const desktop = platform.desktop;
const report = @import("report.zig");
const Env = @import("env.zig").Env;

/// What a small surface (the scrolling capture's control) says instead.
pub const short_title = "Only the installed Shotlet can do this";
pub const short_hint = "Run that one, or reinstall";

var told = std.atomic.Value(bool).init(false);

/// Whether the integration refused this Shotlet, told once a run (true
/// from then on, without telling again). When the binary it answers is
/// not there either (a broken install), nothing would help the person
/// run "that one": only logged, and false.
pub fn tell(gpa: std.mem.Allocator, env: Env, bus: *desktop.Bus) bool {
    if (!shell.refusedCaller()) return false;
    if (told.load(.monotonic)) return true;
    var exe_buf: [1024]u8 = undefined;
    const exe = shell.servedExe(gpa, env, bus, &exe_buf) orelse {
        log.info("the {s} refused this Shotlet, and the one it answers is not there", .{shell.words().title});
        return false;
    };
    if (told.swap(true, .monotonic)) return true;
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "The {s} only answers the installed Shotlet", .{shell.words().title}) catch "The desktop integration only answers the installed Shotlet";
    var buf: [1100]u8 = undefined;
    report.problem(env, title, body(&buf, env.home, exe));
    return true;
}

/// "Run ~/.local/bin/shotlet, or reinstall": `exe` under `home` with a
/// tilde.
fn body(buf: []u8, home: []const u8, exe: []const u8) []const u8 {
    const under = home.len > 1 and exe.len > home.len and std.mem.startsWith(u8, exe, home) and exe[home.len] == '/';
    const tilde = if (under) "~" else "";
    const rest = if (under) exe[home.len..] else exe;
    return std.fmt.bufPrint(buf, "Run {s}{s}, or reinstall", .{ tilde, rest }) catch "Run the installed one, or reinstall";
}

test "the refusal names the binary the integration answers" {
    var buf: [200]u8 = undefined;
    try std.testing.expectEqualStrings("Run ~/.local/bin/shotlet, or reinstall", body(&buf, "/home/ana", "/home/ana/.local/bin/shotlet"));
    try std.testing.expectEqualStrings("Run /usr/bin/shotlet, or reinstall", body(&buf, "/home/ana", "/usr/bin/shotlet"));
    // a neighbour of the home folder is not under it
    try std.testing.expectEqualStrings("Run /home/anabel/shotlet, or reinstall", body(&buf, "/home/ana", "/home/anabel/shotlet"));
    var small: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Run the installed one, or reinstall", body(&small, "/h", "/h/a-long-path/shotlet"));
}
