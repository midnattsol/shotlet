//! Why a scrolling capture stops, decided from what each frame did to the
//! stitched image (stitch.Push), and how to say it.
//!
//! Stable API:
//!   Reason                 every way a capture ends or pauses
//!   Reason.natural()       the capture is complete: finish
//!   Reason.message(buf, max_height)  the plain words shown in the control
//!   Note                   those words, kept for the editor to show
//!   Watch.feed(push, clicks)  fold one frame in: go on, scroll slower,
//!                          warn (and go on), or stop for a reason
//!   Watch.restart()        after Continue: count afresh
//!
//! When Shotlet turns the wheel (auto): two frames in a row that the
//! wheel did not move end it; at the end of the page when the wheel had
//! moved the content, else the page never moved. Content that moves by
//! itself (a terminal's output arriving at the bottom, a few lines at a
//! time) is stitched, but it is not the wheel's doing: a step that moved
//! less than an eighth of the region (`Watch.min_move`), or less than
//! `min_notch_px` a notch, counts as one that did not move. Else a
//! terminal at the bottom of its scrollback ended "at the end of the
//! page" with what it printed meanwhile, never saying the wheel did
//! nothing. (A wheel step aims at half the region; the first, of three
//! notches, moved a GTK page 40 % of it and Ghostty a third. A page
//! that can scroll less than an eighth of the region pauses as "didn't
//! move", with what it moved kept for Finish.) No overlap shrinks the step to one notch, and
//! no overlap at one notch stops it. When the person scrolls, nothing
//! moving is just waiting, and no overlap is a warning: scrolling back a
//! little lines it up again by itself.

const std = @import("std");
const stitch = @import("stitch.zig");
const grouped = @import("../../ui/scroll_hud.zig").grouped;

/// The least a wheel notch moves content: a line of text at scale 1
/// (terminals move 1 to 6 lines a notch, GTK 123 logical px).
pub const min_notch_px = 16;

pub const Reason = enum {
    /// the content stopped moving after it had moved
    end_of_page,
    /// scroll_max_height reached
    height_limit,
    /// Stop, Finish or Enter
    user_stopped,
    /// Shotlet turned the wheel and nothing ever moved
    didnt_move,
    /// the next frame lines up nowhere, even one notch at a time
    no_match,
    /// the frames stopped coming (the session timed out, the region left
    /// the screen, its size changed)
    lost,

    /// Complete: the image goes to the editor. The others pause with
    /// Continue, Finish and Cancel.
    pub fn natural(self: Reason) bool {
        return switch (self) {
            .end_of_page, .height_limit, .user_stopped => true,
            .didnt_move, .no_match, .lost => false,
        };
    }

    pub fn message(self: Reason, buf: []u8, max_height: u32) []const u8 {
        return switch (self) {
            .end_of_page => "Reached the end of the page",
            .height_limit => limitMessage(buf, max_height),
            .user_stopped => "Stopped",
            .didnt_move => "The page didn\u{2019}t move \u{2014} scroll manually or try again",
            .no_match => "Couldn\u{2019}t match the next part \u{2014} try a slower scroll",
            .lost => "Lost sight of the region \u{2014} Continue to try again",
        };
    }
};

fn limitMessage(buf: []u8, max_height: u32) []const u8 {
    var nbuf: [24]u8 = undefined;
    const n = grouped(&nbuf, max_height);
    return std.fmt.bufPrint(buf, "Stopped at the {s} px limit", .{n}) catch "Stopped at the height limit";
}

/// Why a capture ended by itself, for the editor that opens on it (empty:
/// nothing to say, the person ended it).
pub const Note = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Note, msg: []const u8) void {
        self.len = @min(msg.len, self.buf.len);
        @memcpy(self.buf[0..self.len], msg[0..self.len]);
    }

    pub fn text(self: *const Note) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Verdict = union(enum) {
    go,
    /// moved too far: halve the notches and go on
    slower,
    /// go on, saying this in the control (the person scrolls)
    warn: Reason,
    stop: Reason,
};

