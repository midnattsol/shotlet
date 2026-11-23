//! The command line's front door: help, the version, the completions,
//! the man page and refused command lines are answered here (help to
//! stdout, errors to stderr with status 2: out.zig's rules); anything
//! else goes back to main to run.

const std = @import("std");
const parse = @import("parse.zig");
const help = @import("help.zig");
const errors = @import("errors.zig");
const out = @import("out.zig");
const commands = @import("commands.zig");
const text = @import("text.zig");
const sys = @import("../platform/api.zig").sys;

pub const Parsed = parse.Parsed;

pub const Result = union(enum) {
    run: Parsed,
    /// answered: exit with this status
    exit: u8,
};

/// `args` with the program name; `no_color`: NO_COLOR is set.
pub fn handle(arena: std.mem.Allocator, args: []const [:0]const u8, no_color: bool) !Result {
    const style: text.Style = .{ .bold = !no_color and sys.isTerminal(1) };
    var buf: std.Io.Writer.Allocating = .init(arena);
    const r = try answer(arena, if (args.len > 0) args[1..] else args, style, &buf.writer);
    switch (r) {
        .run => {},
        .exit => |code| sys.writeAll(if (code == @backingInt(out.ExitCode.ok)) 1 else 2, buf.written()) catch {},
    }
    return r;
}

/// What `args` (without the program name) asks; the answer, if any, goes
/// to `w` (for stdout with status 0, else for stderr).
pub fn answer(arena: std.mem.Allocator, args: []const [:0]const u8, style: text.Style, w: *std.Io.Writer) !Result {
    switch (try parse.parse(arena, args)) {
        .run => |p| switch (p.id()) {
            .help => try help.overview(w, style),
            .completions => try @import("complete.zig").write(w, std.meta.stringToEnum(@import("complete.zig").Shell, p.positionals[0]).?),
            .man_page => try @import("man.zig").write(w),
            else => return .{ .run = p },
        },
        .overview => try help.overview(w, style),
        .help => |chain| try help.command(w, style, chain),
        .version => try w.print("shotlet {s}\n", .{commands.version}),
        .fail => |f| {
            try errors.write(w, f);
            return .{ .exit = @backingInt(out.ExitCode.usage) };
        },
    }
    return .{ .exit = @backingInt(out.ExitCode.ok) };
}
