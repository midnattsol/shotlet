//! Runs the command the command line named (src/cli/ parsed and checked
//! it, once: everything here reads the typed `Parsed`). The switch covers
//! every command of the table. A command that fails ends here with
//! "shotlet COMMAND: message" and status 1 (src/cli/out.zig).

const std = @import("std");
const Env = @import("env.zig").Env;
const Parsed = @import("../cli/parse.zig").Parsed;
const out = @import("../cli/out.zig");
const launch = @import("../ui/tools/launch.zig");
const platform = @import("../platform/api.zig");
const trimui = @import("../ui/recui/trimui.zig");
const shell = platform.shell;

pub fn run(gpa: std.mem.Allocator, env: Env, p: Parsed) !void {
    out.command = p.chain;
    dispatch(gpa, env, &p) catch |err| out.failWith(err);
}

fn dispatch(gpa: std.mem.Allocator, env: Env, p: *const Parsed) !void {
    switch (p.id()) {
        .shot, .text => try runShot(gpa, env, p),
        .area, .fullscreen, .screens, .previous, .window, .scroll, .timer => try @import("modes/cli.zig").run(gpa, env, p),
        .record => try @import("../record/cli.zig").main(gpa, env, p),
        .edit => try runEdit(gpa, env, p),
        .pin => if (p.arg(0)) |file|
            try @import("pin.zig").run(gpa, env, file, p.pair(i32, "at"))
        else
            try @import("clipimg.zig").pinClipboard(gpa, env),
        .history => try @import("history_ui.zig").run(gpa, env, smoke(p)),
        .history_clear => try clearHistory(env),
        .thumbnail => try @import("lastthumb.zig").run(gpa, env),
        .settings => try @import("../ui/settings.zig").run(gpa, env, smoke(p)),
        .daemon => try platform.desktop.daemon(gpa, env, p.flag("foreground")),
        .gnome_integration, .gnome_status, .gnome_install, .gnome_uninstall, .gnome_shortcut => try shell.runCli(gpa, env, shellCli(p)),
        .permissions, .permissions_reset => try platform.capture.permissionsCli(gpa, env, permissionsCli(p)),
        // answered by src/cli/front.zig
        .help, .completions, .man_page => unreachable,
        .quick => try @import("quick.zig").run(gpa, env, p.positionals[0], p.positionals[1], readyFd(p.argInt(i32, 2))),
        .quick_video => try @import("../record/quickvid.zig").run(gpa, env, p.positionals[0], p.positionals[1]),
        .trim => try trimui.run(gpa, env, p.positionals[0], p.positionals[1], trimOptions(p)),
        .toast => try @import("toastwin.zig").run(gpa, env, .{
            .kind = if (p.flag("info")) .info else .done,
            .title = p.positionals[0],
            .body = p.arg(1) orelse "",
        }),
        .test_window, .test_grab, .test_font, .test_decode => {
            _ = try platform.devtools(gpa, env, p.chain.items[0].name, p.positionals);
        },
    }
}

/// The shot or text capture; `shotlet --from-shell ...` is the GNOME
/// Shell extension starting one.
fn runShot(gpa: std.mem.Allocator, env: Env, p: *const Parsed) !void {
    if (p.shell_launch) {
        launch.takeHandOff(env.runtime_dir);
        // the extension runs: an install that waited for it can finish
        shell.finishPendingSetup(env);
    }
    // `shotlet text` is a capture whose region's text is copied
    if (p.id() == .text) launch.text_capture = true;
    try @import("shot_args.zig").run(gpa, env, p);
}

/// `edit FILE`, or `edit ROOT ID`: a history entry again (the thumbnail);
/// `--pin-fd FD`: a pin's Annotate, which FD answers.
fn runEdit(gpa: std.mem.Allocator, env: Env, p: *const Parsed) !void {
    launch.pin_fd = p.int(i32, "pin-fd");
    if (p.arg(1)) |id| return @import("shot.zig").runEdit(gpa, env, p.positionals[0], id);
    try @import("editfile.zig").run(gpa, env, p.positionals[0]);
}

/// `trim ROOT ID [--range A,B] [--export]`.
fn trimOptions(p: *const Parsed) trimui.Options {
    const r = p.pair(i64, "range");
    return .{
        .range = if (r) |v| .{ .start_ms = v[0], .end_ms = v[1] } else null,
        .headless = p.flag("export"),
    };
}

