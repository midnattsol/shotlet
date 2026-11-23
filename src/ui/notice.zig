//! A word shown over a card for a moment ("Copied", "Saved", "Failed"):
//! the quick access cards, the quick video card and the history panel.
//! floatui.notice draws it; this is when it shows.
//!
//! A save on a thumbnail ends it: "✓ Saved" (`showSaved`) for `end_ms`,
//! then the card fades out (the card does that; Alt held keeps it).

const std = @import("std");
const fui = @import("floatui.zig");
const theme = @import("theme.zig");
const Rect = @import("shapes.zig").Rect;
const Canvas = fui.Canvas;

/// how long a word shows
pub const word_ms = 1200;
/// how long "✓ Saved" shows before the card that says it goes
pub const end_ms = 700;

pub const Notice = struct {
    word: []const u8 = "",
    /// when it goes (monotonic ms), 0 while none shows
    until: i64 = 0,
    /// a check before the word (something done)
    check: bool = false,

    /// Show `word` from `now` for `ms`.
    pub fn show(n: *Notice, word: []const u8, now: i64, ms: i64) void {
        n.* = .{ .word = word, .until = now + ms };
    }

    /// "✓ Saved" from `now`, for as long as the card stays after it
    /// (`ms`: end_ms when it ends the card).
    pub fn showSaved(n: *Notice, now: i64, ms: i64) void {
        n.* = .{ .word = "Saved", .until = now + ms, .check = true };
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

    /// Draw it centred in `area` (`k` physical px per logical px).
    pub fn draw(n: *const Notice, cv: *Canvas, area: Rect, now: i64, k: f64, th: theme.Theme) void {
        const word = n.text(now);
        if (word.len == 0) return;
        if (n.check) fui.noticeDone(cv, area, word, k, th) else fui.notice(cv, area, word, k, th);
    }
};

const testing = std.testing;

test "a notice shows for its time, then goes once" {
    var n: Notice = .{};
    try testing.expectEqualStrings("", n.text(0));
    try testing.expectEqual(null, n.left(0));
    n.show("Copied", 1000, 1200);
    try testing.expectEqualStrings("Copied", n.text(2199));
    try testing.expectEqual(@as(?i64, 200), n.left(2000));
    try testing.expect(!n.expire(2199));
    try testing.expectEqualStrings("", n.text(2200));
    try testing.expect(n.expire(2200));
    try testing.expect(!n.expire(2300));
}

test "Saved carries the check, a later word does not" {
    var n: Notice = .{};
    n.showSaved(0, end_ms);
    try testing.expect(n.check);
    try testing.expectEqualStrings("Saved", n.text(end_ms - 1));
    try testing.expectEqualStrings("", n.text(end_ms));
    n.show("Copied", 0, word_ms);
    try testing.expect(!n.check);
}

test "the checked notice draws wider than the plain one" {
    const text_mod = @import("../gfx/text.zig");
    text_mod.init(testing.allocator);
    defer text_mod.deinit();
    if (!text_mod.available()) return error.SkipZigTest;
    const th = theme.Theme.get(false, null);
    var buf: [240 * 150]u32 = undefined;
    var cv = Canvas.init(&buf, 240, 150);
    const area: Rect = .{ .x = 0, .y = 0, .w = 240, .h = 150 };
    var n: Notice = .{};
    var widths: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |check, i| {
        @memset(&buf, 0);
        if (check) n.showSaved(0, end_ms) else n.show("Saved", 0, word_ms);
        n.draw(&cv, area, 0, 1, th);
        var w: usize = 0;
        for (buf[75 * 240 ..][0..240]) |p| w += @intFromBool(p != 0);
        widths[i] = w;
    }
    try testing.expect(widths[0] > 0);
    try testing.expect(widths[1] > widths[0]);
}