pub const Watch = struct {
    /// Shotlet turns the wheel (else the person scrolls)
    auto: bool,
    /// something was appended since the capture started (auto: by the
    /// wheel)
    moved: bool = false,
    /// frames in a row that did not move
    still: u32 = 0,
    /// frames in a row that lined up nowhere
    misses: u32 = 0,
    /// rows a step must move to be the wheel's doing (auto): an eighth
    /// of the region, set from the first frame
    min_move: u32 = 0,

    /// One frame's outcome (after the session looked again at a frame
    /// that seemed not to move or not to line up). `clicks`: the notches
    /// turned before it.
    pub fn feed(self: *Watch, r: stitch.Push, clicks: i32) Verdict {
        switch (r) {
            .appended => |d| {
                self.misses = 0;
                if (self.auto and clicks > 0 and !self.byWheel(d, clicks)) return self.stood();
                self.moved = true;
                self.still = 0;
                return .go;
            },
            .full => return .{ .stop = .height_limit },
            .unchanged => {
                self.misses = 0;
                if (!self.auto) return .go;
                return self.stood();
            },
            .no_overlap => {
                self.misses += 1;
                if (!self.auto) return if (self.misses >= 2) .{ .warn = .no_match } else .go;
                return if (clicks <= 1) .{ .stop = .no_match } else .slower;
            },
        }
    }

    /// A step of `clicks` notches that moved the content `d` rows: far
    /// enough to be the wheel's doing, not content moving by itself.
    fn byWheel(self: *const Watch, d: u32, clicks: i32) bool {
        return d >= self.min_move and d >= @as(u32, @intCast(clicks)) * min_notch_px;
    }

    /// A step the wheel did not move (auto): two in a row end it.
    fn stood(self: *Watch) Verdict {
        self.still += 1;
        if (self.still < 2) return .go;
        return .{ .stop = if (self.moved) .end_of_page else .didnt_move };
    }

    /// Continue: count afresh (what moved before still counts).
    pub fn restart(self: *Watch) void {
        self.still = 0;
        self.misses = 0;
    }
};

// --- tests: synthetic frame sequences through the real stitcher ---

const testing = std.testing;
const fw = 32;
const fh = 240;

/// The view of a page scrolled by `off` rows; every row distinct.
fn frameAt(buf: []u32, off: u32) stitch.Frame {
    for (0..fh) |y| for (0..fw) |x| {
        const h = std.hash.Wyhash.hash(off + @as(u32, @intCast(y)), "page");
        buf[y * fw + x] = 0xFF000000 | @as(u32, @truncate(h >> @intCast(x % 8)));
    };
    return .{ .pixels = buf, .width = fw, .height = fh };
}

/// Feed frames at these offsets (the first starts the stitcher), turning
/// `clicks` notches per frame, halved on .slower as the session does.
/// The first stop, or null.
fn run(offsets: []const u32, auto: bool, max_height: u32, warned: ?*?Reason) !?Reason {
    var buf: [fw * fh]u32 = undefined;
    var st = try stitch.Stitcher.init(testing.allocator, frameAt(&buf, offsets[0]), max_height);
    defer st.deinit();
    var w: Watch = .{ .auto = auto };
    var clicks: i32 = 3;
    for (offsets[1..]) |off| {
        switch (w.feed(try st.push(frameAt(&buf, off)), clicks)) {
            .go => {},
            .slower => clicks = @max(1, @divTrunc(clicks, 2)),
            .warn => |r| if (warned) |p| {
                p.* = r;
            },
            .stop => |r| return r,
        }
    }
    return null;
}

test "identical frames: the page didn't move" {
    try testing.expectEqual(Reason.didnt_move, (try run(&.{ 0, 0, 0 }, true, 20_000, null)).?);
}

test "moving, then identical frames: the end of the page" {
    try testing.expectEqual(Reason.end_of_page, (try run(&.{ 0, 80, 160, 220, 220, 220 }, true, 20_000, null)).?);
    // one still frame (a slow repaint) is not the end
    try testing.expectEqual(@as(?Reason, null), try run(&.{ 0, 80, 80, 160 }, true, 20_000, null));
}

