//! Starting another shotlet: a subcommand run detached (proc.spawnSelf:
//! double fork, never a zombie, it outlives us) with our environment.
//! One typed function per subcommand Shotlet starts itself; the names
//! come from the command table (src/cli/commands.zig), so the table and
//! its callers cannot drift apart.

const std = @import("std");
const commands = @import("../cli/commands.zig");
const env_mod = @import("env.zig");
const proc = @import("../platform/api.zig").proc;
const sys = @import("../platform/api.zig").sys;
const Env = env_mod.Env;
const Id = commands.Id;

/// The command line under construction: NUL-terminated copies in one
/// fixed buffer.
const Args = struct {
    store: [6 * 1024]u8 = undefined,
    used: usize = 0,
    /// proc.spawnSelf takes up to seven
    ptrs: [7][*:0]const u8 = undefined,
    n: usize = 0,

    fn of(comptime id: Id) Args {
        var a: Args = .{};
        a.ptrs[0] = comptime nameOf(id);
        a.n = 1;
        return a;
    }

    fn add(a: *Args, s: []const u8) !void {
        if (a.n == a.ptrs.len or a.used + s.len + 1 > a.store.len) return error.ArgsTooLong;
        const z = a.store[a.used..][0 .. s.len + 1];
        @memcpy(z[0..s.len], s);
        z[s.len] = 0;
        a.ptrs[a.n] = z[0..s.len :0].ptr;
        a.n += 1;
        a.used += s.len + 1;
    }

    fn print(a: *Args, comptime fmt: []const u8, args: anytype) !void {
        var buf: [64]u8 = undefined;
        try a.add(try std.fmt.bufPrint(&buf, fmt, args));
    }

    fn slice(a: *const Args) []const [*:0]const u8 {
        return a.ptrs[0..a.n];
    }
};

/// The top-level command's name in the table.
fn nameOf(comptime id: Id) [:0]const u8 {
    return comptime blk: {
        for (&commands.all) |*c| if (c.id == id) break :blk (c.name ++ "\x00")[0..c.name.len :0];
        @compileError("no top-level command " ++ @tagName(id));
    };
}

fn run(e: Env, a: *const Args, keep: ?sys.fd_t) void {
    std.log.debug("starting shotlet {s}", .{std.mem.span(a.ptrs[0])});
    proc.spawnSelf(e.envp, a.slice(), keep);
}

/// Report a command line that did not fit.
fn tooLong(err: anyerror, comptime what: []const u8) void {
    std.log.warn("cannot start shotlet " ++ what ++ ": {t}", .{err});
}

/// `shotlet edit ROOT ID`: a history entry in the editor again.
pub fn edit(e: Env, root: []const u8, id: []const u8) void {
    var a: Args = .of(.edit);
    a.add(root) catch |err| return tooLong(err, "edit");
    a.add(id) catch |err| return tooLong(err, "edit");
    run(e, &a, null);
}

/// `shotlet edit FILE`
pub fn editFile(e: Env, path: []const u8) void {
    var a: Args = .of(.edit);
    a.add("--") catch unreachable;
    a.add(path) catch |err| return tooLong(err, "edit");
    run(e, &a, null);
}

/// `shotlet edit --pin-fd FD FILE`: a pin's Annotate; the editor hands
/// the picture back through `fd` (the write end of a pipe), which stays
/// open in the child.
pub fn editForPin(e: Env, path: []const u8, fd: sys.fd_t) void {
    var a: Args = .of(.edit);
    a.add("--pin-fd") catch unreachable;
    a.print("{d}", .{fd}) catch unreachable;
    a.add("--") catch unreachable;
    a.add(path) catch |err| return tooLong(err, "edit");
    run(e, &a, fd);
}

