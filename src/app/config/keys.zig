//! How a config key is read and written: one line parser, one bool
//! parser and one table-driven reader/formatter for every section of the
//! config file (model.zig's core settings, modes.zig, record.zig). A key
//! names its field (a path like "record.fps" inside nested structs) and
//! how its value is spelled; the field's own default is the only default.
//! Unknown keys and malformed values never fail: they keep the value the
//! field has (its default unless an earlier line set it).

const std = @import("std");

pub const Kind = union(enum) {
    /// true or false, see parseBool
    flag,
    /// one of the field's enum tags
    tag,
    /// an integer clamped to [min, max]
    int: struct { min: i64, max: i64 },
    /// an integer, kept only when it is one of these
    one_of: []const i64,
    /// an integer snapped to the nearest of these
    nearest: []const i64,
    /// the index of one of these names
    names: []const []const u8,
    /// text kept in the field (a byte array); the length goes to the
    /// field named here
    text: []const u8,
};

pub const Key = struct {
    name: []const u8,
    field: []const u8,
    kind: Kind,
};

pub const Line = struct { key: []const u8, value: []const u8 };

/// "key = value" with surrounding blanks trimmed; null for a blank line,
/// a comment (#) or a line without '='.
pub fn parseLine(line: []const u8) ?Line {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, trimmed[0..eq], " \t"),
        .value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t"),
    };
}

const true_words = [_][]const u8{ "true", "yes", "on", "1" };
const false_words = [_][]const u8{ "false", "no", "off", "0" };

/// true/yes/on/1 or false/no/off/0, in any letter case; null for anything
/// else (the setting then keeps its value). Shotlet writes true/false.
pub fn parseBool(value: []const u8) ?bool {
    for (true_words) |w| if (std.ascii.eqlIgnoreCase(value, w)) return true;
    for (false_words) |w| if (std.ascii.eqlIgnoreCase(value, w)) return false;
    return null;
}

pub fn boolText(v: bool) []const u8 {
    return if (v) "true" else "false";
}

/// The keys of struct `T` described by `keys`.
pub fn Section(comptime T: type, comptime keys: []const Key) type {
    return struct {
        pub const len = keys.len;

        /// Set the field `key` names from `value`; false when none does.
        pub fn apply(s: *T, key: []const u8, value: []const u8) bool {
            const i = find(key) orelse return false;
            inline for (keys, 0..) |k, j| if (i == j) applyKey(k, s, value);
            return true;
        }

        fn find(key: []const u8) ?usize {
            for (names, 0..) |n, i| if (std.mem.eql(u8, n, key)) return i;
            return null;
        }

        const names = blk: {
            var out: [keys.len][]const u8 = undefined;
            for (keys, 0..) |k, i| out[i] = k.name;
            break :blk out;
        };

        /// The number of the key named `name` (comptime).
        pub fn index(comptime key: []const u8) usize {
            inline for (keys, 0..) |k, i| {
                if (comptime std.mem.eql(u8, k.name, key)) return i;
            }
            @compileError("no config key " ++ key);
        }

        pub fn name(i: usize) []const u8 {
            return names[i];
        }

        /// Key `i`'s value in `s` as the file spells it.
        pub fn format(s: *const T, i: usize, buf: []u8) []const u8 {
            inline for (keys, 0..) |k, j| if (i == j) return formatKey(k, s, buf);
            unreachable;
        }
    };
}

/// `keys` with every field path (and text length field) put under
/// `prefix`: a section's keys as fields of the struct holding it.
pub fn within(comptime prefix: []const u8, comptime keys: []const Key) [keys.len]Key {
    var out: [keys.len]Key = undefined;
    for (keys, 0..) |k, i| {
        out[i] = k;
        out[i].field = prefix ++ "." ++ k.field;
        if (k.kind == .text) out[i].kind = .{ .text = prefix ++ "." ++ k.kind.text };
    }
    return out;
}

fn FieldPtr(comptime P: type, comptime path: []const u8) type {
    const info = @typeInfo(P).pointer;
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const Sub = @FieldType(info.child, path[0..dot]);
        return FieldPtr(if (info.attrs.@"const") *const Sub else *Sub, path[dot + 1 ..]);
    }
    const F = @FieldType(info.child, path);
    return if (info.attrs.@"const") *const F else *F;
}

/// The field at `path` ("a" or "a.b") of the struct `s` points to.
fn fieldPtr(s: anytype, comptime path: []const u8) FieldPtr(@TypeOf(s), path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return fieldPtr(&@field(s, path[0..dot]), path[dot + 1 ..]);
    }
    return &@field(s, path);
}

