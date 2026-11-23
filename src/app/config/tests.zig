//! The one config file end to end: defaults, a round trip of every key,
//! the cliptux move on every loader, the per-section setters writing only
//! their key, and every older spelling a user's file can still hold.

const std = @import("std");
const config = @import("../config.zig");
const model = @import("model.zig");
const parse = @import("parse.zig");
const Config = model.Config;
const testing = std.testing;
const TmpDir = @import("../../testutil.zig").TmpDir;

/// The config file's text ("" when there is none).
fn readConfig(h: *const TmpDir) ![]u8 {
    return h.read(".config/shotlet/config") catch |err| switch (err) {
        error.NotFound => testing.allocator.dupe(u8, ""),
        else => err,
    };
}

fn expectFile(h: *const TmpDir, want: []const u8) !void {
    const data = try readConfig(h);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(want, data);
}

fn read(text: []const u8) Config {
    var cfg: Config = .{};
    _ = parse.applyText(&cfg, text);
    return cfg;
}

fn expectSame(a: *const Config, b: *const Config) !void {
    var ba: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    for (0..model.n_keys) |k| {
        try testing.expectEqualStrings(model.formatValue(a, k, &ba), model.formatValue(b, k, &bb));
    }
}

test "defaults: no file reads as every field's default and writes nothing" {
    var h = try TmpDir.home();
    defer h.deinit();
    var cfg = config.load(testing.allocator, h.path);
    try expectSame(&cfg, &Config{});
    try testing.expectEqual(config.Modes{}, cfg.modes);
    const r = cfg.record;
    try testing.expectEqual(@as(u32, 30), r.fps);
    try testing.expect(r.dir() == null and !r.mic);
    try config.save(testing.allocator, h.path, &cfg);
    try expectFile(&h, "");
}

test "every key round-trips through the file" {
    var h = try TmpDir.home();
    defer h.deinit();
    var cfg: Config = .{};
    _ = parse.applyText(&cfg,
        \\notify=false
        \\copy_on_save=true
        \\default_thickness=9
        \\default_color=5
        \\save_dir=~/Shots
        \\screencast_restore_token=tok
        \\beautify_always=true
        \\beautify_background=4
        \\beautify_padding=small
        \\beautify_corners=false
        \\beautify_shadow=false
        \\thumbnail=never
        \\quick_access_seconds=20
        \\history=false
        \\history_max=9
        \\history_max_mb=64
        \\loupe=always
        \\loupe_zoom=16
        \\after_fullscreen=save
        \\timer_seconds=10
        \\window_shadow=false
        \\scroll_max_height=30000
        \\scroll_auto=false
        \\record_format=gif
        \\record_fps=24
        \\record_quality=high
        \\record_mic=true
        \\record_system_audio=true
        \\record_clicks=true
        \\record_keys=true
        \\record_countdown=5
        \\record_gif_fps=20
        \\record_gif_width=640
        \\record_gif_dither=none
        \\record_dir=/media/rec
        \\shortcut_pen=Ctrl+F
        \\
    );
    // every fixed key differs from its default (hint_shown aside: never written)
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    for (0..model.n_fixed_keys) |k| {
        if (!model.writable(k)) continue;
        try testing.expect(!std.mem.eql(u8, model.formatValue(&cfg, k, &b1), model.formatValue(&Config{}, k, &b2)));
    }
    try config.save(testing.allocator, h.path, &cfg);
    const back = config.load(testing.allocator, h.path);
    try expectSame(&cfg, &back);
    try testing.expectEqualStrings("/media/rec", back.record.dir().?);
    try testing.expectEqual(config.After.save, back.modes.after);
}

/// Load, change one field, save: what Settings does for one control.
fn setOne(home: []const u8, comptime field: []const u8, comptime section: []const u8, value: anytype) !void {
    var cfg = config.load(testing.allocator, home);
    @field(@field(cfg, section), field) = value;
    try config.save(testing.allocator, home, &cfg);
}

test "a changed field writes its key alone, through the one save" {
    var h = try TmpDir.home();
    defer h.deinit();
    try h.write(".config/shotlet/config", "# mine\nnotify=false\nfuture_option=1\n");
    try setOne(h.path, "after", "modes", config.After.copy);
    try setOne(h.path, "timer_s", "modes", @as(u8, 10));
    try setOne(h.path, "mic", "record", true);
    try setOne(h.path, "fps", "record", @as(u32, 24));
    try expectFile(&h, "# mine\nnotify=false\nfuture_option=1\nafter_fullscreen=copy\ntimer_seconds=10\nrecord_mic=true\nrecord_fps=24\n");
    try testing.expectEqual(config.After.copy, config.load(testing.allocator, h.path).modes.after);
    try testing.expect(config.load(testing.allocator, h.path).record.mic);
    // setting a value back to the default writes it too
    try setOne(h.path, "timer_s", "modes", @as(u8, 5));
    try testing.expectEqual(@as(u8, 5), config.load(testing.allocator, h.path).modes.timer_s);
}

