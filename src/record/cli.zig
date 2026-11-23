//! `shotlet record`: pick an area (or the whole screen) and record it,
//! or control the recording under way (--stop, --pause, --resume,
//! --discard). src/cli/cmds_record.zig lists the options; the parser
//! checked them. While a recording runs, `shotlet record` again stops
//! it (so one shortcut starts and stops).

const std = @import("std");
const desktop = @import("../platform/api.zig").desktop;
const media = @import("../platform/api.zig").record;
const shell = @import("../platform/api.zig").shell;
const env_mod = @import("../app/env.zig");
const settings_mod = @import("settings.zig");
const region = @import("region.zig");
const ctlsock = @import("ctlsock.zig");
const run_mod = @import("run.zig");
const picker = @import("../ui/recui/picker.zig");
const capture = @import("../app/capture.zig");
const config = @import("../app/config.zig");
const shot = @import("../app/shot.zig");
const text = @import("../gfx/text.zig");
const theme = @import("../ui/theme.zig");
const out = @import("../cli/out.zig");
const Parsed = @import("../cli/parse.zig").Parsed;
const Env = env_mod.Env;

pub const Args = struct {
    area: ?region.Rect = null,
    full: bool = false,
    seconds: ?u32 = null,
    out: ?[]const u8 = null,
    control: bool = true,
    /// a command for the running recording ("stop", "pause", ...)
    command: ?[]const u8 = null,
};

/// The command line's options (src/cli/cmds_record.zig) as `Args` and
/// the settings they override.
pub fn options(p: *const Parsed, set: *settings_mod.Settings) Args {
    var a: Args = .{
        .full = p.flag("full"),
        .seconds = p.int(u32, "seconds"),
        .out = p.value("out"),
        .control = !p.flag("no-control"),
    };
    if (p.rect("region")) |r| a.area = .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] };
    if (p.last(&.{ "stop", "pause", "resume", "discard" })) |o| a.command = o.option.long;
    if (p.last(&.{ "format", "gif", "mp4" })) |o| set.format = if (o.value) |v|
        std.meta.stringToEnum(@TypeOf(set.format), v).?
    else
        std.meta.stringToEnum(@TypeOf(set.format), o.option.long).?;
    // the format is known by now, whatever the order: --fps is its rate
    if (p.value("fps")) |v| set.apply(if (set.format == .gif) "record_gif_fps" else "record_fps", v);
    if (p.flag("mic")) set.mic = true;
    if (p.flag("system-audio")) set.system_audio = true;
    if (p.flag("clicks")) set.clicks = true;
    if (p.flag("keys")) set.keys = true;
    if (p.flag("no-countdown")) set.countdown = 0;
    return a;
}

/// `shotlet record [OPTION...]`
pub fn main(gpa: std.mem.Allocator, env: Env, p: *const Parsed) !void {
    var set = settings_mod.load(gpa, env.home);
    const a = options(p, &set);
    var ans: [64]u8 = undefined;
    if (a.command) |c| {
        const r = ctlsock.send(env.runtime_dir, env.session.tag(), c, &ans) orelse
            out.fail(.failure, "no recording under way", .{});
        out.say("{s}\n", .{r});
        return;
    }
    // the same shortcut again: stop the recording under way
    if (ctlsock.send(env.runtime_dir, env.session.tag(), "stop", &ans)) |r| {
        std.log.info("record: stopped the recording under way ({s})", .{r});
        return;
    }
    if (a.area != null or a.full) return run_mod.run(gpa, env, a, set, null);
    try pickThenRun(gpa, env, a, set);
}

/// The picker on a capture of the desktop: taken by the GNOME Shell
/// extension (which then starts `shotlet --from-shell ... --then record`),
/// else as for screenshots (direct or the portal).
fn pickThenRun(gpa: std.mem.Allocator, env: Env, a: Args, set: settings_mod.Settings) !void {
    var bus = try desktop.connectBrief(gpa, env);
    defer bus.deinit();
    if (media.pickInShell(gpa, &bus)) return;
    var cfg = config.load(gpa, env.home);
    desktop.identify(gpa, &bus);
    var cap = (try shot.acquire(gpa, env, &bus, &cfg, .{})) orelse return;
    defer cap.deinit(gpa);
    try pickOn(gpa, env, a, set, &cap, false);
}

