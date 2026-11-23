//! Clipboard and drag-and-drop payloads: bounded reads from a data
//! offer's pipe, the types a dragged capture offers, file URI lists.

const std = @import("std");
const sys = @import("../platform/api.zig").sys;

/// Read `fd` until EOF, `max_bytes` or the deadline, whichever comes
/// first (sys.readBounded); a cut never splits a UTF-8 sequence. Caller
/// owns the bytes.
pub fn readBounded(alloc: std.mem.Allocator, fd: sys.fd_t, max_bytes: usize, deadline_ms: i64) ![]u8 {
    const out = try sys.readBounded(alloc, fd, max_bytes, deadline_ms);
    if (out.len < max_bytes) return out;
    // drop a trailing partial character
    var i = out.len;
    while (i > 0 and (out[i - 1] & 0xC0) == 0x80) i -= 1;
    if (i > 0 and out[i - 1] >= 0xC0) {
        const need = std.unicode.utf8ByteSequenceLength(out[i - 1]) catch 1;
        if (out.len - (i - 1) < need) {
            defer alloc.free(out);
            return alloc.dupe(u8, out[0 .. i - 1]);
        }
    }
    return out;
}

test "bounded reads stop at EOF, the size limit and the deadline" {
    const alloc = std.testing.allocator;
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    try sys.writeAll(fds[1], "ab\xc3\xb1cd"); // "abñcd"
    // limit cuts inside "ñ": the partial character is dropped
    const cut = try readBounded(alloc, fds[0], 3, sys.monoMs() + 1000);
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("ab", cut);
    // nothing more arrives and the writer stays open: the deadline ends it
    const rest = try readBounded(alloc, fds[0], 100, sys.monoMs() + 50);
    defer alloc.free(rest);
    try std.testing.expectEqualStrings("\xb1cd", rest);
    sys.close(fds[1]);
    const eof = try readBounded(alloc, fds[0], 100, sys.monoMs() + 1000);
    defer alloc.free(eof);
    try std.testing.expectEqual(@as(usize, 0), eof.len);
}

/// MIME types a dragged image offers, best first.
pub const drag_mimes = [_][]const u8{ "image/png", "text/uri-list" };

/// Which payload answers a request for `mime` (null: not offered).
pub fn dragPayloadFor(mime: []const u8) ?enum { png, uri_list } {
    if (std.mem.eql(u8, mime, "image/png")) return .png;
    if (std.mem.eql(u8, mime, "text/uri-list")) return .uri_list;
    return null;
}

/// text/uri-list body for a local file: file:// URI with every byte
/// outside RFC 3986's unreserved set and '/' percent-encoded, CRLF ended.
pub fn fileUriList(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |c| {
        const plain = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/", c) != null;
        if (plain) try out.append(alloc, c) else try out.print(alloc, "%{X:0>2}", .{c});
    }
    try out.appendSlice(alloc, "\r\n");
    return out.toOwnedSlice(alloc);
}

test "drag MIME types map to their payloads" {
    const t = std.testing;
    try t.expectEqual(.png, dragPayloadFor("image/png").?);
    try t.expectEqual(.uri_list, dragPayloadFor("text/uri-list").?);
    try t.expect(dragPayloadFor("text/plain") == null);
    try t.expect(dragPayloadFor("image/png;x") == null);
    try t.expect(dragPayloadFor("") == null);
    for (drag_mimes) |m| try t.expect(dragPayloadFor(m) != null);
    const u = try fileUriList(t.allocator, "/home/a b/Imágenes/shot#1.png");
    defer t.allocator.free(u);
    try t.expectEqualStrings("file:///home/a%20b/Im%C3%A1genes/shot%231.png\r\n", u);
}
