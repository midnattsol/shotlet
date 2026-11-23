//! Body builder: appends DBus wire values with the alignment rules of the
//! little-endian marshalling format.

const std = @import("std");
const sys = @import("../sys.zig");

/// Body builder. All append methods handle alignment.
pub const Marshal = struct {
    buf: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Marshal {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Marshal) void {
        self.buf.deinit(self.alloc);
    }

    pub fn pad(self: *Marshal, alignment: usize) !void {
        while (self.buf.items.len % alignment != 0)
            try self.buf.append(self.alloc, 0);
    }
    pub fn putByte(self: *Marshal, v: u8) !void {
        try self.buf.append(self.alloc, v);
    }
    pub fn putU16(self: *Marshal, v: u16) !void {
        try self.pad(2);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putU32(self: *Marshal, v: u32) !void {
        try self.pad(4);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putI32(self: *Marshal, v: i32) !void {
        try self.putU32(@bitCast(v));
    }
    pub fn putU64(self: *Marshal, v: u64) !void {
        try self.pad(8);
        try self.buf.appendSlice(self.alloc, std.mem.asBytes(&v));
    }
    pub fn putBool(self: *Marshal, v: bool) !void {
        try self.putU32(if (v) 1 else 0);
    }
    pub fn putString(self: *Marshal, s: []const u8) !void {
        try self.putU32(@intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }
    pub fn putObjectPath(self: *Marshal, s: []const u8) !void {
        try self.putString(s);
    }
    pub fn putSignature(self: *Marshal, s: []const u8) !void {
        try self.buf.append(self.alloc, @intCast(s.len));
        try self.buf.appendSlice(self.alloc, s);
        try self.buf.append(self.alloc, 0);
    }
    /// variant with a simple inner value
    pub fn putVariantString(self: *Marshal, s: []const u8) !void {
        try self.putSignature("s");
        try self.putString(s);
    }
    pub fn putVariantBool(self: *Marshal, v: bool) !void {
        try self.putSignature("b");
        try self.putBool(v);
    }
    pub fn putVariantU32(self: *Marshal, v: u32) !void {
        try self.putSignature("u");
        try self.putU32(v);
    }
    pub fn putVariantI32(self: *Marshal, v: i32) !void {
        try self.putSignature("i");
        try self.putI32(v);
    }

    /// A variant of `value`: a string (anything that coerces to
    /// []const u8), bool, u32, i32 or u64.
    pub fn putVariant(self: *Marshal, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == bool) return self.putVariantBool(value);
        if (T == u32) return self.putVariantU32(value);
        if (T == i32) return self.putVariantI32(value);
        if (T == u64) {
            try self.putSignature("t");
            return self.putU64(value);
        }
        const s: []const u8 = value;
        return self.putVariantString(s);
    }

    /// One a{sv} entry: `key` and a variant of `value` (see putVariant).
    pub fn putEntry(self: *Marshal, key: []const u8, value: anytype) !void {
        try self.beginStruct();
        try self.putString(key);
        try self.putVariant(value);
    }

    /// Begin an a{sv}; add entries, then end() it.
    pub fn beginDict(self: *Marshal) !Dict {
        return .{ .m = self, .mark = try self.beginArray(8) };
    }

    /// An a{sv} being written (beginDict).
    pub const Dict = struct {
        m: *Marshal,
        mark: ArrayMark,

        pub fn entry(self: Dict, key: []const u8, value: anytype) !void {
            try self.m.putEntry(key, value);
        }

        /// A request handle token entry (`handle_token`,
        /// `session_handle_token`): a fresh token made into `buf` from
        /// `prefix` (makeToken), written under `key` and returned.
        pub fn token(self: Dict, key: []const u8, buf: []u8, prefix: []const u8) ![]const u8 {
            const t = try makeToken(buf, prefix);
            try self.entry(key, t);
            return t;
        }

        pub fn end(self: Dict) void {
            self.m.endArray(self.mark);
        }
    };

    /// Begin an array: returns position of the length field. Call endArray
    /// after writing elements. elem_alignment is the alignment of one element.
    pub fn beginArray(self: *Marshal, elem_alignment: usize) !ArrayMark {
        try self.pad(4);
        const len_pos = self.buf.items.len;
        try self.buf.appendSlice(self.alloc, &.{ 0, 0, 0, 0 });
        try self.pad(elem_alignment);
        return .{ .len_pos = len_pos, .start = self.buf.items.len };
    }
    pub fn endArray(self: *Marshal, mark: ArrayMark) void {
        const len: u32 = @intCast(self.buf.items.len - mark.start);
        @memcpy(self.buf.items[mark.len_pos..][0..4], std.mem.asBytes(&len));
    }
    pub const ArrayMark = struct { len_pos: usize, start: usize };

    /// dict entries and structs are 8-aligned
    pub fn beginStruct(self: *Marshal) !void {
        try self.pad(8);
    }
};

/// A handle token for a request-style call: unique per request, only
/// [A-Za-z0-9_] as the portal spec asks.
pub fn makeToken(buf: []u8, prefix: []const u8) ![]u8 {
    var rnd: [8]u8 = undefined;
    sys.getRandom(&rnd);
    return std.fmt.bufPrint(buf, "{s}{d}_{x}", .{ prefix, std.os.linux.getpid(), std.mem.readInt(u64, &rnd, .little) });
}

test "putEntry writes the same bytes as the hand-written entry" {
    const alloc = std.testing.allocator;
    var a = Marshal.init(alloc);
    defer a.deinit();
    const d = try a.beginDict();
    try d.entry("s", "text");
    try d.entry("b", true);
    try d.entry("u", @as(u32, 7));
    try d.entry("i", @as(i32, -3));
    d.end();

    var b = Marshal.init(alloc);
    defer b.deinit();
    const arr = try b.beginArray(8);
    try b.beginStruct();
    try b.putString("s");
    try b.putVariantString("text");
    try b.beginStruct();
    try b.putString("b");
    try b.putVariantBool(true);
    try b.beginStruct();
    try b.putString("u");
    try b.putVariantU32(7);
    try b.beginStruct();
    try b.putString("i");
    try b.putVariantI32(-3);
    b.endArray(arr);
    try std.testing.expectEqualSlices(u8, b.buf.items, a.buf.items);
}

test "a handle token entry carries the token it returns" {
    const alloc = std.testing.allocator;
    var m = Marshal.init(alloc);
    defer m.deinit();
    var buf: [64]u8 = undefined;
    const d = try m.beginDict();
    const tok = try d.token("handle_token", &buf, "shotlet_r");
    d.end();
    try std.testing.expect(std.mem.startsWith(u8, tok, "shotlet_r"));
    for (tok) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '_');
    var r = @import("reader.zig").Reader{ .data = m.buf.items, .pos = 0 };
    var it = try r.readDictSV();
    const e = (try it.next()).?;
    try std.testing.expectEqualStrings("handle_token", e.key);
    try std.testing.expectEqualStrings(tok, e.value.string);
}

test "marshal alignment" {
    var m = Marshal.init(std.testing.allocator);
    defer m.deinit();
    try m.putByte(1);
    try m.putU32(0xAABBCCDD);
    try std.testing.expectEqual(@as(usize, 8), m.buf.items.len);
    try std.testing.expectEqual(@as(u8, 0xDD), m.buf.items[4]);
}