fn applyKey(comptime k: Key, s: anytype, v: []const u8) void {
    const f = fieldPtr(s, k.field);
    const F = @TypeOf(f.*);
    switch (k.kind) {
        .flag => f.* = parseBool(v) orelse f.*,
        .tag => f.* = std.meta.stringToEnum(F, v) orelse f.*,
        .int => |r| {
            const n = std.fmt.parseInt(i64, v, 10) catch return;
            f.* = @intCast(std.math.clamp(n, r.min, r.max));
        },
        .one_of => |choices| {
            const n = std.fmt.parseInt(i64, v, 10) catch return;
            if (std.mem.indexOfScalar(i64, choices, n) != null) f.* = @intCast(n);
        },
        .nearest => |choices| {
            const n = std.fmt.parseInt(i64, v, 10) catch return;
            f.* = @intCast(nearest(choices, n));
        },
        .names => |names| {
            for (names, 0..) |nm, i| {
                if (std.mem.eql(u8, v, nm)) f.* = @intCast(i);
            }
        },
        .text => |len_field| {
            const n = @min(v.len, f.len);
            @memcpy(f[0..n], v[0..n]);
            fieldPtr(s, len_field).* = n;
        },
    }
}

fn formatKey(comptime k: Key, s: anytype, buf: []u8) []const u8 {
    const f = fieldPtr(s, k.field);
    return switch (k.kind) {
        .flag => boolText(f.*),
        .tag => @tagName(f.*),
        .int, .one_of, .nearest => std.fmt.bufPrint(buf, "{d}", .{f.*}) catch unreachable,
        .names => |names| names[f.*],
        .text => |len_field| f[0..fieldPtr(s, len_field).*],
    };
}

/// The one of `choices` nearest `v` (the first on a tie).
pub fn nearest(choices: []const i64, v: i64) i64 {
    var best = choices[0];
    for (choices) |c| {
        if (@abs(v - c) < @abs(v - best)) best = c;
    }
    return best;
}

test "every spelling of a bool" {
    for ([_][]const u8{ "true", "TRUE", "True", "yes", "on", "1" }) |v| try std.testing.expectEqual(@as(?bool, true), parseBool(v));
    for ([_][]const u8{ "false", "FALSE", "False", "no", "Off", "0" }) |v| try std.testing.expectEqual(@as(?bool, false), parseBool(v));
    for ([_][]const u8{ "", "maybe", "2", "truee" }) |v| try std.testing.expectEqual(@as(?bool, null), parseBool(v));
}

test "lines: blanks, comments, spaces around the key and the value" {
    try std.testing.expectEqual(@as(?Line, null), parseLine("  # notify=true"));
    try std.testing.expectEqual(@as(?Line, null), parseLine(" \t\r"));
    try std.testing.expectEqual(@as(?Line, null), parseLine("notify"));
    const kv = parseLine("  notify \t=  false \r").?;
    try std.testing.expectEqualStrings("notify", kv.key);
    try std.testing.expectEqualStrings("false", kv.value);
    try std.testing.expectEqualStrings("a=b", parseLine("k=a=b").?.value);
}

test "a section reads and writes its keys, keeping values it cannot read" {
    const Mode = enum { a, b };
    const S = struct {
        on: bool = true,
        n: u8 = 5,
        pick: u8 = 3,
        snap: u8 = 8,
        mode: Mode = .a,
        size: u2 = 1,
        txt: [4]u8 = @splat(0),
        txt_len: usize = 0,
        inner: struct { off: bool = false } = .{},
    };
    const keys = [_]Key{
        .{ .name = "on", .field = "on", .kind = .flag },
        .{ .name = "n", .field = "n", .kind = .{ .int = .{ .min = 1, .max = 10 } } },
        .{ .name = "pick", .field = "pick", .kind = .{ .one_of = &.{ 3, 5 } } },
        .{ .name = "snap", .field = "snap", .kind = .{ .nearest = &.{ 4, 8, 16 } } },
        .{ .name = "mode", .field = "mode", .kind = .tag },
        .{ .name = "size", .field = "size", .kind = .{ .names = &.{ "s", "m", "l" } } },
        .{ .name = "txt", .field = "txt", .kind = .{ .text = "txt_len" } },
        .{ .name = "off", .field = "inner.off", .kind = .flag },
    };
    const Sec = Section(S, &keys);
    var s: S = .{};
    for ([_][2][]const u8{
        .{ "on", "maybe" }, .{ "n", "x" },     .{ "pick", "4" },  .{ "snap", "zz" },
        .{ "mode", "c" },   .{ "size", "xl" }, .{ "off", "nah" },
    }) |kv| try std.testing.expect(Sec.apply(&s, kv[0], kv[1]));
    try std.testing.expectEqual(S{}, s);
    try std.testing.expect(!Sec.apply(&s, "nope", "1"));
    for ([_][2][]const u8{
        .{ "on", "no" },  .{ "n", "99" },   .{ "pick", "5" },     .{ "snap", "13" },
        .{ "mode", "b" }, .{ "size", "l" }, .{ "txt", "abcdef" }, .{ "off", "yes" },
    }) |kv| _ = Sec.apply(&s, kv[0], kv[1]);
    var buf: [16]u8 = undefined;
    const want = [_][]const u8{ "false", "10", "5", "16", "b", "l", "abcd", "true" };
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, Sec.format(&s, i, &buf));
    try std.testing.expectEqual(@as(usize, 7), Sec.index("off"));
    try std.testing.expectEqualStrings("off", Sec.name(7));
}
