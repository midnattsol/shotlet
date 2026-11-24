//! `shotlet record`: pick an area (or the whole screen) and record it,
//! or control the recording under way (--stop, --pause, --resume,
//! --discard). src/cli/cmds_record.zig lists the options; the parser
//! checked them. While a recording runs, `shotlet record` again stops
//! it (so one shortcut starts and stops).

const std = @import("std");
const log = std.log.scoped(.record);
const desktop = @import("../platform/api.zig").desktop;
const media = @import("../platform/api.zig").record;
const shell = @import("../platform/api.zig").shell;
const env_mod = @import("../app/env.zig");
const geom = @import("../geom.zig");
const ctlsock = @import("ctlsock.zig");
const run_mod = @import("run.zig");
const picker = @import("../ui/recui/picker.zig");
const capture = @import("../app/capture.zig");
const config = @import("../app/config.zig");
const shot = @import("../app/shot.zig");
const refused = @import("../app/refused.zig");
const text = @import("../gfx/text.zig");
const theme = @import("../ui/theme.zig");
const out = @import("../cli/out.zig");
const Parsed = @import("../cli/parse.zig").Parsed;
const Env = env_mod.Env;
const Settings = config.Record;

pub const Args = struct {
    area: ?geom.Rect = null,
    full: bool = false,
    seconds: ?u32 = null,
    out: ?[]const u8 = null,
    control: bool = true,
    /// a command for the running recording ("stop", "pause", ...)
    command: ?[]const u8 = null,
};

/// The command line's options (src/cli/cmds_record.zig) as `Args` and
/// the settings they override. `--fps` is the chosen format's rate
/// (whatever the order): error.FpsOutOfRange outside its fpsRange.
pub fn options(p: *const Parsed, set: *Settings) error{FpsOutOfRange}!Args {
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
    if (p.int(u32, "fps")) |v| if (!set.setRate(v)) return error.FpsOutOfRange;
    if (p.flag("mic")) set.mic = true;
    if (p.flag("system-audio")) set.system_audio = true;
    if (p.flag("clicks")) set.clicks = true;
    if (p.flag("keys")) set.keys = true;
    if (p.flag("no-countdown")) set.countdown = 0;
    return a;
}

/// `shotlet record [OPTION...]`
pub fn main(gpa: std.mem.Allocator, env: Env, p: *const Parsed) !void {
    var cfg = config.load(gpa, env.home);
    // the settings for this recording; cfg keeps what the file says
    var set = cfg.record;
    const a = options(p, &set) catch {
        const r = @import("../app/config/record.zig").fpsRange(set.format);
        out.fail(.usage, "invalid value '{s}' for --fps: {s} records at {d} to {d}", .{ p.value("fps").?, formatName(set.format), r.min, r.max });
    };
    var ans: [64]u8 = undefined;
    if (a.command) |c| {
        const r = ctlsock.send(env.runtime_dir, env.session.tag(), c, &ans) orelse
            out.fail(.failure, "no recording under way", .{});
        out.say("{s}\n", .{r});
        return;
    }
    // the same shortcut again: stop the recording under way
    if (ctlsock.send(env.runtime_dir, env.session.tag(), "stop", &ans)) |r| {
        log.info("stopped the recording under way ({s})", .{r});
        return;
    }
    if (a.area != null or a.full) return run_mod.run(gpa, env, a, set, null);
    try pickThenRun(gpa, env, a, set, &cfg);
}

fn formatName(f: @import("../encode/sink.zig").Format) []const u8 {
    return switch (f) {
        .mp4 => "MP4",
        .gif => "GIF",
    };
}

/// The picker on a capture of the desktop: taken by the GNOME Shell
/// extension (which then starts `shotlet --from-shell ... --then record`),
/// else as for screenshots (direct or the portal).
fn pickThenRun(gpa: std.mem.Allocator, env: Env, a: Args, set: Settings, cfg: *config.Config) !void {
    var bus = try desktop.connectBrief(gpa, env);
    defer bus.deinit();
    if (media.pickInShell(gpa, &bus)) return;
    _ = refused.tell(gpa, env, &bus);
    desktop.identify(gpa, &bus);
    var cap = (try shot.acquire(gpa, env, &bus, cfg, .{}, null)) orelse return;
    defer cap.deinit(gpa);
    try pickOn(gpa, env, a, set, cfg, &cap, false);
}

/// `shotlet --from-shell ID ... --then record`
pub fn fromShell(gpa: std.mem.Allocator, env: Env, args: shell.HandedCapture) !void {
    var cap = try shell.loadHanded(gpa, env, args);
    defer cap.deinit(gpa);
    var cfg = config.load(gpa, env.home);
    try pickOn(gpa, env, .{}, cfg.record, &cfg, &cap, true);
}

/// The picker on a capture already taken (the editor's Record mode).
pub fn pickOnCapture(gpa: std.mem.Allocator, env: Env, cap: *const capture.Capture, overlays: bool) !void {
    var cfg = config.load(gpa, env.home);
    try pickOn(gpa, env, .{}, cfg.record, &cfg, cap, overlays);
}

