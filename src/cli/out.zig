//! What a command prints and how it exits, the same for every command:
//! results on stdout (`say`); problems on stderr as
//! "shotlet COMMAND: message" (`fail`); exit status 0 when it worked, 1
//! when it failed and 2 for a command line the table refuses (the parser
//! answers those, errors.zig). A Zig error that reaches the dispatcher
//! becomes such a message too (`failWith`), never a stack trace.

const std = @import("std");
const parse = @import("parse.zig");
const errors = @import("errors.zig");
const sys = @import("../platform/api.zig").sys;

pub const ExitCode = enum(u8) {
    ok = 0,
    /// the command ran and failed
    failure = 1,
    /// the command line is wrong
    usage = 2,
};

/// The command running, for the messages; the dispatcher sets it.
pub var command: parse.Chain = .{};

/// A result, on stdout.
pub fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    sys.writeAll(1, std.fmt.bufPrint(&buf, fmt, args) catch truncated(&buf)) catch {};
}

/// "shotlet COMMAND: message" on stderr.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    message(&w, command, fmt, args) catch {};
    sys.writeAll(2, w.buffered()) catch {};
}

/// `warn`, then exit with `code`.
pub fn fail(code: ExitCode, comptime fmt: []const u8, args: anytype) noreturn {
    warn(fmt, args);
    exit(code);
}

/// A failure the code returned as `err`: its message, then status 1.
pub fn failWith(err: anyerror) noreturn {
    var buf: [128]u8 = undefined;
    fail(.failure, "{s}", .{describe(&buf, err)});
}

pub fn exit(code: ExitCode) noreturn {
    std.process.exit(@backingInt(code));
}

fn message(w: *std.Io.Writer, chain: parse.Chain, comptime fmt: []const u8, args: anytype) !void {
    try errors.writeChain(w, chain);
    try w.writeAll(": ");
    w.print(fmt, args) catch {
        // cut short: end the line anyway
        w.end = @min(w.end, w.buffer.len - 4);
        try w.writeAll("...");
    };
    try w.writeAll("\n");
}

fn truncated(buf: []u8) []const u8 {
    @memcpy(buf[buf.len - 4 ..], "...\n");
    return buf;
}

/// Words for the errors a person can do something about; else the
/// error's name in words ("InstallFailed": "install failed").
pub fn describe(buf: []u8, err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.OutOfMemory => "out of memory",
        error.Unavailable => "not available on this platform",
        error.NoSpaceLeft => "no space left on the device",
        else => words(buf, @errorName(err)),
    };
}

/// "NoFileChooser" as "no file chooser".
fn words(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    for (name, 0..) |c, i| {
        if (n + 2 > buf.len) break;
        if (std.ascii.isUpper(c) and i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

test "messages name the command" {
    const commands = @import("commands.zig");
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var chain: parse.Chain = .of(commands.find("gnome-integration").?);
    chain.push(chain.leaf().?.findSub("install").?);
    try message(&w, chain, "could not install ({d})", .{3});
    try std.testing.expectEqualStrings("shotlet gnome-integration install: could not install (3)\n", w.buffered());
    var small: [24]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&small);
    try message(&sw, .of(commands.find("record").?), "{s}", .{"a very long message indeed"});
    try std.testing.expect(std.mem.endsWith(u8, sw.buffered(), "...\n"));
}

test "errors read as words" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("no such file or directory", describe(&buf, error.FileNotFound));
    try std.testing.expectEqualStrings("install failed", describe(&buf, error.InstallFailed));
    try std.testing.expectEqualStrings("no runtime dir", describe(&buf, error.NoRuntimeDir));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(ExitCode.usage));
}
