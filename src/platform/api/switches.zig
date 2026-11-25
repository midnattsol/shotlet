//! Development and test switches: every SHOTLET_* variable the program
//! reads, in one table (name, what it does, who reads it). main reads
//! them once at startup (`init`); everyone else asks `get()`, core and
//! backend alike, so no module reads the environment on its own.
//!
//! The locale categories ride along (`locale()`): they are not switches,
//! but the code that needs them (OCR languages, the compose table) has
//! no Env either.

const std = @import("std");

/// The switches' values. A flag is on when its variable is set at all
/// (`SHOTLET_NO_DIRECT=1`); a value is null when unset or empty.
pub const Switches = struct {
    no_direct: bool = false,
    no_layer_shell: bool = false,
    no_fractional: bool = false,
    no_cursor_shape: bool = false,
    no_shell_record: bool = false,
    no_libav: bool = false,
    no_vaapi: bool = false,
    no_ocr: bool = false,
    encoder: ?[]const u8 = null,
    ocr_lang: ?[]const u8 = null,
    dump_frame: ?[]const u8 = null,
    editor_dump: ?[]const u8 = null,
    editor_script: ?[]const u8 = null,
    settings_focus: ?[]const u8 = null,
    settings_view: ?[]const u8 = null,
    loop_stats: bool = false,
};

pub const Entry = struct {
    /// the environment variable
    name: []const u8,
    /// its field in Switches
    field: []const u8,
    doc: []const u8,
    /// the module that acts on it
    consumer: []const u8,
};

/// Every switch. Adding one: a field above and a row here; the test below
/// keeps them in step.
pub const table = [_]Entry{
    .{ .name = "SHOTLET_NO_DIRECT", .field = "no_direct", .doc = "never capture straight from the compositor (ext-image-copy / wlr-screencopy / KWin): portal or GNOME integration only", .consumer = "platform/linux/capture.zig, capture/perms/now.zig, capture/scroll_support.zig" },
    .{ .name = "SHOTLET_NO_LAYER_SHELL", .field = "no_layer_shell", .doc = "ignore wlr-layer-shell: floating windows become plain toplevels", .consumer = "platform/linux/window/registry.zig" },
    .{ .name = "SHOTLET_NO_FRACTIONAL", .field = "no_fractional", .doc = "ignore wp-fractional-scale: integer buffer scales only", .consumer = "platform/linux/window/registry.zig" },
    .{ .name = "SHOTLET_NO_CURSOR_SHAPE", .field = "no_cursor_shape", .doc = "ignore cursor-shape-v1: Shotlet draws its own cursors", .consumer = "platform/linux/window/registry.zig" },
    .{ .name = "SHOTLET_NO_SHELL_RECORD", .field = "no_shell_record", .doc = "record through the ScreenCast portal even when the GNOME integration could record", .consumer = "platform/linux/record/source.zig" },
    .{ .name = "SHOTLET_NO_LIBAV", .field = "no_libav", .doc = "do not load the FFmpeg libraries (recordings use the ffmpeg program)", .consumer = "encode/av.zig" },
    .{ .name = "SHOTLET_NO_VAAPI", .field = "no_vaapi", .doc = "no VA-API hardware encoding through the ffmpeg program", .consumer = "encode/ffmpeg_proc.zig" },
    .{ .name = "SHOTLET_NO_OCR", .field = "no_ocr", .doc = "do not load Tesseract: no text recognition or search", .consumer = "ocr/tesseract.zig" },
    .{ .name = "SHOTLET_ENCODER", .field = "encoder", .doc = "libav|ffmpeg: force one MP4 encoder path", .consumer = "encode/sink.zig" },
    .{ .name = "SHOTLET_OCR_LANG", .field = "ocr_lang", .doc = "Tesseract languages, e.g. eng+spa (default: the desktop's language plus English)", .consumer = "ocr/tesseract.zig" },
    .{ .name = "SHOTLET_DUMP_FRAME", .field = "dump_frame", .doc = "/path/prefix: each window surface's last frame is written to <prefix>-<n>.png when it closes", .consumer = "platform/linux/window/dump.zig" },
    .{ .name = "SHOTLET_EDITOR_DUMP", .field = "editor_dump", .doc = "/path/prefix: the editor writes every pane's last frame and the export at exit", .consumer = "ui/editor/session.zig" },
    .{ .name = "SHOTLET_EDITOR_SCRIPT", .field = "editor_script", .doc = "scripted editor input, `;`-separated (ui/script_input.zig); turns animations off", .consumer = "ui/editor/session.zig" },
    .{ .name = "SHOTLET_SETTINGS_FOCUS", .field = "settings_focus", .doc = "n: Settings starts with its n-th control focused", .consumer = "ui/settings/app.zig" },
    .{ .name = "SHOTLET_LOOP_STATS", .field = "loop_stats", .doc = "log, as each window closes, its frame times (p50, p95, max) and the longest time the event loop stayed away from the compositor", .consumer = "platform/linux/window/loopstats.zig" },
    .{ .name = "SHOTLET_SETTINGS_VIEW", .field = "settings_view", .doc = "general|editor|shortcuts|recording: the view Settings starts on", .consumer = "ui/settings/app.zig" },
};

