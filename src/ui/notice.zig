//! A word shown over a card for a moment ("Copied", "Saved", "Failed"):
//! the quick access cards, the quick video card and the history panel.
//! floatui.notice draws it; this is when it shows.

pub const Notice = struct {
    word: []const u8 = "",
    /// when it goes (monotonic ms), 0 while none shows
    until: i64 = 0,

    /// Show `word` from `now` for `ms`.
    pub fn show(n: *Notice, word: []const u8, now: i64, ms: i64) void {
        n.* = .{ .word = word, .until = now + ms };
    }

    /// The word while it shows, else "".
    pub fn text(n: *const Notice, now: i64) []const u8 {
        return if (n.until != 0 and now < n.until) n.word else "";
    }

    /// Clear it once its time is up; true when it just went (the card
    /// needs a repaint).
    pub fn expire(n: *Notice, now: i64) bool {
        if (n.until == 0 or now < n.until) return false;
        n.* = .{};
        return true;
    }

    /// The milliseconds left until it goes, null while none shows.
    pub fn left(n: *const Notice, now: i64) ?i64 {
        return if (n.until == 0) null else n.until - now;
    }
};

test "a notice shows for its time, then goes once" {
    const std = @import("std");
    var n: Notice = .{};
    try std.testing.expectEqualStrings("", n.text(0));
    try std.testing.expectEqual(null, n.left(0));
    n.show("Copied", 1000, 1200);
    try std.testing.expectEqualStrings("Copied", n.text(2199));
    try std.testing.expectEqual(@as(?i64, 200), n.left(2000));
    try std.testing.expect(!n.expire(2199));
    try std.testing.expectEqualStrings("", n.text(2200));
    try std.testing.expect(n.expire(2200));
    try std.testing.expect(!n.expire(2300));
}
