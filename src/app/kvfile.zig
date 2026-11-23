//! The key=value files a history entry keeps (`meta`, a recording's
//! `video`): a header line naming the format and its version, then one
//! `key=value` per line. Text values escape backslash, newline and CR
//! (`\\`, `\n`, `\r`) so each stays on its line; unknown keys and lines
//! without "=" are skipped, so older and newer versions read each other.
//!
//!     shotlet-history 1
//!     time=1763740953123
//!     size=1920x1080
//!     saved=/home/me/Pictures/shotlet-20251121-161233.png

const std = @import("std");

/// Writes a file: `header` first, then the values (an ArrayList kept
/// by the caller's allocator).
pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, header: []const u8) !Writer {
        var w: Writer = .{ .gpa = gpa };
        errdefer w.deinit();
        try w.out.appendSlice(gpa, header);
        try w.out.append(gpa, '\n');
        return w;
    }

    pub fn deinit(w: *Writer) void {
        w.out.deinit(w.gpa);
    }

    /// The file (owned); the writer is empty afterwards.
    pub fn finish(w: *Writer) ![]u8 {
        return w.out.toOwnedSlice(w.gpa);
    }

    pub fn int(w: *Writer, key: []const u8, v: anytype) !void {
        try w.out.print(w.gpa, "{s}={d}\n", .{ key, v });
    }

    /// An enum value by its name.
    pub fn tag(w: *Writer, key: []const u8, v: anytype) !void {
        try w.out.print(w.gpa, "{s}={t}\n", .{ key, v });
    }

    /// "WxH"
    pub fn size(w: *Writer, key: []const u8, width: u32, height: u32) !void {
        try w.out.print(w.gpa, "{s}={d}x{d}\n", .{ key, width, height });
    }

    /// "X,Y"
    pub fn point(w: *Writer, key: []const u8, p: [2]i32) !void {
        try w.out.print(w.gpa, "{s}={d},{d}\n", .{ key, p[0], p[1] });
    }

    /// Text, escaped to stay on its line.
    pub fn str(w: *Writer, key: []const u8, v: []const u8) !void {
        try w.out.print(w.gpa, "{s}=", .{key});
        for (v) |c| switch (c) {
            '\\' => try w.out.appendSlice(w.gpa, "\\\\"),
            '\n' => try w.out.appendSlice(w.gpa, "\\n"),
            '\r' => try w.out.appendSlice(w.gpa, "\\r"),
            else => try w.out.append(w.gpa, c),
        };
        try w.out.append(w.gpa, '\n');
    }
};

pub const Field = struct {
    key: []const u8,
    /// as written: text values are still escaped (see `text`)
    value: []const u8,

    pub fn is(f: Field, key: []const u8) bool {
        return std.mem.eql(u8, f.key, key);
    }
};

/// Reads a file whose first line is `header`.
pub const Reader = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    /// error.BadHeader when the file is not this format.
    pub fn init(data: []const u8, header: []const u8) !Reader {
        var lines = std.mem.splitScalar(u8, data, '\n');
        if (!std.mem.eql(u8, lines.next() orelse "", header)) return error.BadHeader;
        return .{ .lines = lines };
    }

    pub fn next(r: *Reader) ?Field {
        while (r.lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            return .{ .key = line[0..eq], .value = line[eq + 1 ..] };
        }
        return null;
    }
};

/// "WxH"
pub fn parseSize(v: []const u8) ?[2]u32 {
    const x = std.mem.indexOfScalar(u8, v, 'x') orelse return null;
    const w = std.fmt.parseInt(u32, v[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch return null;
    return .{ w, h };
}

/// "X,Y", nothing more.
pub fn parsePoint(v: []const u8) ?[2]i32 {
    var it = std.mem.splitScalar(u8, v, ',');
    const x = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    return if (it.next() == null) .{ x, y } else null;
}

/// A text value unescaped (owned).
pub fn text(gpa: std.mem.Allocator, v: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, v);
    const n = unescapeInPlace(out).len;
    return gpa.realloc(out, n) catch |err| {
        gpa.free(out);
        return err;
    };
}

/// A text value of `data` (a field a Reader of `data` returned)
/// unescaped where it lies, in `data`.
pub fn textIn(data: []u8, v: []const u8) []u8 {
    const off = @intFromPtr(v.ptr) - @intFromPtr(data.ptr);
    std.debug.assert(off + v.len <= data.len);
    return unescapeInPlace(data[off..][0..v.len]);
}

/// A text value unescaped where it lies (it only gets shorter).
pub fn unescapeInPlace(v: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        var c = v[i];
        if (c == '\\' and i + 1 < v.len) {
            i += 1;
            c = switch (v[i]) {
                'n' => '\n',
                'r' => '\r',
                else => v[i],
            };
        }
        v[n] = c;
        n += 1;
    }
    return v[0..n];
}

test "a file round-trips, text escaped onto its line" {
    const gpa = std.testing.allocator;
    var w = try Writer.init(gpa, "shotlet-test 1");
    defer w.deinit();
    try w.int("time", @as(i64, -5));
    try w.size("size", 640, 480);
    try w.point("at", .{ -10, 20 });
    try w.str("path", "/a\\b\nc\rd=e");
    try w.tag("format", enum { mp4, gif }.gif);
    const data = try w.finish();
    defer gpa.free(data);
    try std.testing.expectEqualStrings("shotlet-test 1\ntime=-5\nsize=640x480\nat=-10,20\npath=/a\\\\b\\nc\\rd=e\nformat=gif\n", data);

    var r = try Reader.init(data, "shotlet-test 1");
    try std.testing.expect(r.next().?.is("time"));
    try std.testing.expectEqual([2]u32{ 640, 480 }, parseSize(r.next().?.value).?);
    try std.testing.expectEqual([2]i32{ -10, 20 }, parsePoint(r.next().?.value).?);
    const p = r.next().?;
    try std.testing.expect(p.is("path"));
    const t = try text(gpa, p.value);
    defer gpa.free(t);
    try std.testing.expectEqualStrings("/a\\b\nc\rd=e", t);
    try std.testing.expectEqualStrings("format", r.next().?.key);
    try std.testing.expect(r.next() == null);
}

test "headers, stray lines and bad values" {
    try std.testing.expectError(error.BadHeader, Reader.init("shotlet-test 2\nk=v\n", "shotlet-test 1"));
    try std.testing.expectError(error.BadHeader, Reader.init("", "shotlet-test 1"));
    var r = try Reader.init("shotlet-test 1\nno equals\n\nk=\n", "shotlet-test 1");
    const f = r.next().?;
    try std.testing.expectEqualStrings("k", f.key);
    try std.testing.expectEqualStrings("", f.value);
    try std.testing.expect(r.next() == null);
    try std.testing.expect(parseSize("12") == null);
    try std.testing.expect(parseSize("ax2") == null);
    try std.testing.expect(parsePoint("1,2,3") == null);
    try std.testing.expect(parsePoint("1") == null);
    // an old file's value with no escapes reads as it was
    var buf = "/v/a b.mp4".*;
    try std.testing.expectEqualStrings("/v/a b.mp4", unescapeInPlace(&buf));
    // a lone trailing backslash stays
    var tail = "a\\".*;
    try std.testing.expectEqualStrings("a\\", unescapeInPlace(&tail));
}
