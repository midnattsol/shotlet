//! A word shown over a card for a moment ("Copied", "Saved", "Failed"):
//! the quick access cards, the quick video card and the history panel.
//!
//! "Saved" on a thumbnail is also a link (`showSaved`): "Saved · Show in
//! Files", which a click (press and release on it) or Enter / Space
//! while it shows opens in the file manager with the file selected. It
//! shows longer than a plain word, and stays while the pointer rests on
//! it. The card owns the click and the keys; this says when it shows,
//! where the link is (`hit`), draws it (`draw`) and keeps the file
//! (`file`).

const std = @import("std");
const fui = @import("floatui.zig");
const theme = @import("theme.zig");
const focus = @import("focus.zig");
const window = @import("../platform/api.zig").window;
const Rect = @import("shapes.zig").Rect;
const Canvas = fui.Canvas;

/// how long a plain word shows, and a link
pub const word_ms = 1200;
pub const link_ms = 4000;
/// what the link says
pub const saved_label = "Saved \u{00B7} Show in Files";
/// the longest path a link keeps (a longer one shows a plain "Saved")
const max_path = 2048;

pub const Notice = struct {
    word: []const u8 = "",
    /// when it goes (monotonic ms), 0 while none shows
    until: i64 = 0,
    /// the saved file the link shows (path_len 0: a plain word)
    path_buf: [max_path]u8 = undefined,
    path_len: usize = 0,

    /// Show `word` from `now` for `ms`.
    pub fn show(n: *Notice, word: []const u8, now: i64, ms: i64) void {
        n.word = word;
        n.until = now + ms;
        n.path_len = 0;
    }

    /// "Saved", as a link to `path` (the file manager shows it).
    pub fn showSaved(n: *Notice, path: []const u8, now: i64) void {
        if (path.len == 0 or path.len > max_path) return n.show("Saved", now, word_ms);
        n.show(saved_label, now, link_ms);
        @memcpy(n.path_buf[0..path.len], path);
        n.path_len = path.len;
    }

    /// The word while it shows, else "".
    pub fn text(n: *const Notice, now: i64) []const u8 {
        return if (n.until != 0 and now < n.until) n.word else "";
    }

    /// The file the link shows, while the link shows.
    pub fn file(n: *const Notice, now: i64) ?[]const u8 {
        if (n.path_len == 0 or n.text(now).len == 0) return null;
        return n.path_buf[0..n.path_len];
    }

    /// The pointer rests on the link: it stays a while longer.
    pub fn hold(n: *Notice, now: i64) void {
        if (n.file(now) != null) n.until = @max(n.until, now + word_ms);
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

    /// Whether the key press `k` opens the link: Enter or Space while it
    /// shows (a card with a control focused gives that control the key
    /// first).
    pub fn opensOn(n: *const Notice, k: window.Key, now: i64) bool {
        return n.file(now) != null and focus.action(k, .none) == .activate;
    }

    /// Whether the link, centred in `area` (logical px), is under x, y.
    pub fn hit(n: *const Notice, area: Rect, x: i32, y: i32, now: i64) bool {
        if (n.file(now) == null) return false;
        return fui.noticeRect(area, n.word, true, 1).contains(x, y);
    }

    /// Draw it centred in `area` (`k` physical px per logical px); `st`:
    /// the link under the pointer, or focused.
    pub fn draw(n: *const Notice, cv: *Canvas, area: Rect, now: i64, st: fui.State, k: f64, th: theme.Theme) void {
        const word = n.text(now);
        if (word.len == 0) return;
        if (n.file(now) != null) fui.noticeLink(cv, area, word, st, k, th) else fui.notice(cv, area, word, k, th);
    }
};

const testing = std.testing;
const text_mod = @import("../gfx/text.zig");

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

test "Saved is a link to the file while it shows, held under the pointer" {
    var n: Notice = .{};
    n.showSaved("/home/u/Pictures/a.png", 1000);
    try testing.expectEqualStrings(saved_label, n.text(1000));
    try testing.expectEqualStrings("/home/u/Pictures/a.png", n.file(1000 + link_ms - 1).?);
    try testing.expectEqual(null, n.file(1000 + link_ms));
    // the pointer on it near its end keeps it
    n.hold(1000 + link_ms - 10);
    try testing.expect(n.file(1000 + link_ms + 500) != null);
    try testing.expect(n.expire(1000 + link_ms - 10 + word_ms));
    try testing.expectEqual(null, n.file(0));
    // a plain word after a link is no link, and is not held
    n.showSaved("/x.png", 0);
    n.show("Copied", 10, word_ms);
    try testing.expectEqual(null, n.file(10));
    n.hold(10);
    try testing.expectEqual(@as(?i64, word_ms), n.left(10));
    // no path: a plain "Saved"
    n.showSaved("", 0);
    try testing.expectEqualStrings("Saved", n.text(0));
    try testing.expectEqual(null, n.file(0));
}

test "Enter and Space open the link while it shows" {
    const key = struct {
        fn of(code: window.KeyCode, ctrl: bool) window.Key {
            return .{ .code = code, .pressed = true, .ctrl = ctrl, .shift = false };
        }
    }.of;
    var n: Notice = .{};
    try testing.expect(!n.opensOn(key(.enter, false), 0));
    n.show("Copied", 0, word_ms);
    try testing.expect(!n.opensOn(key(.enter, false), 0));
    n.showSaved("/x.png", 0);
    try testing.expect(n.opensOn(key(.enter, false), 0));
    try testing.expect(n.opensOn(key(.space, false), 0));
    try testing.expect(n.opensOn(key(.kp_enter, false), 0));
    try testing.expect(!n.opensOn(key(.enter, true), 0));
    try testing.expect(!n.opensOn(key(.escape, false), 0));
    try testing.expect(!n.opensOn(key(.c, false), 0));
    var up = key(.enter, false);
    up.pressed = false;
    try testing.expect(!n.opensOn(up, 0));
    try testing.expect(!n.opensOn(key(.enter, false), link_ms));
}

test "the link is hit inside its pill, while it shows" {
    text_mod.init(testing.allocator);
    defer text_mod.deinit();
    if (!text_mod.available()) return error.SkipZigTest;
    const area: Rect = .{ .x = 0, .y = 0, .w = 240, .h = 150 };
    var n: Notice = .{};
    try testing.expect(!n.hit(area, 120, 75, 0));
    n.showSaved("/x.png", 0);
    try testing.expect(n.hit(area, 120, 75, 0));
    try testing.expect(!n.hit(area, 120, 30, 0));
    try testing.expect(!n.hit(area, 2, 75, 0));
    try testing.expect(!n.hit(area, 120, 75, link_ms));
    n.show("Copied", 0, word_ms);
    try testing.expect(!n.hit(area, 120, 75, 0));
}

test "the link draws in the accent under the pointer" {
    text_mod.init(testing.allocator);
    defer text_mod.deinit();
    if (!text_mod.available()) return error.SkipZigTest;
    const th = theme.Theme.get(false, null);
    var buf: [240 * 150]u32 = undefined;
    var cv = Canvas.init(&buf, 240, 150);
    const area: Rect = .{ .x = 0, .y = 0, .w = 240, .h = 150 };
    var n: Notice = .{};
    n.showSaved("/x.png", 0);
    @memset(&buf, 0);
    n.draw(&cv, area, 0, .{}, 1, th);
    const r = fui.noticeRect(area, n.word, true, 1);
    const edge = buf[@as(usize, @intCast(r.y + 15)) * 240 + @as(usize, @intCast(r.x + 6))];
    try testing.expect(edge != 0);
    @memset(&buf, 0);
    n.draw(&cv, area, 0, .{ .hot = true }, 1, th);
    try testing.expect(buf[@as(usize, @intCast(r.y + 15)) * 240 + @as(usize, @intCast(r.x + 6))] != edge);
}
