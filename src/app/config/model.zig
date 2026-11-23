//! The configuration model: the Config struct (the one settings model of
//! the one config file: core settings, the capture modes, recording), its
//! keys (the fixed ones from keys.zig tables, plus one "shortcut_<action>"
//! per editor action) and how each key's value is serialized, plus the
//! per-key hash baseline save() compares against.

const std = @import("std");
const binds = @import("../binds.zig");
const Action = binds.Action;
const n_actions = binds.n_actions;
const Bind = binds.Bind;
const keys = @import("keys.zig");
const modes = @import("modes.zig");
const record = @import("record.zig");

pub const After = modes.After;
pub const Modes = modes.Modes;
pub const Record = record.Record;

/// When the floating thumbnail shows up.
pub const Thumbnail = enum {
    after_save,
    after_copy_and_save,
    never,

    pub fn label(t: Thumbnail) []const u8 {
        return switch (t) {
            .after_save => "After Save",
            .after_copy_and_save => "After Copy and Save",
            .never => "Never",
        };
    }
};

/// When the magnifier shows while choosing an area: while Ctrl is held
/// (hold); all the while pointing and dragging (always); or never.
pub const Loupe = enum {
    hold,
    always,
    never,

    pub fn label(l: Loupe) []const u8 {
        return switch (l) {
            .hold => "While Holding Ctrl",
            .always => "Always",
            .never => "Never",
        };
    }

    /// The setting a config value names; older files' values read as hold.
    pub fn parse(value: []const u8) ?Loupe {
        if (isLegacy(value)) return .hold;
        return std.meta.stringToEnum(Loupe, value);
    }

    /// What older files called the settings that are hold now: only while
    /// dragging (selecting), when the pointer slows down (auto).
    pub fn isLegacy(value: []const u8) bool {
        for ([_][]const u8{ "selecting", "auto" }) |v| if (std.mem.eql(u8, value, v)) return true;
        return false;
    }
};

/// The magnifier's zoom levels: screen pixels per captured pixel, at
/// scale 1 (the lens keeps its size: more zoom shows fewer pixels).
pub const loupe_zooms = [_]u8{ 4, 8, 12, 16 };
pub const loupe_zoom_default: u8 = 8;

/// The zoom level nearest `v`.
pub fn nearestZoom(v: i64) u8 {
    return @intCast(keys.nearest(&zoom_choices, v));
}

pub const Config = struct {
    /// desktop notification after saving, when no thumbnail says so
    notify: bool = true,
    /// also copy to clipboard when saving to disk
    copy_on_save: bool = false,
    /// default stroke thickness (logical px, scaled by the UI)
    default_thickness: i32 = 3,
    /// default palette color index
    default_color: u3 = 0,
    /// override save directory; empty = XDG pictures dir
    save_dir: [256]u8 = @splat(0),
    save_dir_len: usize = 0,
    /// editor keybindings, indexed by Action
    binds: [n_actions]Bind = binds.default_binds,
    /// ScreenCast restore token (silent re-capture after first consent)
    sc_token: [512]u8 = @splat(0),
    sc_token_len: usize = 0,
    /// every new capture starts with the "beautify" frame on (else each
    /// starts without it; its style below is remembered either way)
    beautify_always: bool = false,
    beautify_background: u8 = 0,
    /// 0 none, 1 small, 2 medium, 3 large
    beautify_padding: u2 = 2,
    beautify_corners: bool = true,
    beautify_shadow: bool = true,
    /// the editor's first-run hint was shown: only read from older
    /// files, and turned into the state flag by config.load
    /// (stateflag.zig)
    hint_shown: bool = false,
    /// the floating thumbnail with more actions: after which results
    thumbnail: Thumbnail = .after_save,
    /// how long the thumbnail stays (it stays while hovered)
    quick_access_seconds: u16 = 8,
    /// keep copied and saved captures in $XDG_STATE_HOME/shotlet/history
    history: bool = true,
    /// at most this many captures...
    history_max: u16 = 50,
    /// ...taking at most this many MiB
    history_max_mb: u32 = 500,
    /// the magnifier while choosing an area, and its zoom (one of
    /// loupe_zooms)
    loupe: Loupe = .hold,
    loupe_zoom: u8 = loupe_zoom_default,
    /// the capture modes (modes.zig)
    modes: Modes = .{},
    /// recording (record.zig)
    record: Record = .{},
    /// hash of every key's value as last loaded or saved; save() writes
    /// only keys whose value differs. All zero (a Config not read from
    /// disk) means every key is written.
    base: [n_keys]u64 = @splat(0),

    /// Whether a capture that was saved (else only copied) gets a
    /// thumbnail.
    pub fn showsThumbnail(self: *const Config, saved: bool) bool {
        return switch (self.thumbnail) {
            .after_save => saved,
            .after_copy_and_save => true,
            .never => false,
        };
    }

    /// Whether any capture gets a thumbnail.
    pub fn thumbnails(self: *const Config) bool {
        return self.thumbnail != .never;
    }

    pub fn saveDir(self: *const Config) ?[]const u8 {
        if (self.save_dir_len == 0) return null;
        return self.save_dir[0..self.save_dir_len];
    }

    pub fn scToken(self: *const Config) ?[]const u8 {
        if (self.sc_token_len == 0) return null;
        return self.sc_token[0..self.sc_token_len];
    }

    pub fn setScToken(self: *Config, token: []const u8) void {
        const n = @min(token.len, self.sc_token.len);
        @memcpy(self.sc_token[0..n], token[0..n]);
        self.sc_token_len = n;
    }
};

// --- keys ---

