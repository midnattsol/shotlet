//! Recording settings (Config.record), the `record_*` keys:
//!
//!     record_format=mp4|gif       record_fps=30 (MP4: 15..60)
//!     record_quality=low|medium|high
//!     record_mic=false            record_system_audio=false
//!     record_clicks=false         record_keys=false   (GNOME)
//!     record_countdown=3          (seconds, 0: none; at most 10)
//!     record_gif_fps=15 (10..30)  record_gif_width=800 (0: full size)
//!     record_gif_dither=ordered|floyd|none
//!     record_dir=                 (default: the Videos folder)

const std = @import("std");
const keys = @import("keys.zig");
const sink = @import("../../encode/sink.zig");
const quantize = @import("../../encode/quantize.zig");

pub const Record = struct {
    format: sink.Format = .mp4,
    fps: u32 = 30,
    quality: sink.Quality = .medium,
    mic: bool = false,
    system_audio: bool = false,
    clicks: bool = false,
    keys: bool = false,
    countdown: u32 = 3,
    gif_fps: u32 = 15,
    gif_width: u32 = 800,
    dither: quantize.Dither = .ordered,
    dir_buf: [512]u8 = @splat(0),
    dir_len: usize = 0,

    pub fn dir(self: *const Record) ?[]const u8 {
        return if (self.dir_len > 0) self.dir_buf[0..self.dir_len] else null;
    }

    /// The frame rate for the chosen format.
    pub fn rate(self: *const Record) u32 {
        return if (self.format == .gif) self.gif_fps else self.fps;
    }

    /// Set one `record_*` key as the config file would (unknown keys and
    /// malformed values change nothing).
    pub fn apply(self: *Record, key: []const u8, value: []const u8) void {
        _ = Section.apply(self, key, value);
    }
};

pub const table = [_]keys.Key{
    .{ .name = "record_format", .field = "format", .kind = .tag },
    .{ .name = "record_fps", .field = "fps", .kind = .{ .int = .{ .min = 15, .max = 60 } } },
    .{ .name = "record_quality", .field = "quality", .kind = .tag },
    .{ .name = "record_mic", .field = "mic", .kind = .flag },
    .{ .name = "record_system_audio", .field = "system_audio", .kind = .flag },
    .{ .name = "record_clicks", .field = "clicks", .kind = .flag },
    .{ .name = "record_keys", .field = "keys", .kind = .flag },
    .{ .name = "record_countdown", .field = "countdown", .kind = .{ .int = .{ .min = 0, .max = 10 } } },
    .{ .name = "record_gif_fps", .field = "gif_fps", .kind = .{ .int = .{ .min = 10, .max = 30 } } },
    .{ .name = "record_gif_width", .field = "gif_width", .kind = .{ .int = .{ .min = 0, .max = 8192 } } },
    .{ .name = "record_gif_dither", .field = "dither", .kind = .tag },
    .{ .name = "record_dir", .field = "dir_buf", .kind = .{ .text = "dir_len" } },
};

pub const Section = keys.Section(Record, &table);
