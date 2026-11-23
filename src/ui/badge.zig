//! The round status badge at the start of a toast or notice, drawn one
//! way everywhere (the editor's toasts and notices, the floating toast
//! window): an accent disc with a check or an "i", a red one with a
//! cross, a ring while busy, or a colour swatch.
//!
//! Stable API:
//!   Kind                                    what the badge says
//!   statusBadge(canvas, kind, cx, cy, f, th)   centred on cx, cy at scale f
//!   radius                                  the disc's radius, logical px

const std = @import("std");
const render = @import("../gfx/render.zig");
const text = @import("../gfx/text.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");

const Canvas = render.Canvas;
const Theme = theme.Theme;

/// the disc's radius, logical px
pub const radius: f64 = 11;

pub const Kind = union(enum) {
    /// done (copied, saved): a check on the accent
    done,
    /// for your information: an "i" on the accent
    info,
    /// working on it: an accent ring
    busy,
    /// it failed: a cross on red
    problem,
    /// a colour (picked, copied): the colour itself
    swatch: u32,
};

/// The badge for `kind`, centred on (cx, cy), at scale `f`.
pub fn statusBadge(cv: *Canvas, kind: Kind, cx: f64, cy: f64, f: f64, th: Theme) void {
    const is = 14 * f;
    switch (kind) {
        .swatch => |c| {
            cv.fillCircleAA(cx, cy, (radius - 1) * f, c | 0xFF000000);
            cv.ringAA(cx, cy, (radius - 1) * f, 1.0 * f, th.swatch_ring);
        },
        .busy => cv.ringAA(cx, cy, (radius - 2) * f, 2.0 * f, theme.withAlpha(th.accent, 0x80)),
        .done => {
            cv.fillCircleAA(cx, cy, radius * f, th.accent);
            icons.drawAt(cv, .check, cx, cy, is, .{ .stroke = 3 }, th.on_accent);
        },
        .problem => {
            cv.fillCircleAA(cx, cy, radius * f, th.destructive);
            icons.drawAt(cv, .close, cx, cy, is, .{ .stroke = 3 }, 0xFFFFFFFF);
        },
        .info => {
            cv.fillCircleAA(cx, cy, radius * f, th.accent);
            const fs = 13 * f;
            const tw: f64 = @floatFromInt(text.widthStyled(fs, .semibold, "i"));
            const fh: f64 = @floatFromInt(text.heightStyled(fs, .semibold));
            text.drawStyled(cv, @intFromFloat(@round(cx - tw / 2)), @intFromFloat(@round(cy - fh / 2)), fs, th.on_accent, .semibold, "i");
        },
    }
}

test "every badge draws inside its disc" {
    const th = Theme.get(false, null);
    var px: [40 * 40]u32 = undefined;
    var cv = Canvas.init(&px, 40, 40);
    for ([_]Kind{ .done, .info, .busy, .problem, .{ .swatch = 0xFF00FF00 } }) |k| {
        @memset(&px, 0xFF000000);
        statusBadge(&cv, k, 20, 20, 1, th);
        var lit: usize = 0;
        for (px, 0..) |p, i| if (p != 0xFF000000) {
            lit += 1;
            const dx = @as(f64, @floatFromInt(i % 40)) + 0.5 - 20;
            const dy = @as(f64, @floatFromInt(i / 40)) + 0.5 - 20;
            try std.testing.expect(@sqrt(dx * dx + dy * dy) <= radius + 1.5);
        };
        try std.testing.expect(lit > 20);
    }
}