/// The picker with `set0`, then the recording; the bar's choices are
/// kept in `cfg`'s file.
fn pickOn(gpa: std.mem.Allocator, env: Env, a: Args, set0: Settings, cfg: *config.Config, cap: *const capture.Capture, overlays: bool) !void {
    var set = set0;
    text.init(gpa);
    log.info("picker up", .{});
    const res = picker.pick(gpa, env, cap.frozen(), &set, overlays, theme.load(gpa, env, 300));
    text.deinit();
    const area = switch (try res) {
        .area => |r| r,
        .cancelled => {
            log.info("cancelled in the picker", .{});
            return;
        },
    };
    if (takeChoices(&cfg.record, &set0, &set)) config.save(gpa, env.home, cfg) catch |err|
        log.warn("could not save the recording choices: {t}", .{err});
    log.info("picked {d},{d} {d}x{d}", .{ area.x, area.y, area.w, area.h });
    try run_mod.run(gpa, env, a, set, area);
}

/// The choices the picker's bar changed (from `old` to `new`) into
/// `kept`, to remember them for next time; false when there were none.
/// What the command line set for this recording only stays out.
fn takeChoices(kept: *Settings, old: *const Settings, new: *const Settings) bool {
    var changed = false;
    inline for (.{ "format", "mic", "system_audio", "clicks", "keys" }) |f| {
        if (@field(old, f) != @field(new, f)) {
            @field(kept, f) = @field(new, f);
            changed = true;
        }
    }
    return changed;
}

fn parsed(arena: std.mem.Allocator, args: []const [:0]const u8) !Parsed {
    return (try @import("../cli/parse.zig").parse(arena, args)).run;
}

test "record options read from the command line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: Settings = .{};
    const a = try options(&try parsed(arena.allocator(), &.{ "record", "--region", "10,20,300,200", "--gif", "--fps", "12", "--seconds", "2", "--no-countdown", "--keys" }), &s);
    try std.testing.expectEqual(geom.Rect{ .x = 10, .y = 20, .w = 300, .h = 200 }, a.area.?);
    try std.testing.expectEqual(@as(u32, 12), s.gif_fps);
    try std.testing.expectEqual(@as(?u32, 2), a.seconds);
    try std.testing.expectEqual(@as(u32, 0), s.countdown);
    try std.testing.expect(s.keys and !s.clicks and a.control and !a.full);
    const b = try options(&try parsed(arena.allocator(), &.{ "record", "--pause", "--stop" }), &s);
    try std.testing.expectEqualStrings("stop", b.command.?);
    _ = try options(&try parsed(arena.allocator(), &.{ "record", "--gif", "--format", "mp4" }), &s);
    try std.testing.expectEqual(.mp4, s.format);
}

test "record --fps is the chosen format's rate, before or after it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s: Settings = .{};
    _ = try options(&try parsed(arena.allocator(), &.{ "record", "--fps", "20", "--gif" }), &s);
    try std.testing.expectEqual(.gif, s.format);
    try std.testing.expectEqual(@as(u32, 20), s.gif_fps);
    try std.testing.expectEqual(@as(u32, 30), s.fps);
    var m: Settings = .{ .format = .gif };
    _ = try options(&try parsed(arena.allocator(), &.{ "record", "--fps", "50", "--format", "mp4" }), &m);
    try std.testing.expectEqual(@as(u32, 50), m.fps);
    try std.testing.expectEqual(@as(u32, 15), m.gif_fps);
}

test "record --fps outside the chosen format's rates is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const limits = @import("../app/config/record.zig");
    var s: Settings = .{};
    // the GIF's top rate is not the MP4's
    try std.testing.expectError(error.FpsOutOfRange, options(&try parsed(arena.allocator(), &.{ "record", "--gif", "--fps", "50" }), &s));
    try std.testing.expectEqual(@as(u32, 15), s.gif_fps);
    var m: Settings = .{};
    try std.testing.expectError(error.FpsOutOfRange, options(&try parsed(arena.allocator(), &.{ "record", "--fps", "12" }), &m));
    try std.testing.expectEqual(@as(u32, 30), m.fps);
    // each format's bounds are taken, the same ones the settings clamp to
    for ([_]@import("../encode/sink.zig").Format{ .mp4, .gif }) |f| {
        const r = limits.fpsRange(f);
        for ([_]u32{ r.min, r.max }) |v| {
            var t: Settings = .{ .format = f };
            var buf: [8]u8 = undefined;
            const n = std.fmt.bufPrintSentinel(&buf, "{d}", .{v}, 0) catch unreachable;
            _ = try options(&try parsed(arena.allocator(), &.{ "record", "--fps", n }), &t);
            try std.testing.expectEqual(v, t.rate());
            var c: Settings = .{ .format = f };
            c.apply(if (f == .gif) "record_gif_fps" else "record_fps", "1000");
            try std.testing.expectEqual(r.max, c.rate());
        }
    }
}

test "only the picker's choices are kept for next time" {
    var kept: Settings = .{};
    // the command line asked for a GIF with the microphone
    const old: Settings = .{ .format = .gif, .mic = true, .countdown = 0 };
    var new = old;
    try std.testing.expect(!takeChoices(&kept, &old, &new));
    new.keys = true;
    new.mic = false;
    try std.testing.expect(takeChoices(&kept, &old, &new));
    try std.testing.expect(kept.keys and !kept.mic);
    // what the bar left alone stays as the file has it
    try std.testing.expectEqual(.mp4, kept.format);
    try std.testing.expectEqual(@as(u32, 3), kept.countdown);
}
