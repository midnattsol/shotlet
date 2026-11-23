//! Every command of the table, public and internal, against the front
//! door: its examples run, --help answers with its help (status 0), and
//! a bogus option, a missing or an extra argument is refused with
//! "shotlet COMMAND: ..." and status 2.

const std = @import("std");
const commands = @import("commands.zig");
const front = @import("front.zig");
const out = @import("out.zig");
const spec = @import("spec.zig");
const t = std.testing;

const Answer = struct {
    result: front.Result,
    text: []const u8,
};

fn ask(arena: std.mem.Allocator, words: []const []const u8) !Answer {
    var args = try arena.alloc([:0]const u8, words.len);
    for (words, 0..) |w, i| args[i] = try arena.dupeSentinel(u8, w, 0);
    var buf: std.Io.Writer.Allocating = .init(arena);
    const r = try front.answer(arena, args, .{}, &buf.writer);
    return .{ .result = r, .text = buf.written() };
}

/// `chain ++ extra`, as words.
fn line(arena: std.mem.Allocator, chain: []const []const u8, extra: []const []const u8) ![]const []const u8 {
    return std.mem.concat(arena, []const u8, &.{ chain, extra });
}

/// "shotlet gnome-integration install"
fn label(arena: std.mem.Allocator, chain: []const []const u8) ![]const u8 {
    return std.mem.join(arena, " ", try line(arena, &.{"shotlet"}, chain));
}

fn expectRefused(arena: std.mem.Allocator, chain: []const []const u8, extra: []const []const u8, what: []const u8) !void {
    const a = try ask(arena, try line(arena, chain, extra));
    try t.expectEqual(@backingInt(out.ExitCode.usage), a.result.exit);
    const want = try std.fmt.allocPrint(arena, "{s}: {s}", .{ try label(arena, chain), what });
    if (!std.mem.startsWith(u8, a.text, want)) {
        std.debug.print("want {s}\ngot  {s}\n", .{ want, a.text });
        return error.WrongMessage;
    }
}

fn expectExamplesRun(arena: std.mem.Allocator, c: *const spec.Command) !void {
    for (c.examples) |ex| {
        // the shell's part ("> shotlet.fish") is not shotlet's
        const cmd = std.mem.trim(u8, ex.cmd[0 .. std.mem.indexOfScalar(u8, ex.cmd, '>') orelse ex.cmd.len], " ");
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        while (it.next()) |w| try words.append(arena, w);
        const a = try ask(arena, words.items);
        switch (a.result) {
            .run => |p| try t.expect(p.id() == c.id or c.findSub(p.chain.leaf().?.name) != null),
            // help, completions and the man page are answered at the door
            .exit => |code| try t.expectEqual(@backingInt(out.ExitCode.ok), code),
        }
    }
}

fn checkCommand(arena: std.mem.Allocator, chain: []const []const u8, c: *const spec.Command) !void {
    try expectExamplesRun(arena, c);
    if (c.id != .help) {
        const h = try ask(arena, try line(arena, chain, &.{"--help"}));
        try t.expectEqual(@backingInt(out.ExitCode.ok), h.result.exit);
        try t.expect(std.mem.indexOf(u8, h.text, c.usage[0]) != null);
        try expectRefused(arena, chain, &.{"--bogus"}, "unknown option '--bogus'");
    }
    var required: ?[]const u8 = null;
    for (c.args) |arg| if (arg.required) {
        required = arg.name;
        break;
    };
    if (required) |name| try expectRefused(arena, chain, &.{}, try std.fmt.allocPrint(arena, "missing {s}", .{name}));
    if (c.args.len == 0 and c.subs.len == 0) try expectRefused(arena, chain, &.{"extra"}, "unexpected argument 'extra'");
}

test "every command: its examples, its help and refused command lines" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (&commands.all) |*c| {
        try checkCommand(arena, &.{c.name}, c);
        for (c.subs) |*s| try checkCommand(arena, &.{ c.name, s.name }, s);
    }
}

test "bad values say what they should look like" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectRefused(arena, &.{"record"}, &.{ "--region", "1,2,0,4" }, "invalid value '1,2,0,4' for --region: expected X,Y,W,H");
    try expectRefused(arena, &.{"record"}, &.{ "--fps", "0" }, "invalid value '0' for --fps");
    try expectRefused(arena, &.{"record"}, &.{ "--format", "webm" }, "invalid value 'webm' for --format: expected one of: mp4, gif");
    try expectRefused(arena, &.{"quick"}, &.{ "/r", "id", "fd" }, "invalid value 'fd' for READY-FD");
    try expectRefused(arena, &.{"trim"}, &.{ "/r", "id", "--range", "5" }, "invalid value '5' for --range: expected A,B");
    try expectRefused(arena, &.{"edit"}, &.{ "a.png", "--pin-fd", "1" }, "invalid value '1' for --pin-fd");
    try expectRefused(arena, &.{"pin"}, &.{ "a.png", "--at", "x" }, "invalid value 'x' for --at");
    try expectRefused(arena, &.{"shot"}, &.{ "--pointer", "1,2,3" }, "invalid value '1,2,3' for --pointer");
    try expectRefused(arena, &.{"shot"}, &.{ "--then", "edit" }, "invalid value 'edit' for --then");
    try expectRefused(arena, &.{"toast"}, &.{ "a", "b", "c" }, "unexpected argument 'c'");
    try expectRefused(arena, &.{"test-decode"}, &.{}, "missing FILE");
}

test "the CLI's words come from the app's tables" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mode = @import("../app/modes/mode.zig");
    const delay = commands.find("area").?.findOption("delay").?;
    try t.expectEqual(@as(i64, mode.max_delay_s), delay.max);
    try t.expectEqual(mode.timer_choices.len, delay.choices.len);
    for (mode.shortcuts) |s| {
        const a = try ask(arena, &.{ "gnome-integration", "shortcut", s.name });
        try t.expectEqual(.gnome_shortcut, a.result.run.id());
    }
    const fmt = commands.find("record").?.findOption("format").?;
    try t.expectEqual(std.meta.fieldNames(@import("../encode/sink.zig").Format).len, fmt.choices.len);
}
