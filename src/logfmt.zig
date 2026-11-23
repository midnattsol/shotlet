//! How Shotlet's log lines read (src/main.zig's std_options.logFn):
//! `LEVEL: SUBSYSTEM: message`, on stderr.
//!
//! Every file logs through its subsystem's scoped logger,
//! `const log = std.log.scoped(.quick_access);`. Scopes are snake_case
//! subsystem names (pin, quick_access, history, capture, record for the
//! command, recording for the capture and encoding under it, editor,
//! window, portal...), shown with spaces ("quick access"). A message that
//! already starts with that name ("capture cancelled") is not prefixed
//! twice. Levels: err (the user's action failed), warn (degraded, or worth
//! a look), info (the flow), debug (details).

const std = @import("std");

pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    std.log.defaultLog(level, .default, comptime prefixed(scope, format), args);
}

/// `format` with its subsystem's name in front.
pub fn prefixed(comptime scope: @EnumLiteral(), comptime format: []const u8) []const u8 {
    if (scope == .default) return format;
    const words = comptime spaced(@tagName(scope));
    if (startsWithWord(format, words)) return format;
    return words ++ ": " ++ format;
}

fn spaced(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |c, i| out[i] = if (c == '_') ' ' else c;
        const final = out;
        return &final;
    }
}

/// `s` starts with the word(s) `w` followed by a space, a colon or its end.
fn startsWithWord(s: []const u8, w: []const u8) bool {
    if (!std.mem.startsWith(u8, s, w)) return false;
    return s.len == w.len or s[w.len] == ' ' or s[w.len] == ':';
}

test "log lines carry their subsystem once" {
    try std.testing.expectEqualStrings("quick access: added {s}", prefixed(.quick_access, "added {s}"));
    try std.testing.expectEqualStrings("capture cancelled", prefixed(.capture, "capture cancelled"));
    try std.testing.expectEqualStrings("capture mode: {d}", prefixed(.capture, "capture mode: {d}"));
    try std.testing.expectEqualStrings("pin: pinning {s}", prefixed(.pin, "pinning {s}"));
    try std.testing.expectEqualStrings("record: recording", prefixed(.record, "recording"));
    try std.testing.expectEqualStrings("plain", prefixed(.default, "plain"));
}
