//! file:// URIs as portals hand them out: the local path a URI names
//! (percent-encoded UTF-8, e.g. the Spanish XDG pictures dir "Imágenes"
//! arrives as "Im%C3%A1genes").

const std = @import("std");

/// The local path `uri` names (owned): a file:// URI, with no host or
/// localhost, percent-decoded. A %00 or a malformed escape is an error,
/// never a different path.
pub fn toFilePath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const scheme = "file://";
    if (!std.mem.startsWith(u8, uri, scheme)) return error.BadUri;
    var rest = uri[scheme.len..];
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return error.BadUri; // another host
    return percentDecode(alloc, rest);
}

fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') {
            try out.append(alloc, s[i]);
            continue;
        }
        if (i + 2 >= s.len) return error.BadUri;
        const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.BadUri;
        const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.BadUri;
        const c = hi * 16 + lo;
        if (c == 0) return error.BadUri;
        try out.append(alloc, c);
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

test "file URIs become local paths" {
    const alloc = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "file:///home/x/Im%C3%A1genes/a%20b.png", "/home/x/Imágenes/a b.png" },
        .{ "file://localhost/tmp/x.png", "/tmp/x.png" },
        .{ "file:///tmp/100%25", "/tmp/100%" },
    }) |c| {
        const p = try toFilePath(alloc, c[0]);
        defer alloc.free(p);
        try std.testing.expectEqualStrings(c[1], p);
    }
    for ([_][]const u8{ "http://x/y", "file://otherhost/x.png", "file:///a%00b", "file:///bad%zz", "file:///cut%4" }) |bad|
        try std.testing.expectError(error.BadUri, toFilePath(alloc, bad));
}
