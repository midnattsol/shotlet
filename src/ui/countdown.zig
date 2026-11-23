//! The self-timer's countdown where the GNOME extension does not draw it
//! (wlroots, KDE, GNOME without the extension): a small glass card in the
//! middle of the screen. It never takes the keyboard on layer-shell
//! compositors (a menu left open for the timer stays open); a click on it
//! cancels. Before the capture it turns fully transparent and waits for
//! the compositor to show that, so it is never in the picture.

const std = @import("std");
const sys = @import("../platform/api.zig").sys;
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const fui = @import("floatui.zig");
const floatwin = @import("floatwin.zig");
const focus = @import("focus.zig");
const press = @import("press.zig");
const scale = @import("scale.zig");
const theme = @import("theme.zig");
const window = @import("../platform/api.zig").window;

/// the card's size and corner radius, logical px
const size = 132;
const radius = 32;
/// how much of the card shows: the screen stays readable through it
const opacity = 0.86;

fn draw(win: *window.Window, th: theme.Theme, left: u32) !void {
    const bw = win.width;
    const bh = win.height;
    const k = scale.of(win.scale120);
    const o = theme.Opaque.of(th);
    const card = try win.alloc.alloc(u32, @as(usize, bw) * bh);
    defer win.alloc.free(card);
    @memset(card, o.panel);
    var cv = render.Canvas.init(card, bw, bh);
    var buf: [4]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{left}) catch "";
    fui.textCentered(&cv, .ofSize(bw, bh), 60 * k, o.fg, text.Style.semibold.num(), s);
    const px = try win.backBuffer();
    @memset(px, 0);
    fui.place(.{ .px = px, .w = bw, .h = bh }, .{ .px = card, .w = bw, .h = bh }, .{ 0, 0 }, radius * k, null, k);
    fui.fadeAlpha(px, opacity);
    try floatwin.presentStraight(win, px);
}

/// Nothing drawn, and shown: the capture may start.
fn vanish(win: *window.Window) !void {
    const px = try win.backBuffer();
    @memset(px, 0);
    try win.present();
    const deadline = sys.monoMs() + 300;
    while (win.frame_pending and sys.monoMs() < deadline) _ = try win.nextEventTimeout(20);
    sys.sleepMs(50);
}

/// Count `seconds` down on a card in `th`. True when it ran out (the
/// card is invisible now and is closed by the caller), false when
/// cancelled: Escape, or a click on the card.
pub fn run(win: *window.Window, seconds: u8, th: theme.Theme) !bool {
    _ = try floatwin.open(win, .{ .title = "shotlet:timer", .namespace = "shotlet-timer", .size = .{ size, size } });
    const end = sys.monoMs() + @as(i64, seconds) * 1000;
    var shown: u32 = 0;
    // the whole window is the card: a press and release on it cancel
    var click: press.Press(void) = .{};
    while (true) {
        const now = sys.monoMs();
        if (now >= end) break;
        const left: u32 = @intCast(@divTrunc(end - now + 999, 1000));
        if (left != shown and floatwin.canDraw(win)) {
            try draw(win, th, left);
            shown = left;
        }
        const ev = (try win.nextEventTimeout(@intCast(@min(100, end - now)))) orelse continue;
        switch (ev) {
            .close => return false,
            .pointer_button => |b| if (b.pressed) click.down({}, b.x, b.y) else if (click.up(if (win.pointer_in) {} else null) != null) return false,
            .key => |k| if (focus.action(k, .none) == .close) return false,
            .resize => shown = 0,
            else => {},
        }
    }
    try vanish(win);
    return true;
}