/// `shotlet --from-shell ID ... --then record`
pub fn fromShell(gpa: std.mem.Allocator, env: Env, args: shell.HandedCapture) !void {
    var cap = try shell.loadHanded(gpa, env, args);
    defer cap.deinit(gpa);
    try pickOn(gpa, env, .{}, settings_mod.load(gpa, env.home), &cap, true);
}

/// The picker on a capture already taken (the editor's Record mode).
pub fn pickOnCapture(gpa: std.mem.Allocator, env: Env, cap: *const capture.Capture, overlays: bool) !void {
    try pickOn(gpa, env, .{}, settings_mod.load(gpa, env.home), cap, overlays);
}

fn pickOn(gpa: std.mem.Allocator, env: Env, a: Args, set0: settings_mod.Settings, cap: *const capture.Capture, overlays: bool) !void {
    var set = set0;
    text.init(gpa);
    std.log.info("record: picker up", .{});
    const res = picker.pick(gpa, env, cap, &set, overlays, theme.load(gpa, env, 300));
    text.deinit();
    const area = switch (try res) {
        .area => |r| r,
        .cancelled => {
            std.log.info("record: cancelled in the picker", .{});
            return;
        },
    };
    saveChoices(gpa, env.home, &set0, &set);
    std.log.info("record: picked {d},{d} {d}x{d}", .{ area.x, area.y, area.w, area.h });
    try run_mod.run(gpa, env, a, set, area);
}

/// Remember the bar's choices for next time.
fn saveChoices(gpa: std.mem.Allocator, home: []const u8, old: *const settings_mod.Settings, new: *const settings_mod.Settings) void {
    const tf = struct {
        fn f(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.f;
    if (old.format != new.format) settings_mod.save(gpa, home, "record_format", @tagName(new.format));
    if (old.mic != new.mic) settings_mod.save(gpa, home, "record_mic", tf(new.mic));
    if (old.system_audio != new.system_audio) settings_mod.save(gpa, home, "record_system_audio", tf(new.system_audio));
    if (old.clicks != new.clicks) settings_mod.save(gpa, home, "record_clicks", tf(new.clicks));
    if (old.keys != new.keys) settings_mod.save(gpa, home, "record_keys", tf(new.keys));
}

fn parsed(arena: std.mem.Allocator, args: []const [:0]const u8) !Parsed {
    return (try @import("../cli/parse.zig").parse(arena, args)).run;
}

test "record options read from the command line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: settings_mod.Settings = .{};
    const a = options(&try parsed(arena.allocator(), &.{ "record", "--region", "10,20,300,200", "--gif", "--fps", "12", "--seconds", "2", "--no-countdown", "--keys" }), &s);
    try std.testing.expectEqual(region.Rect{ .x = 10, .y = 20, .w = 300, .h = 200 }, a.area.?);
    try std.testing.expectEqual(@as(u32, 12), s.gif_fps);
    try std.testing.expectEqual(@as(?u32, 2), a.seconds);
    try std.testing.expectEqual(@as(u32, 0), s.countdown);
    try std.testing.expect(s.keys and !s.clicks and a.control and !a.full);
    const b = options(&try parsed(arena.allocator(), &.{ "record", "--pause", "--stop" }), &s);
    try std.testing.expectEqualStrings("stop", b.command.?);
    _ = options(&try parsed(arena.allocator(), &.{ "record", "--gif", "--format", "mp4" }), &s);
    try std.testing.expectEqual(.mp4, s.format);
}

test "record --fps is the chosen format's rate, before or after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: settings_mod.Settings = .{};
    _ = options(&try parsed(arena.allocator(), &.{ "record", "--fps", "20", "--gif" }), &s);
    try std.testing.expectEqual(.gif, s.format);
    try std.testing.expectEqual(@as(u32, 20), s.gif_fps);
    try std.testing.expectEqual(@as(u32, 30), s.fps);
    var m: settings_mod.Settings = .{ .format = .gif };
    _ = options(&try parsed(arena.allocator(), &.{ "record", "--fps", "50", "--format", "mp4" }), &m);
    try std.testing.expectEqual(@as(u32, 50), m.fps);
    try std.testing.expectEqual(@as(u32, 15), m.gif_fps);
}
