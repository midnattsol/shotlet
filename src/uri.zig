//! file:// URIs, both ways, for every layer: the local path a URI names
//! (portal answers, dropped files, text/uri-list on the clipboard) and the
//! URI of a local path (drags, copies, "show in Files"). Paths are bytes:
//! percent-encoded UTF-8 ("Imágenes" is "Im%C3%A1genes").

const std = @import("std");

const scheme = "file://";

/// The local path `uri` names, decoded into `buf`: a file:// URI with no
/// host or localhost. A %00, a malformed or cut escape or another host is
/// error.BadUri, never a different path; error.NoSpaceLeft when `buf` is
/// too short.
pub fn toFilePathBuf(buf: []u8, uri: []const u8) error{ BadUri, NoSpaceLeft }![]u8 {
    if (!std.mem.startsWith(u8, uri, scheme)) return error.BadUri;
    var rest = uri[scheme.len..];
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return error.BadUri; // another host
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (n += 1) {
        if (n >= buf.len) return error.NoSpaceLeft;
        if (rest[i] != '%') {
            buf[n] = rest[i];
            i += 1;
            continue;
        }
        if (i + 2 >= rest.len) return error.BadUri;
        const hi = std.fmt.charToDigit(rest[i + 1], 16) catch return error.BadUri;
        const lo = std.fmt.charToDigit(rest[i + 2], 16) catch return error.BadUri;
        buf[n] = hi * 16 + lo;
        if (buf[n] == 0) return error.BadUri;
        i += 3;
    }
    return buf[0..n];
}

/// toFilePathBuf, owned.
pub fn toFilePath(gpa: std.mem.Allocator, uri: []const u8) ![]u8 {
    // decoding never makes it longer
    const buf = try gpa.alloc(u8, uri.len);
    errdefer gpa.free(buf);
    const path = try toFilePathBuf(buf, uri);
    return gpa.realloc(buf, path.len);
}

/// The first local file of a text/uri-list ("file:///a%20b.png\r\n..."),
/// decoded into `buf`; comments, other schemes and other hosts are
/// skipped.
pub fn firstFilePath(buf: []u8, list: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, list, "\r\n");
    while (it.next()) |line| {
        if (line[0] == '#') continue;
        return toFilePathBuf(buf, line) catch continue;
    }
    return null;
}

/// The file:// URI of the absolute `path`, every byte outside RFC 3986's
/// unreserved set and '/' percent-encoded.
pub fn writeFileUri(w: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(scheme);
    for (path) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
        if (plain) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

/// The file:// URI of `path`, owned.
pub fn fromFilePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return build(gpa, path, "");
}

/// A text/uri-list naming the one file `path` (CRLF ended), owned.
pub fn fileUriList(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return build(gpa, path, "\r\n");
}

fn build(gpa: std.mem.Allocator, path: []const u8, end: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try writeFileUri(&out.writer, path);
    try out.writer.writeAll(end);
    return out.toOwnedSlice();
}

test "file URIs become local paths" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "file:///home/x/Im%C3%A1genes/a%20b.png", "/home/x/Imágenes/a b.png" },
        .{ "file://localhost/tmp/x.png", "/tmp/x.png" },
        .{ "file:///tmp/100%25", "/tmp/100%" },
        .{ "file:///tmp/%e2%82%ac", "/tmp/€" },
    }) |c| {
        const p = try toFilePath(gpa, c[0]);
        defer gpa.free(p);
        try std.testing.expectEqualStrings(c[1], p);
    }
    for ([_][]const u8{ "http://x/y", "file://otherhost/x.png", "file:///a%00b", "file:///bad%zz", "file:///cut%4", "file:///cut%", "file://", "/tmp/x" }) |bad|
        try std.testing.expectError(error.BadUri, toFilePath(gpa, bad));
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, toFilePathBuf(&small, "file:///tmp/x.png"));
}

test "a uri list gives its first local file" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u/a b.png", firstFilePath(&buf, "# comment\r\nfile:///home/u/a%20b.png\r\nfile:///x.png\r\n").?);
    try std.testing.expectEqualStrings("/tmp/x.png", firstFilePath(&buf, "file://localhost/tmp/x.png").?);
    try std.testing.expectEqualStrings("/x.png", firstFilePath(&buf, "https://example.com/a.png\nfile://otherhost/b.png\nfile:///x.png\n").?);
    try std.testing.expect(firstFilePath(&buf, "https://example.com/x.png\n") == null);
    try std.testing.expect(firstFilePath(&buf, "file:///a%00b") == null);
    try std.testing.expect(firstFilePath(&buf, "file:///bad%zz") == null);
    try std.testing.expect(firstFilePath(&buf, "") == null);
}

test "local paths become file URIs and back" {
    const gpa = std.testing.allocator;
    const u = try fileUriList(gpa, "/home/a b/Imágenes/shot#1.png");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("file:///home/a%20b/Im%C3%A1genes/shot%231.png\r\n", u);
    const one = try fromFilePath(gpa, "/tmp/a b");
    defer gpa.free(one);
    try std.testing.expectEqualStrings("file:///tmp/a%20b", one);
    for ([_][]const u8{ "/home/a b/Imágenes/shot#1.png", "/tmp/100%/x?y=z&w", "/~user/-._~", "/tab\there/\u{1F600}" }) |path| {
        const list = try fileUriList(gpa, path);
        defer gpa.free(list);
        var buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings(path, firstFilePath(&buf, list).?);
    }
}