test "content moving by itself while the wheel does nothing: didn't move" {
    // a terminal at the bottom of its scrollback (a region 1851 px
    // tall), printing a line or two now and then: 28 or 55 px while three
    // notches turned, 111 px while ten did
    var w: Watch = .{ .auto = true, .min_move = 1851 / 8 };
    try testing.expectEqual(Verdict.go, w.feed(.{ .appended = 55 }, 3));
    try testing.expectEqual(Verdict{ .stop = .didnt_move }, w.feed(.{ .appended = 111 }, 10));
    try testing.expect(!w.moved);
    // after the wheel moved it, the same is the end of the page
    var m: Watch = .{ .auto = true, .min_move = 1851 / 8 };
    try testing.expectEqual(Verdict.go, m.feed(.{ .appended = 499 }, 3));
    try testing.expectEqual(Verdict.go, m.feed(.{ .appended = 28 }, 10));
    try testing.expectEqual(Verdict{ .stop = .end_of_page }, m.feed(.unchanged, 10));
    // a short last step at the end of a real scroll: the end
    var e: Watch = .{ .auto = true, .min_move = 1500 / 8 };
    try testing.expectEqual(Verdict.go, e.feed(.{ .appended = 666 }, 4));
    try testing.expectEqual(Verdict.go, e.feed(.{ .appended = 111 }, 4));
    try testing.expectEqual(Verdict{ .stop = .end_of_page }, e.feed(.unchanged, 4));
    // many notches that moved little each are not the wheel either
    var n: Watch = .{ .auto = true };
    _ = n.feed(.{ .appended = 100 }, 10);
    try testing.expect(!n.moved);
    // the person scrolling: whatever moved counts
    var p: Watch = .{ .auto = false };
    try testing.expectEqual(Verdict.go, p.feed(.{ .appended = 3 }, 0));
    try testing.expect(p.moved);
}

test "no overlap: slower first, then couldn't match" {
    try testing.expectEqual(Reason.no_match, (try run(&.{ 0, 2000, 4000 }, true, 20_000, null)).?);
    // a smaller step that lines up again carries on
    try testing.expectEqual(@as(?Reason, null), try run(&.{ 0, 2000, 120, 240 }, true, 20_000, null));
}

test "the height cap stops at the limit" {
    var offs: [40]u32 = undefined;
    for (&offs, 0..) |*o, i| o.* = @intCast(i * 120);
    try testing.expectEqual(Reason.height_limit, (try run(&offs, true, 2000, null)).?);
}

test "the person scrolling: waiting is fine, no overlap only warns" {
    var warned: ?Reason = null;
    try testing.expectEqual(@as(?Reason, null), try run(&.{ 0, 0, 0, 0, 0, 100 }, false, 20_000, &warned));
    try testing.expectEqual(@as(?Reason, null), warned);
    try testing.expectEqual(@as(?Reason, null), try run(&.{ 0, 3600, 3800, 100, 200 }, false, 20_000, &warned));
    try testing.expectEqual(Reason.no_match, warned.?);
    // and the end of the page is the person's Stop, not a guess
    try testing.expectEqual(@as(?Reason, null), try run(&.{ 0, 120, 120, 120, 120 }, false, 20_000, null));
}

test "only natural stops finish; the messages say why" {
    var buf: [64]u8 = undefined;
    try testing.expect(Reason.end_of_page.natural() and Reason.height_limit.natural() and Reason.user_stopped.natural());
    try testing.expect(!Reason.didnt_move.natural() and !Reason.no_match.natural() and !Reason.lost.natural());
    try testing.expectEqualStrings("Stopped at the 20\u{2009}000 px limit", Reason.height_limit.message(&buf, 20_000));
    try testing.expectEqualStrings("Reached the end of the page", Reason.end_of_page.message(&buf, 0));
    try testing.expectEqualStrings("1\u{2009}234\u{2009}567", grouped(&buf, 1_234_567));
    try testing.expectEqualStrings("999", grouped(&buf, 999));
}

test "Continue counts afresh" {
    var w: Watch = .{ .auto = true };
    try testing.expectEqual(Verdict.go, w.feed(.unchanged, 3));
    w.restart();
    try testing.expectEqual(Verdict.go, w.feed(.unchanged, 3));
    try testing.expectEqual(Verdict{ .stop = .didnt_move }, w.feed(.unchanged, 3));
}