/// `shotlet pin FILE [--at X,Y]`: centred on `at` (logical pixels) when
/// known.
pub fn pin(e: Env, path: []const u8, at: ?[2]i32) void {
    var a: Args = .of(.pin);
    if (at) |p| {
        a.add("--at") catch unreachable;
        a.print("{d},{d}", .{ p[0], p[1] }) catch unreachable;
    }
    a.add("--") catch unreachable;
    a.add(path) catch |err| return tooLong(err, "pin");
    run(e, &a, null);
}

/// `shotlet quick ROOT ID READY-FD`: the floating thumbnail of a kept
/// capture. With `ready`, the write end of a pipe the thumbnail process
/// writes to once its first frame is committed (or closes, giving up);
/// it stays open in the child.
pub fn quick(e: Env, root: []const u8, id: []const u8, ready: ?sys.fd_t) void {
    var a: Args = .of(.quick);
    a.add(root) catch |err| return tooLong(err, "quick");
    a.add(id) catch |err| return tooLong(err, "quick");
    a.print("{d}", .{ready orelse -1}) catch unreachable;
    run(e, &a, ready);
}

/// `shotlet quick-video ROOT ID`: the floating thumbnail of a recording.
pub fn quickVideo(e: Env, root: []const u8, id: []const u8) void {
    var a: Args = .of(.quick_video);
    a.add(root) catch |err| return tooLong(err, "quick-video");
    a.add(id) catch |err| return tooLong(err, "quick-video");
    run(e, &a, null);
}

/// `shotlet trim ROOT ID`: the trim window for a recording.
pub fn trim(e: Env, root: []const u8, id: []const u8) void {
    var a: Args = .of(.trim);
    a.add(root) catch |err| return tooLong(err, "trim");
    a.add(id) catch |err| return tooLong(err, "trim");
    run(e, &a, null);
}

pub const ToastKind = enum { done, info };

/// `shotlet toast [--info] TITLE [BODY]`: a card at the bottom of the
/// screen, after the window that had something to say is gone.
pub fn toast(e: Env, kind: ToastKind, title: []const u8, body: []const u8) void {
    var a: Args = .of(.toast);
    if (kind == .info) a.add("--info") catch unreachable;
    // the words are never options, whatever they start with
    a.add("--") catch unreachable;
    a.add(title) catch |err| return tooLong(err, "toast");
    if (body.len > 0) a.add(body) catch |err| return tooLong(err, "toast");
    run(e, &a, null);
}

/// `shotlet history`: the history panel.
pub fn history(e: Env) void {
    var a: Args = .of(.history);
    run(e, &a, null);
}

/// A capture command by its name ("window", "scroll", "timer": the
/// editor's mode strip), refused unless the table has it.
pub fn capture(e: Env, name: []const u8) void {
    const c = commands.find(name) orelse {
        std.log.warn("cannot start shotlet {s}: no such command", .{name});
        return;
    };
    var a: Args = .{};
    a.add(c.name) catch unreachable;
    run(e, &a, null);
}

test "names come from the command table" {
    try std.testing.expectEqualStrings("quick-video", nameOf(.quick_video));
    try std.testing.expectEqualStrings("edit", nameOf(.edit));
    try std.testing.expectEqualStrings("toast", nameOf(.toast));
}

test "command lines are built in one buffer, NUL-terminated" {
    var a: Args = .of(.pin);
    try a.add("/tmp/a b.png");
    try a.add("--at");
    try a.print("{d},{d}", .{ -3, 40 });
    const s = a.slice();
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("pin", std.mem.span(s[0]));
    try std.testing.expectEqualStrings("/tmp/a b.png", std.mem.span(s[1]));
    try std.testing.expectEqualStrings("-3,40", std.mem.span(s[3]));
    // too many or too long: refused, not cut
    var big: Args = .of(.edit);
    const long: [7 * 1024]u8 = @splat('x');
    try std.testing.expectError(error.ArgsTooLong, big.add(&long));
    for (0..6) |_| try big.add("x");
    try std.testing.expectError(error.ArgsTooLong, big.add("x"));
}
