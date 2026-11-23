//! The table's internal commands: Shotlet starts them itself (the
//! thumbnail, the video thumbnail, the trimmer, toasts), the build runs
//! man-page, and test-* are for development. Hidden from the overview
//! and the completions; their arguments are checked like any other's.

const spec = @import("spec.zig");

const root: spec.Arg = .{ .name = "ROOT", .kind = .file, .required = true, .help = "The history directory" };
const id: spec.Arg = .{ .name = "ID", .required = true, .help = "The entry in it" };

const Takes = struct {
    args: []const spec.Arg = &.{},
    options: []const spec.Option = &.{},
};

fn internal(comptime cid: spec.Id, comptime usage: []const u8, comptime summary: []const u8, comptime example: spec.Example, comptime takes: Takes) spec.Command {
    return .{
        .id = cid,
        .name = usage[0 .. @import("std").mem.indexOfScalar(u8, usage, ' ') orelse usage.len],
        .group = .internal,
        .summary = summary,
        .usage = &.{usage},
        .args = takes.args,
        .options = takes.options,
        .examples = &.{example},
    };
}

const ready_fd: spec.Arg = .{
    .name = "READY-FD",
    .kind = .int,
    .min = -1,
    .max = 1 << 20,
    .help = "A pipe the editor waits on until the thumbnail is up (-1: none)",
};

const trim_options = [_]spec.Option{
    .{ .long = "range", .value = "A,B", .kind = .pair, .max = 1 << 40, .help = "Keep milliseconds A to B" },
    .{ .long = "export", .help = "Export the range without the window" },
};

const toast_args = [_]spec.Arg{
    .{ .name = "TITLE", .required = true, .help = "The first line" },
    .{ .name = "BODY", .help = "The text under it" },
};

const font_args = [_]spec.Arg{
    .{ .name = "LINES", .help = "The lines to render, separated by |" },
    .{ .name = "OUT.png", .kind = .file, .help = "Where to write the PNG" },
    .{ .name = "FONT.ttf", .kind = .file, .help = "The font to try first" },
};

pub const list = [_]spec.Command{
    internal(.quick, "quick ROOT ID [READY-FD]", "The floating thumbnail of a history entry", .{ .cmd = "quick ./history 20250101-1 -1", .what = "Its thumbnail" }, .{ .args = &.{ root, id, ready_fd } }),
    internal(.quick_video, "quick-video ROOT ID", "The floating thumbnail of a recording", .{ .cmd = "quick-video ./history 20250101-1", .what = "Its thumbnail" }, .{ .args = &.{ root, id } }),
    internal(.trim, "trim ROOT ID [--range A,B] [--export]", "The recording trimmer", .{ .cmd = "trim ./history 20250101-1 --range 0,1500 --export", .what = "Keep 1.5 s" }, .{ .args = &.{ root, id }, .options = &trim_options }),
    internal(.toast, "toast [--info] TITLE [BODY]", "A short notice on the screen", .{ .cmd = "toast --info Saved shot.png", .what = "A notice" }, .{
        .args = &toast_args,
        .options = &.{.{ .long = "info", .help = "A notice to read (longer, as wide as its words), not a done" }},
    }),
    internal(.man_page, "man-page", "Print the man page (roff)", .{ .cmd = "man-page", .what = "The man page" }, .{}),
    internal(.test_window, "test-window", "A test window for 3 seconds", .{ .cmd = "test-window", .what = "The window" }, .{}),
    internal(.test_grab, "test-grab", "Grab every monitor through the portal to a PNG", .{ .cmd = "test-grab", .what = "The PNG" }, .{}),
    internal(.test_font, "test-font [LINES [OUT.png [FONT.ttf]]]", "Render sample text to a PNG", .{ .cmd = "test-font Hello|world out.png", .what = "Two lines" }, .{ .args = &font_args }),
    internal(.test_decode, "test-decode FILE", "Decode and re-encode a PNG", .{ .cmd = "test-decode shot.png", .what = "Round trip" }, .{ .args = &.{
        .{ .name = "FILE", .kind = .file, .required = true, .help = "The PNG" },
    } }),
};
