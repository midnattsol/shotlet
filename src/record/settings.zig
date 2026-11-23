//! Recording settings: a section of the one config (config.Record,
//! app/config/record.zig lists the `record_*` keys), read with config.load
//! and written with config.save; plus where recordings go.

const std = @import("std");
const config = @import("../app/config.zig");
const env_mod = @import("../app/env.zig");

pub const Settings = config.Record;

/// Where recordings go: record_dir, else the Videos folder
/// (env.userDir: $XDG_VIDEOS_DIR, user-dirs.dirs, else ~/Videos; a value
/// equal to $HOME means none).
pub fn outputDir(gpa: std.mem.Allocator, s: *const Settings, home: []const u8, buf: []u8) ![]u8 {
    if (s.dir()) |d| return env_mod.expandHome(buf, home, d);
    return env_mod.userDir(gpa, buf, home, .videos);
}

test "recording settings read with limits" {
    var cfg: config.Config = .{};
    _ = @import("../app/config/parse.zig").applyText(&cfg, "save_dir=~/x\nrecord_format=gif\nrecord_fps=120\nrecord_gif_fps=5\nrecord_mic=true\nrecord_quality=high\nrecord_gif_dither=floyd\nrecord_countdown=0\n# record_keys=true\nrecord_dir=~/clips\n");
    const s = cfg.record;
    try std.testing.expectEqual(@import("../encode/sink.zig").Format.gif, s.format);
    try std.testing.expectEqual(@as(u32, 60), s.fps);
    try std.testing.expectEqual(@as(u32, 10), s.gif_fps);
    try std.testing.expectEqual(@as(u32, 10), s.rate());
    try std.testing.expect(s.mic and !s.keys);
    try std.testing.expectEqual(@import("../encode/sink.zig").Quality.high, s.quality);
    try std.testing.expectEqual(@import("../encode/quantize.zig").Dither.floyd, s.dither);
    try std.testing.expectEqual(@as(u32, 0), s.countdown);
    try std.testing.expectEqualStrings("~/clips", s.dir().?);
    var d: Settings = .{};
    d.apply("record_format", "webm");
    try std.testing.expectEqual(@import("../encode/sink.zig").Format.mp4, d.format);
}

test "recordings go to record_dir, else the Videos folder" {
    const saved = env_mod.xdg;
    defer env_mod.xdg = saved;
    env_mod.xdg = .{ .videos_dir = "/media/films" };
    var buf: env_mod.PathBuf = undefined;
    var s: Settings = .{};
    try std.testing.expectEqualStrings("/media/films", try outputDir(std.testing.allocator, &s, "/home/u", &buf));
    s.apply("record_dir", "~/clips");
    try std.testing.expectEqualStrings("/home/u/clips", try outputDir(std.testing.allocator, &s, "/home/u", &buf));
}