/// The locale categories (POSIX order of precedence: LC_ALL, then the
/// category, then LANG).
pub const Locale = struct {
    lc_all: ?[]const u8 = null,
    lc_ctype: ?[]const u8 = null,
    lc_messages: ?[]const u8 = null,
    lang: ?[]const u8 = null,

    pub const Category = enum { ctype, messages };

    /// The locale in effect for `c` ("es_ES.UTF-8"), or null for "C".
    pub fn of(self: *const Locale, c: Category) ?[]const u8 {
        return self.lc_all orelse switch (c) {
            .ctype => self.lc_ctype,
            .messages => self.lc_messages,
        } orelse self.lang;
    }
};

var current: Switches = .{};
var current_locale: Locale = .{};

/// Read every switch and the locale from `vars` (anything with
/// `get(name) ?[]const u8`, e.g. std.process.Environ.Map). Called once
/// by main before anything else runs; tests may call `set` instead.
pub fn init(vars: anytype) void {
    current = read(vars);
    current_locale = .{
        .lc_all = nonEmpty(vars.get("LC_ALL")),
        .lc_ctype = nonEmpty(vars.get("LC_CTYPE")),
        .lc_messages = nonEmpty(vars.get("LC_MESSAGES")),
        .lang = nonEmpty(vars.get("LANG")),
    };
}

/// The switches in `vars`.
pub fn read(vars: anytype) Switches {
    var s: Switches = .{};
    inline for (table) |e| {
        const v = vars.get(e.name);
        switch (@TypeOf(@field(s, e.field))) {
            bool => @field(s, e.field) = v != null,
            ?[]const u8 => @field(s, e.field) = nonEmpty(v),
            else => @compileError("switch " ++ e.name ++ ": unsupported type"),
        }
    }
    return s;
}

/// The switches main read at startup.
pub fn get() *const Switches {
    return &current;
}

/// The locale categories main read at startup.
pub fn locale() *const Locale {
    return &current_locale;
}

/// Replace the switches (tests).
pub fn set(s: Switches) void {
    current = s;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

test "every switch has exactly one table row" {
    inline for (comptime std.meta.fieldNames(Switches)) |name| {
        comptime var rows = 0;
        inline for (table) |e| {
            if (comptime std.mem.eql(u8, e.field, name)) rows += 1;
        }
        try std.testing.expectEqual(1, rows);
    }
    inline for (table) |e| try std.testing.expect(std.mem.startsWith(u8, e.name, "SHOTLET_"));
}

test "flags are on when set, values only when not empty" {
    const Vars = struct {
        fn get(_: @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "SHOTLET_NO_DIRECT")) return "0";
            if (std.mem.eql(u8, name, "SHOTLET_ENCODER")) return "ffmpeg";
            if (std.mem.eql(u8, name, "SHOTLET_DUMP_FRAME")) return "";
            return null;
        }
    };
    const s = read(Vars{});
    try std.testing.expect(s.no_direct and !s.no_ocr);
    try std.testing.expectEqualStrings("ffmpeg", s.encoder.?);
    try std.testing.expect(s.dump_frame == null);
    const l: Locale = .{ .lc_messages = "es_ES.UTF-8", .lang = "en_US.UTF-8" };
    try std.testing.expectEqualStrings("es_ES.UTF-8", l.of(.messages).?);
    try std.testing.expectEqualStrings("en_US.UTF-8", l.of(.ctype).?);
}
