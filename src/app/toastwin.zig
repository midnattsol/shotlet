//! `shotlet toast [--info] TITLE [TEXT]`: a small card at the bottom of
//! the screen for a couple of seconds, after the editor has closed
//! ("Copied" and the first line of the text `shotlet text` read). With
//! --info it tells why something cannot be done (a scrolling capture
//! where none can run): an "i" instead of the check, as wide as its words
//! need and up for longer. Placed like the
//! thumbnail: a layer surface where there is layer shell, else a window
//! titled shotlet:quick that the GNOME extension puts bottom-left, above,
//! without the keyboard focus. A click closes it.

const std = @import("std");
const env_mod = @import("env.zig");
const sys = @import("../platform/api.zig").sys;
const text = @import("../gfx/text.zig");
const render = @import("../gfx/render.zig");
const window = @import("../platform/api.zig").window;
const fui = @import("../ui/floatui.zig");
const floatwin = @import("../ui/floatwin.zig");
const badge = @import("../ui/badge.zig");
const press = @import("../ui/press.zig");
const scale = @import("../ui/scale.zig");
const theme = @import("../ui/theme.zig");
const Env = env_mod.Env;
const Rect = @import("../ui/shapes.zig").Rect;

const card_w = 340;
const card_max_w = 560;
const card_h = 64;
const pad = 20;
const radius = 14;
/// the text's left edge (after the badge) and the card's right margin
const text_x = 16 + 24 + 12;
const text_right = 16;
const title_size = 14.0;
const body_size = 12.0;

pub const Kind = enum {
    /// done: a check
    done,
    /// why something cannot be done: an "i"
    info,

    fn badgeKind(self: Kind) badge.Kind {
        return switch (self) {
            .done => .done,
            .info => .info,
        };
    }

    fn showMs(self: Kind) i64 {
        return switch (self) {
            .done => 2600,
            .info => 6000,
        };
    }
};

pub const Toast = struct {
    kind: Kind = .done,
    title: []const u8,
    body: []const u8 = "",
};

/// The card's logical width: fixed for done, else as wide as the words.
fn cardWidth(t: Toast) u32 {
    if (t.kind == .done) return card_w;
    const words = @max(text.widthStyled(title_size, .semibold, t.title), text.width(body_size, t.body));
    return @intCast(std.math.clamp(words + text_x + text_right, card_w, card_max_w));
}

pub fn run(gpa: std.mem.Allocator, env: Env, t: Toast) !void {
    text.init(gpa);
    defer text.deinit();
    const th = theme.load(gpa, env, 300);
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    const cw = cardWidth(t);
    _ = try floatwin.open(&win, .{
        .size = .{ cw + 2 * pad, card_h + 2 * pad },
        .anchor = .{ .bottom = true },
        .margin = .{ 0, 0, 24, 0 },
    });
    std.log.info("toast: {s}: {s}", .{ t.title, t.body });
    const end = sys.monoMs() + t.kind.showMs();
    var drawn = false;
    // a click on the card (pressed and released on it) closes it
    var click: press.Press(void) = .{};
    while (sys.monoMs() < end) {
        if (!drawn and floatwin.canDraw(&win)) {
            try draw(gpa, &win, th, t, cw);
            drawn = true;
        }
        const ev = (try win.nextEventTimeout(100)) orelse continue;
        switch (ev) {
            .close => break,
            .pointer_button => |b| {
                const k = scale.of(win.scale120);
                const on: ?void = if (cardRect(cw).contains(scale.toLogical(b.x, k), scale.toLogical(b.y, k))) {} else null;
                if (b.pressed) click.down(on, b.x, b.y) else if (click.up(on) != null) break;
            },
            .resize => drawn = false,
            else => {},
        }
    }
    win.closeWindow();
}

/// The card in the window, logical px.
fn cardRect(card_lw: u32) Rect {
    return .{ .x = pad, .y = pad, .w = @intCast(card_lw), .h = card_h };
}

/// The card of logical width `card_lw`, at the window's scale.
fn draw(gpa: std.mem.Allocator, win: *window.Window, th: theme.Theme, t: Toast, card_lw: u32) !void {
    const k = scale.of(win.scale120);
    const buf = try win.backBuffer();
    @memset(buf, 0);
    const r = scale.rect(cardRect(card_lw), k);
    const cw: u32 = @intCast(r.w);
    const ch: u32 = @intCast(r.h);
    const card = try gpa.alloc(u32, @as(usize, cw) * ch);
    defer gpa.free(card);
    const o = theme.Opaque.of(th);
    @memset(card, o.panel);
    var c = render.Canvas.init(card, cw, ch);
    badge.statusBadge(&c, t.kind.badgeKind(), 28 * k, scale.ff(ch) / 2, k, th);
    const tx = scale.px(text_x, k);
    const fs = title_size * k;
    const ss = body_size * k;
    const room = @as(i32, @intCast(cw)) - tx - scale.px(text_right, k);
    var tbuf: [256]u8 = undefined;
    var bbuf: [256]u8 = undefined;
    const top: i32 = @divTrunc(@as(i32, @intCast(ch)) - text.heightStyled(fs, .semibold) - (if (t.body.len > 0) text.height(ss) else 0), 2);
    text.drawStyled(&c, tx, top, fs, o.fg, .semibold, text.ellipsize(&tbuf, fs, .semibold, t.title, room, .end));
    if (t.body.len > 0) text.draw(&c, tx, top + text.heightStyled(fs, .semibold), ss, o.muted, text.ellipsize(&bbuf, ss, .regular, t.body, room, .end));
    fui.place(gpa, .{ .px = buf, .w = win.width, .h = win.height }, .{ .px = card, .w = cw, .h = ch }, .{ r.x, r.y }, radius * k, th.card_shadow, k);
    try floatwin.presentStraight(win, buf);
}