/// `gnome-integration [status|install|uninstall|shortcut]`.
fn shellCli(p: *const Parsed) shell.Cli {
    return switch (p.id()) {
        .gnome_install => .{ .install = installHow(p) },
        .gnome_uninstall => .uninstall,
        .gnome_shortcut => .{ .shortcut = p.positionals },
        else => .status,
    };
}

/// `permissions [reset [--dry-run]]`.
fn permissionsCli(p: *const Parsed) platform.capture.PermissionsCli {
    if (p.id() != .permissions_reset) return .status;
    return .{ .reset = .{ .dry_run = p.flag("dry-run") } };
}

/// Whether install moves the desktop's screenshot key (the last of
/// --move-shortcut and --keep-shortcut given), or asks.
fn installHow(p: *const Parsed) shell.Cli.Install {
    const o = p.last(&.{ "move-shortcut", "keep-shortcut" }) orelse return .ask;
    return if (std.mem.eql(u8, o.option.long, "move-shortcut")) .move_shortcut else .keep_shortcut;
}

fn clearHistory(env: Env) !void {
    const history = @import("history.zig");
    var buf: [1024]u8 = undefined;
    history.clear(try history.historyRoot(&buf, env.home));
    out.say("history cleared\n", .{});
}

/// `quick ROOT ID READY-FD`: the pipe the editor waits on, if any (-1:
/// none).
fn readyFd(fd: ?i32) ?i32 {
    const v = fd orelse return null;
    return if (v > 2) v else null;
}

/// `--smoke MS`: auto-close after MS (leak runs); 0 when absent.
fn smoke(p: *const Parsed) i64 {
    return p.int(i64, "smoke") orelse 0;
}

fn parsed(arena: std.mem.Allocator, args: []const [:0]const u8) !Parsed {
    return (try @import("../cli/parse.zig").parse(arena, args)).run;
}

test "gnome-integration reaches the integration typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(shell.Cli.status, shellCli(&try parsed(a, &.{"gnome-integration"})));
    try std.testing.expectEqual(shell.Cli.status, shellCli(&try parsed(a, &.{ "gnome-integration", "status" })));
    try std.testing.expectEqual(shell.Cli.uninstall, shellCli(&try parsed(a, &.{ "gnome-integration", "uninstall" })));
    const Case = struct { args: []const [:0]const u8, how: shell.Cli.Install };
    for ([_]Case{
        .{ .args = &.{ "gnome-integration", "install" }, .how = .ask },
        .{ .args = &.{ "gnome-integration", "install", "--move-shortcut" }, .how = .move_shortcut },
        .{ .args = &.{ "gnome-integration", "install", "--keep-shortcut" }, .how = .keep_shortcut },
        .{ .args = &.{ "gnome-integration", "install", "--keep-shortcut", "--move-shortcut" }, .how = .move_shortcut },
    }) |c| try std.testing.expectEqual(shell.Cli{ .install = c.how }, shellCli(&try parsed(a, c.args)));
    const sc = shellCli(&try parsed(a, &.{ "gnome-integration", "shortcut", "window", "Ctrl+Alt+W" }));
    try std.testing.expectEqual(@as(usize, 2), sc.shortcut.len);
    try std.testing.expectEqualStrings("window", sc.shortcut[0]);
    try std.testing.expectEqualStrings("Ctrl+Alt+W", sc.shortcut[1]);
    try std.testing.expectEqual(@as(usize, 0), shellCli(&try parsed(a, &.{ "gnome-integration", "shortcut" })).shortcut.len);
}

test "permissions reaches the backend typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Cli = platform.capture.PermissionsCli;
    try std.testing.expectEqual(Cli.status, permissionsCli(&try parsed(a, &.{"permissions"})));
    try std.testing.expectEqual(Cli{ .reset = .{} }, permissionsCli(&try parsed(a, &.{ "permissions", "reset" })));
    try std.testing.expectEqual(Cli{ .reset = .{ .dry_run = true } }, permissionsCli(&try parsed(a, &.{ "permissions", "reset", "--dry-run" })));
}

test "trim's range and export arrive typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = trimOptions(&try parsed(a, &.{ "trim", "/r", "20260101-000000-001" }));
    try std.testing.expect(none.range == null and !none.headless);
    const both = trimOptions(&try parsed(a, &.{ "trim", "/r", "20260101-000000-001", "--range", "1000,2500", "--export" }));
    try std.testing.expectEqual(@as(i64, 1000), both.range.?.start_ms);
    try std.testing.expectEqual(@as(i64, 2500), both.range.?.end_ms);
    try std.testing.expect(both.headless);
}