test "loading carries a cliptux configuration over, every section" {
    var h = try TmpDir.home();
    defer h.deinit();
    try h.write(".config/cliptux/config", "timer_seconds=3\nrecord_fps=60\nnotify=false\n");
    const cfg = config.load(testing.allocator, h.path);
    try testing.expect(!cfg.notify);
    try testing.expectEqual(@as(u8, 3), cfg.modes.timer_s);
    try testing.expectEqual(@as(u32, 60), cfg.record.fps);
    try expectFile(&h, "timer_seconds=3\nrecord_fps=60\nnotify=false\n");
}

test "older files: the bools Shotlet wrote, for every bool key" {
    inline for (model.fixed_keys) |k| {
        if (k.kind == .flag and !k.read_only) {
            var buf: [64]u8 = undefined;
            for ([_]bool{ true, false }) |v| {
                const line = try std.fmt.bufPrint(&buf, "{s}={s}\n", .{ k.name, if (v) "true" else "false" });
                const cfg = read(line);
                var vb: [64]u8 = undefined;
                try testing.expectEqualStrings(if (v) "true" else "false", model.formatValue(&cfg, model.Fixed.index(k.name), &vb));
            }
        }
    }
}

test "older files: a value no bool spells keeps the default" {
    // each model once had its own rule: default-off keys took only "true",
    // default-on keys anything but "false"; both read the same now
    const cfg = read("copy_on_save=on-ish\nhistory=enabled\nrecord_mic=TRUE\nwindow_shadow=0\nbeautify_corners=no\n");
    try testing.expect(!cfg.copy_on_save and cfg.history and cfg.record.mic);
    try testing.expect(!cfg.modes.window_shadow and !cfg.beautify_corners);
}

test "older files: superseded keys and spellings" {
    // the first-run hint: still read, never written
    var cfg = read("hint_shown=true\n");
    try testing.expect(cfg.hint_shown);
    cfg = read("hint_shown=false\n");
    try testing.expect(!cfg.hint_shown);
    // the quick-access switch: off is never, on the default
    cfg = read("quick_access=false\n");
    try testing.expectEqual(config.Thumbnail.never, cfg.thumbnail);
    cfg = read("quick_access=true\n");
    try testing.expectEqual(config.Thumbnail.after_save, cfg.thumbnail);
    // a later thumbnail line wins
    cfg = read("quick_access=false\nthumbnail=after_copy_and_save\n");
    try testing.expectEqual(config.Thumbnail.after_copy_and_save, cfg.thumbnail);
    // single-monitor tokens and the carried-over beautify are not read
    cfg = read("screencast_token=old\nbeautify=true\n");
    try testing.expect(cfg.scToken() == null and !cfg.beautify_always);
    // malformed numbers keep the default; out-of-range ones are clamped
    cfg = read("default_color=x\ndefault_thickness=99\nhistory_max=0\nrecord_countdown=60\nrecord_gif_width=99999\n");
    try testing.expectEqual(@as(u3, 0), cfg.default_color);
    try testing.expectEqual(@as(i32, 32), cfg.default_thickness);
    try testing.expectEqual(@as(u16, 1), cfg.history_max);
    try testing.expectEqual(@as(u32, 10), cfg.record.countdown);
    try testing.expectEqual(@as(u32, 8192), cfg.record.gif_width);
}

test "older files: quick_access is written anew as thumbnail, hint_shown left alone" {
    var h = try TmpDir.home();
    defer h.deinit();
    try h.write(".config/shotlet/config", "quick_access=false\nhint_shown=true\nscreencast_token=x\nbeautify=true\n");
    const stateflag = @import("../stateflag.zig");
    try testing.expect(!stateflag.isSet(h.path, .editor_hint));
    var cfg = config.load(testing.allocator, h.path);
    // the hint shown becomes the state flag
    try testing.expect(stateflag.isSet(h.path, .editor_hint));
    try testing.expectEqual(config.Thumbnail.never, cfg.thumbnail);
    cfg.notify = false;
    try config.save(testing.allocator, h.path, &cfg);
    try expectFile(&h, "hint_shown=true\nbeautify=true\nnotify=false\nthumbnail=never\n");
    const back = config.load(testing.allocator, h.path);
    try testing.expect(back.hint_shown and back.thumbnail == .never);
}
