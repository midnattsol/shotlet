//! The tools' toast: a small Glass pill at the bottom of the screen
//! ("#FF453A copied", "Copied: first line of the text", how to install
//! Tesseract), gone after a few seconds. The editor's copy notice ("Copy
//! failed") shows in it too.

const render = @import("../../gfx/render.zig");
const text_mod = @import("../../gfx/text.zig");
const theme = @import("../theme.zig");
const badge = @import("../badge.zig");
const ff = @import("../scale.zig").ff;
const ui = @import("../editor_ui.zig");
const editor_mod = @import("../editor.zig");

const Editor = editor_mod.Editor;
const Canvas = render.Canvas;
const Rect = @import("../shapes.zig").Rect;

pub const Kind = enum { info, done, busy, problem };

pub const Toast = struct {
    buf: [240]u8 = undefined,
    len: usize = 0,
    kind: Kind = .info,
    /// a colour swatch before the text (the colour picker)
    swatch: ?u32 = null,
    /// hidden at (monotonic ms); 0 while busy (until replaced)
    until_ms: i64 = 0,

    pub fn visible(self: *const Toast) bool {
        return self.len > 0;
    }

    pub fn text(self: *const Toast) []const u8 {
        return self.buf[0..self.len];
    }

    /// Show `msg` for `ms` (0: until the next show or hide).
    pub fn show(self: *Toast, kind: Kind, msg: []const u8, ms: i64) void {
        var eb: [240]u8 = undefined;
        const fit = text_mod.ellipsize(&eb, 15, .regular, msg, 900, .end);
        self.len = @min(fit.len, self.buf.len);
        @memcpy(self.buf[0..self.len], fit[0..self.len]);
        self.kind = kind;
        self.swatch = null;
        self.until_ms = if (ms > 0) now() + ms else 0;
    }

    pub fn hide(self: *Toast) void {
        self.len = 0;
    }

    /// Hide when due; how long until then (ms), for the event wait.
    pub fn tick(self: *Toast, t: i64) ?i64 {
        if (self.len == 0 or self.until_ms == 0) return null;
        if (t >= self.until_ms) {
            self.len = 0;
            return 0;
        }
        return self.until_ms - t;
    }
};

fn now() i64 {
    return @import("../../platform/api.zig").sys.monoMs();
}

const icon_box = 22;

/// What the toast says now: the editor's copy notice (export.zig sets
/// it) over the tools' message.
const Shown = struct { badge: badge.Kind, text: []const u8 };

fn shown(ed: *const Editor) ?Shown {
    switch (ed.copy_notice) {
        .failed => return .{ .badge = .problem, .text = "Copy failed" },
        .none => {},
    }
    const t = &ed.tools.toast;
    if (!t.visible()) return null;
    if (t.swatch) |c| return .{ .badge = .{ .swatch = c }, .text = t.text() };
    return .{ .badge = switch (t.kind) {
        .info => .info,
        .done => .done,
        .busy => .busy,
        .problem => .problem,
    }, .text = t.text() };
}

pub fn rect(ed: *const Editor) ?Rect {
    const msg = shown(ed) orelse return null;
    if (!ed.isTbPane()) return null;
    const fs = theme.font_label * ed.uf();
    const w: i32 = @intCast(ed.pn().width);
    const h: i32 = @intCast(ed.pn().height);
    const tw = @min(text_mod.width(fs, msg.text), w - ed.sc(120));
    const pw = ed.sc(14) + ed.sc(icon_box) + ed.sc(10) + tw + ed.sc(18);
    const ph = ed.sc(44);
    const low: Rect = .{ .x = @divTrunc(w - pw, 2), .y = h - ph - ed.sc(28), .w = pw, .h = ph };
    // at the top when the toolbar (or what it opened) is down there
    for ([_]Rect{ ed.toolbar_rect, ed.panel_rect, ed.pop_rect }) |c| {
        if (!c.isEmpty() and Rect.intersect(c.expand(ed.sc(12)), low) != null) return .{ .x = low.x, .y = ed.sc(28), .w = pw, .h = ph };
    }
    return low;
}

pub fn footprint(ed: *const Editor) ?Rect {
    const r = rect(ed) orelse return null;
    return ui.shadowFootprint(ed, r, ed.theme.bar_shadow);
}

pub fn draw(ed: *Editor, canvas: *Canvas) void {
    const r = rect(ed) orelse return;
    const msg = shown(ed).?;
    const f = ed.uf();
    const th = ed.theme;
    ui.drawMaterial(ed, canvas, .notice, r, ff(r.h) / 2.0, th.bar_shadow);
    const cx = ff(r.x + ed.sc(14) + @divTrunc(ed.sc(icon_box), 2));
    const cy = ff(r.y) + ff(r.h) / 2.0;
    badge.statusBadge(canvas, msg.badge, cx, cy, f, th);
    const fs = theme.font_label * f;
    const tx = r.x + ed.sc(14) + ed.sc(icon_box) + ed.sc(10);
    text_mod.draw(canvas, tx, r.y + @divTrunc(r.h - text_mod.height(fs), 2), fs, th.fg, msg.text);
}
