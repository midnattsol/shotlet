//! The video thumbnail card (record/quickvid.zig): the first picture,
//! the duration (and "GIF") in a badge; on hover the filmstrip plays and
//! Copy / Save as… / trim / close show, as on the screenshot thumbnail.

const std = @import("std");
const fui = @import("../floatui.zig");
const render = @import("../../gfx/render.zig");
const theme = @import("../theme.zig");
const scale = @import("../scale.zig");
const press = @import("../press.zig");
const control_draw = @import("control_draw.zig");
const Rect = @import("../shapes.zig").Rect;
const Notice = @import("../notice.zig").Notice;

pub const card_w = 240;
pub const card_h = 150;
/// room around the card for its shadow (theme card_shadow)
pub const pad = theme.card_room;

/// `notice`: "Saved · Show in Files" while it shows (ui/notice.zig;
/// quickvid finds it, it is not in `hit`)
pub const Control = enum { body, close, trim, copy, save_as, notice };

pub const View = struct {
    /// the picture shown (first frame, or a strip picture on hover)
    pic: []const u32,
    pic_w: u32,
    pic_h: u32,
    duration_ms: i64,
    gif: bool,
    hover: ?Control = null,
    hovered: bool = false,
    /// "Copied", "Saved · Show in Files" over the card, as at `now`
    notice: ?*const Notice = null,
    now: i64 = 0,
    alpha: f64 = 1,
    /// the desktop's appearance (the controls over the picture look the
    /// same in both; the card behind a narrow picture follows it)
    th: theme.Theme = theme.Theme.get(true, null),
};

pub fn windowSize() [2]u32 {
    return .{ card_w + 2 * pad, card_h + 2 * pad };
}

pub fn controlRect(c: Control) Rect {
    const pw = (card_w - 16 - 6) / 2;
    return switch (c) {
        .close => .{ .x = 8, .y = 8, .w = 26, .h = 26 },
        .trim => .{ .x = card_w - 8 - 26, .y = 8, .w = 26, .h = 26 },
        .copy => .{ .x = 8, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .save_as => .{ .x = 8 + pw + 6, .y = card_h - 8 - 30, .w = pw, .h = 30 },
        .body, .notice => .{ .x = 0, .y = 0, .w = card_w, .h = card_h },
    };
}

/// the controls, top-most first (the body last: anything else on the card)
const targets = blk: {
    var t: [5]press.Target(Control) = undefined;
    for (.{ .close, .trim, .copy, .save_as, .body }, 0..) |c, i| t[i] = .{ .r = controlRect(c), .t = c };
    break :blk t;
};

/// What is under a logical point of the window.
pub fn hit(x: i32, y: i32) ?Control {
    return press.hitTest(Control, &targets, x - pad, y - pad);
}

/// Where the notice is centred, in the card: between the hovered
/// duration badge and the buttons, which it would touch in the middle.
const notice_area: Rect = .{ .x = 0, .y = 8 + 26 + 6 + 24, .w = card_w, .h = card_h - 8 - 30 - (8 + 26 + 6 + 24) };

/// The same, the notice's link (while `n` shows one) over the card first.
pub fn hitWith(n: *const Notice, x: i32, y: i32, now: i64) ?Control {
    const area: Rect = .{ .x = pad + notice_area.x, .y = pad + notice_area.y, .w = notice_area.w, .h = notice_area.h };
    if (n.hit(area, x, y, now)) return .notice;
    return hit(x, y);
}

const px = scale.px;
const ff = scale.ff;

/// Paint the card onto the window buffer (straight alpha).
pub fn paint(gpa: std.mem.Allocator, buf: []u32, bw: u32, bh: u32, k: f64, v: *const View) void {
    const cw: u32 = @intCast(px(card_w, k));
    const ch: u32 = @intCast(px(card_h, k));
    const card = gpa.alloc(u32, @as(usize, cw) * ch) catch return;
    defer gpa.free(card);
    fui.drawImage(gpa, .{ .px = card, .w = cw, .h = ch }, .{ .px = v.pic, .w = v.pic_w, .h = v.pic_h }, .auto, theme.Opaque.of(v.th).panel);
    var cv = render.Canvas.init(card, cw, ch);
    badge(&cv, k, v);
    if (v.hovered) controls(&cv, k, v);
    if (v.notice) |n| n.draw(&cv, scale.rect(notice_area, k), v.now, .{ .hot = v.hover == .notice }, k, v.th);
    const at = px(pad, k);
    fui.compositeFaded(gpa, .{ .px = buf, .w = bw, .h = bh }, .{ .px = card, .w = cw, .h = ch }, .{ at, at }, 12 * k, v.th.card_shadow, v.alpha, k) catch {};
}

/// The duration (and "GIF") in a dark pill: bottom right, under the
/// trim button while hovered.
fn badge(cv: *render.Canvas, k: f64, v: *const View) void {
    var buf: [40]u8 = undefined;
    var tb: [32]u8 = undefined;
    const t = control_draw.formatTime(&tb, v.duration_ms + 500);
    const s = if (v.gif) std.fmt.bufPrint(&buf, "GIF \u{00B7} {s}", .{t}) catch t else t;
    const w = fui.scrimPillWidth(s, .play, k);
    const h = px(fui.scrim_pill_h, k);
    const x = cv.w - w - px(8, k);
    const y = if (v.hovered) px(8 + 26 + 6, k) else cv.h - h - px(8, k);
    fui.scrimPill(cv, .{ .x = x, .y = y, .w = w, .h = h }, s, .play, .strong, k, v.th);
}

fn controls(cv: *render.Canvas, k: f64, v: *const View) void {
    cv.fillRect(0, 0, cv.w, cv.h, v.th.scrim(.soft));
    for ([_]Control{ .close, .trim }) |c| {
        const r = controlRect(c);
        const icon: @import("../icons.zig").Icon = if (c == .close) .close else .scissors;
        fui.roundButton(cv, (ff(r.x) + 13) * k, (ff(r.y) + 13) * k, 13 * k, icon, .{ .hot = v.hover == c }, k, v.th);
    }
    for ([_]Control{ .copy, .save_as }) |c| {
        const label = if (c == .copy) "Copy" else "Save as\u{2026}";
        fui.pillButton(cv, scale.rect(controlRect(c), k), label, .light, 13, .{ .hot = v.hover == c }, k, v.th);
    }
}

test "the Saved link takes the card's middle while it shows" {
    var n: Notice = .{};
    try std.testing.expectEqual(@as(?Control, .body), hitWith(&n, pad + 120, pad + 75, 0));
    n.showSaved("/v.mp4", 0);
    const text = @import("../../gfx/text.zig");
    text.init(std.testing.allocator);
    defer text.deinit();
    if (!text.available()) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?Control, .notice), hitWith(&n, pad + 120, pad + 75, 0));
    try std.testing.expectEqual(@as(?Control, .copy), hitWith(&n, pad + 20, pad + card_h - 20, 0));
    try std.testing.expectEqual(@as(?Control, .body), hitWith(&n, pad + 120, pad + 75, 10_000));
}

test "card controls hit" {
    try std.testing.expectEqual(@as(?Control, .close), hit(pad + 10, pad + 10));
    try std.testing.expectEqual(@as(?Control, .trim), hit(pad + card_w - 20, pad + 10));
    try std.testing.expectEqual(@as(?Control, .copy), hit(pad + 20, pad + card_h - 20));
    try std.testing.expectEqual(@as(?Control, .body), hit(pad + 120, pad + 70));
    try std.testing.expect(hit(2, 2) == null);
}
