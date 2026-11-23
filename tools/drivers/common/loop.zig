//! The drivers' command loop: one command per line on stdin, each
//! answered with one line on stdout, `ok [value]` or `err <reason>`;
//! plus the argument parsing every command shares.

const std = @import("std");
const sys = @import("shotlet").sys;

/// A command line's arguments, after its name.
pub const Args = std.mem.TokenIterator(u8, .any);

/// Answer one command per line on stdin until `quit` or its end.
/// `run(ctx, line)` returns the answer's value (empty for a plain `ok`);
/// `ctx.idle()` runs after every read and every command, to drop events
/// queued meanwhile.
pub fn serve(ctx: anytype, comptime run: anytype) !void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            const quit = answer(ctx, run, std.mem.trim(u8, buf[0..nl], " \t\r"));
            try ctx.idle();
            std.mem.copyForwards(u8, buf[0..], buf[nl + 1 .. len]);
            len -= nl + 1;
            if (quit) return;
            continue;
        }
        if (len == buf.len) return error.LineTooLong;
        const n = try sys.read(0, buf[len..]);
        if (n == 0) return;
        len += n;
        try ctx.idle();
    }
}

/// Run one line (blank and # lines are ignored) and reply to it; whether
/// it was `quit`.
fn answer(ctx: anytype, comptime run: anytype, line: []const u8) bool {
    if (line.len > 0 and line[0] != '#') {
        if (run(ctx, line)) |val| {
            if (val.len > 0) reply("ok {s}", .{val}) else reply("ok", .{});
        } else |err| reply("err {t}", .{err});
    }
    return eql(line, "quit");
}

/// One line on stdout.
pub fn reply(comptime fmt: []const u8, args: anytype) void {
    var out: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&out, fmt ++ "\n", args) catch "err reply too long\n";
    sys.writeAll(1, s) catch {};
}

/// The next argument of a command.
pub fn arg(it: *Args) ![]const u8 {
    return it.next() orelse error.MissingArg;
}

/// The next argument as a decimal integer.
pub fn int(comptime T: type, it: *Args) !T {
    return std.fmt.parseInt(T, try arg(it), 10);
}

/// The next argument as a decimal integer, `default` when there is none.
pub fn optInt(comptime T: type, it: *Args, default: T) !T {
    const s = it.next() orelse return default;
    return std.fmt.parseInt(T, s, 10);
}

/// The next argument as a number.
pub fn float(it: *Args) !f64 {
    return std.fmt.parseFloat(f64, try arg(it));
}

/// The next argument as RRGGBB (or 0xRRGGBB).
pub fn color(it: *Args) !u32 {
    return parseColor(try arg(it));
}

pub fn parseColor(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, if (std.mem.startsWith(u8, s, "0x")) s[2..] else s, 16);
}

/// The optional box X0 Y0 X1 Y1 that ends a command; null when absent.
pub fn optBox(it: *Args) !?[4]u32 {
    const first = it.next() orelse return null;
    var box: [4]u32 = undefined;
    box[0] = try std.fmt.parseInt(u32, first, 10);
    for (box[1..]) |*v| v.* = try int(u32, it);
    return box;
}

/// The rest of `line` from argument `first` (a slice of it) on.
pub fn rest(line: []const u8, first: []const u8) []const u8 {
    return line[@intFromPtr(first.ptr) - @intFromPtr(line.ptr) ..];
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn sleepMs(ms: u32) void {
    var ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

test "arguments" {
    var it = std.mem.tokenizeAny(u8, "12 0xff2020 1 2 3 4 tail end", " ");
    try std.testing.expectEqual(@as(u32, 12), try int(u32, &it));
    try std.testing.expectEqual(@as(u32, 0xff2020), try color(&it));
    try std.testing.expectEqual([4]u32{ 1, 2, 3, 4 }, (try optBox(&it)).?);
    const line = "textpng p 40 tail end";
    var it2 = std.mem.tokenizeAny(u8, line, " ");
    for (0..3) |_| _ = it2.next();
    try std.testing.expectEqualStrings("tail end", rest(line, try arg(&it2)));
    var empty = std.mem.tokenizeAny(u8, "", " ");
    try std.testing.expectEqual(@as(u32, 7), try optInt(u32, &empty, 7));
    try std.testing.expectEqual(@as(?[4]u32, null), try optBox(&empty));
}
