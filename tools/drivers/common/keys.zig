//! Key names for the drivers' `key`, `hold` and `type` commands: evdev
//! key codes by name (US physical positions; the compositor's keymap
//! decides what they type).

const std = @import("std");

const table = [_]struct { []const u8, u32 }{
    .{ "esc", 1 },       .{ "minus", 12 },     .{ "equal", 13 },      .{ "backspace", 14 },
    .{ "tab", 15 },      .{ "leftbrace", 26 }, .{ "rightbrace", 27 }, .{ "enter", 28 },
    .{ "ctrl", 29 },     .{ "semicolon", 39 }, .{ "apostrophe", 40 }, .{ "grave", 41 },
    .{ "shift", 42 },    .{ "backslash", 43 }, .{ "comma", 51 },      .{ "dot", 52 },
    .{ "slash", 53 },    .{ "rshift", 54 },    .{ "alt", 56 },        .{ "space", 57 },
    .{ "capslock", 58 }, .{ "f1", 59 },        .{ "f2", 60 },         .{ "102nd", 86 },
    .{ "rctrl", 97 },    .{ "print", 99 },     .{ "altgr", 100 },     .{ "home", 102 },
    .{ "up", 103 },      .{ "pageup", 104 },   .{ "left", 105 },      .{ "right", 106 },
    .{ "end", 107 },     .{ "down", 108 },     .{ "pagedown", 109 },  .{ "insert", 110 },
    .{ "delete", 111 },  .{ "super", 125 },
};

/// The evdev code of a key name: a letter, a digit, a name from the
/// table, or `#N` for raw code N.
pub fn keyCode(name: []const u8) ?u32 {
    if (name.len > 1 and name[0] == '#') return std.fmt.parseInt(u32, name[1..], 10) catch null;
    if (name.len == 1) {
        const c = name[0];
        if (std.mem.indexOfScalar(u8, "qwertyuiop", c)) |i| return @intCast(16 + i);
        if (std.mem.indexOfScalar(u8, "asdfghjkl", c)) |i| return @intCast(30 + i);
        if (std.mem.indexOfScalar(u8, "zxcvbnm", c)) |i| return @intCast(44 + i);
        if (c >= '1' and c <= '9') return @intCast(2 + c - '1');
        if (c == '0') return 11;
    }
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

/// Parse "ctrl+shift+s" into `codes`; the number of keys.
pub fn parseCombo(combo: []const u8, codes: *[8]u32) !usize {
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, combo, '+');
    while (parts.next()) |p| {
        if (n == codes.len) return error.TooManyKeys;
        codes[n] = keyCode(p) orelse return error.UnknownKey;
        n += 1;
    }
    return n;
}

/// The xkb modifier mask (us keymap) a modifier key sets; 0 for others.
pub fn modMask(code: u32) u32 {
    return switch (code) {
        42, 54 => 1, // Shift
        29, 97 => 4, // Control
        56 => 8, // Mod1 (Alt)
        125 => 64, // Mod4 (Super)
        100 => 128, // Mod5 (AltGr)
        else => 0,
    };
}

test "key names" {
    try std.testing.expectEqual(@as(?u32, 30), keyCode("a"));
    try std.testing.expectEqual(@as(?u32, 11), keyCode("0"));
    try std.testing.expectEqual(@as(?u32, 99), keyCode("print"));
    try std.testing.expectEqual(@as(?u32, 86), keyCode("102nd"));
    try std.testing.expectEqual(@as(?u32, 42), keyCode("#42"));
    try std.testing.expectEqual(@as(?u32, null), keyCode("nope"));
}

test "combos" {
    var codes: [8]u32 = undefined;
    const n = try parseCombo("ctrl+shift+s", &codes);
    try std.testing.expectEqualSlices(u32, &.{ 29, 42, 31 }, codes[0..n]);
    try std.testing.expectError(error.UnknownKey, parseCombo("ctrl+nope", &codes));
}