const zoom_choices = blk: {
    var out: [loupe_zooms.len]i64 = undefined;
    for (loupe_zooms, 0..) |z, i| out[i] = z;
    break :blk out;
};

/// The core settings' keys, in the order a fresh file lists them.
const core_keys = [_]keys.Key{
    .{ .name = "notify", .field = "notify", .kind = .flag },
    .{ .name = "copy_on_save", .field = "copy_on_save", .kind = .flag },
    .{ .name = "default_thickness", .field = "default_thickness", .kind = .{ .int = .{ .min = 1, .max = 32 } } },
    .{ .name = "default_color", .field = "default_color", .kind = .{ .int = .{ .min = 0, .max = 7 } } },
    .{ .name = "save_dir", .field = "save_dir", .kind = .{ .text = "save_dir_len" } },
    // tokens from before multi-monitor capture ("screencast_token") restore
    // a single-monitor selection forever, so they are not read any more
    .{ .name = "screencast_restore_token", .field = "sc_token", .kind = .{ .text = "sc_token_len" } },
    // "beautify" (the last capture's frame carried over to the next) is
    // not read any more: the frame is per capture unless "always"
    .{ .name = "beautify_always", .field = "beautify_always", .kind = .flag },
    .{ .name = "beautify_background", .field = "beautify_background", .kind = .{ .int = .{ .min = 0, .max = 255 } } },
    .{ .name = "beautify_padding", .field = "beautify_padding", .kind = .{ .names = &padding_names } },
    .{ .name = "beautify_corners", .field = "beautify_corners", .kind = .flag },
    .{ .name = "beautify_shadow", .field = "beautify_shadow", .kind = .flag },
    // the first-run hint is a state flag now (stateflag.zig)
    .{ .name = "hint_shown", .field = "hint_shown", .kind = .flag, .read_only = true },
    // "quick_access=false" from before still reads as never (parse.zig)
    .{ .name = "thumbnail", .field = "thumbnail", .kind = .tag },
    .{ .name = "quick_access_seconds", .field = "quick_access_seconds", .kind = .{ .int = .{ .min = 1, .max = 3600 } } },
    .{ .name = "history", .field = "history", .kind = .flag },
    .{ .name = "history_max", .field = "history_max", .kind = .{ .int = .{ .min = 1, .max = 10000 } } },
    .{ .name = "history_max_mb", .field = "history_max_mb", .kind = .{ .int = .{ .min = 1, .max = 1 << 20 } } },
    .{ .name = "loupe", .field = "loupe", .kind = .tag },
    .{ .name = "loupe_zoom", .field = "loupe_zoom", .kind = .{ .nearest = &zoom_choices } },
};

/// Every fixed key of the file: the core settings, then the modes' and
/// the recording's sections.
pub const fixed_keys = core_keys ++ keys.within("modes", &modes.table) ++ keys.within("record", &record.table);
pub const Fixed = keys.Section(Config, &fixed_keys);

pub const n_fixed_keys = fixed_keys.len;
/// an editor action's key: this, then the action's name
pub const bind_prefix = "shortcut_";
pub const n_keys = n_fixed_keys + n_actions;

pub const padding_names = [4][]const u8{ "none", "small", "medium", "large" };

/// Name of key `k` ("notify", ..., "shortcut_pen", ...).
pub fn keyName(k: usize) []const u8 {
    if (k < n_fixed_keys) return Fixed.name(k);
    const names = comptime @typeInfo(Action).@"enum".field_names;
    inline for (names, 0..) |fld_name, i| {
        if (k - n_fixed_keys == i) return bind_prefix ++ fld_name;
    }
    unreachable;
}

/// Whether save() writes key `k` (superseded keys are only read).
pub fn writable(k: usize) bool {
    return k >= n_fixed_keys or Fixed.writable(k);
}

/// Serialized value of key `k` in `cfg`.
pub fn formatValue(cfg: *const Config, k: usize, buf: []u8) []const u8 {
    if (k < n_fixed_keys) return Fixed.format(cfg, k, buf);
    return formatBind(cfg.binds[k - n_fixed_keys], buf);
}

/// "Ctrl+Shift+Z" (app/accel.zig's notation), or "none".
fn formatBind(b: Bind, buf: []u8) []const u8 {
    const a = b.toAccel() orelse return "none";
    return a.format(buf) orelse "none";
}

pub fn valueHash(v: []const u8) u64 {
    // never 0, so an all-zero `base` unambiguously means "nothing loaded"
    return std.hash.Wyhash.hash(0x5107, v) | 1;
}

/// Record every key's current value as the baseline for the next save.
pub fn rememberBase(cfg: *Config) void {
    var buf: [64]u8 = undefined;
    for (0..n_keys) |k| cfg.base[k] = valueHash(formatValue(cfg, k, &buf));
}

test "the keys' numbering" {
    try std.testing.expectEqualStrings("loupe", keyName(Fixed.index("loupe")));
    try std.testing.expectEqualStrings("record_dir", keyName(Fixed.index("record_dir")));
    try std.testing.expectEqualStrings("shortcut_pen", keyName(n_fixed_keys + @as(usize, @backingInt(Action.pen))));
    try std.testing.expect(!writable(Fixed.index("hint_shown")) and writable(Fixed.index("notify")));
    // every key has its own name
    for (0..n_keys) |a| for (a + 1..n_keys) |b| try std.testing.expect(!std.mem.eql(u8, keyName(a), keyName(b)));
}

test "the magnifier's zoom snaps to a level" {
    try std.testing.expectEqual(@as(u8, 8), nearestZoom(9));
    try std.testing.expectEqual(@as(u8, 4), nearestZoom(-3));
    try std.testing.expectEqual(@as(u8, 16), nearestZoom(400));
}
