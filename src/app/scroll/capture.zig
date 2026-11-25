//! The scrolling capture: pick a region on the frozen capture, then
//! frames of it as the content scrolls (Shotlet turning the wheel where
//! it can, else the person scrolling), stitched (stitch.zig) while the
//! control (ui/scroll_hud.zig) shows the image growing (session.zig).
//! Stop, the end of the page or the maximum height ends it; a short stop
//! pauses with its reason and Continue (stop.zig); no frame at all says
//! so on the control. The tall image goes to the editor. Whether it can
//! run at all is decided before (available.zig).

const std = @import("std");
const log = std.log.scoped(.scrolling_capture);
const capture = @import("../capture.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("../../platform/api.zig").sys;
const shell_seam = @import("../../platform/api.zig").shell;
const geom = @import("../../geom.zig");
const flow = @import("../modes/flow.zig");
const refused = @import("../refused.zig");
const settings = @import("../modes/settings.zig");
const region_pick = @import("../../ui/region_pick.zig");
const hud_mod = @import("../../ui/scroll_hud.zig");
const theme = @import("../../ui/theme.zig");
const Session = @import("session.zig").Session;
pub const Note = @import("stop.zig").Note;

pub const Tall = struct { image: png.Image, note: Note };

/// Null when cancelled.
pub fn run(c: flow.Ctx, cap: *const capture.Capture, s: settings.Settings) !?Tall {
    // the picker and the control follow the desktop's appearance
    const th = theme.of(theme.readPrefs(c.bus, 800));
    log.info("pick a region", .{});
    const region: geom.Rect = switch (try region_pick.pick(c.gpa, c.win, cap.frozen(), "Start scrolling capture", th)) {
        .region => |r| .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h },
        .cancelled => return null,
    };
    log.info("region {d}x{d} at {d},{d}", .{ region.w, region.h, region.x, region.y });
    const shell = shell_seam.applies() and shell_seam.active(c.bus);
    var hud = try hud_mod.Hud.open(c.win, th);
    defer c.win.closeWindow();
    defer hud.deinit();
    try showHud(c, &hud, cap, region, shell);
    var session = Session.init(c, &hud, .{ .cap = cap, .region = region, .shell = shell, .auto = s.scroll_auto }, s.scroll_max_height) catch |err| {
        try failed(c, &hud, err);
        return null;
    };
    defer session.deinit();
    const image = (session.collect() catch |err| {
        try failed(c, &hud, err);
        return null;
    }) orelse return null;
    return .{ .image = image, .note = session.note };
}

/// No frame of the region came (the source would not start, or gave
/// nothing): the control says so until it is closed, instead of
/// vanishing; when the integration refused this Shotlet, that (said
/// once a run on a card and stderr: refused.zig).
fn failed(c: flow.Ctx, hud: *hud_mod.Hud, err: anyerror) !void {
    if (refused.tell(c.gpa, c.env, c.bus)) {
        log.warn("stopped: the desktop integration answers only the installed Shotlet", .{});
        hud.show(.failed, refused.short_title, refused.short_hint, 0);
    } else {
        log.warn("scrolling capture failed ({t}): no frame of the region", .{err});
        hud.show(.failed, "Couldn\u{2019}t capture the region", "Close and try again", 0);
    }
    while (true) {
        try hud.draw();
        if (try hud.poll(100)) |_| return;
    }
}

/// Map the control, beside the region on GNOME. The picker's surfaces are
/// gone by now; elsewhere the compositor gets half a second to drop them
/// (the first frame is taken once the region is still anyway).
fn showHud(c: flow.Ctx, hud: *hud_mod.Hud, cap: *const capture.Capture, region: geom.Rect, shell: bool) !void {
    const start = sys.monoMs();
    const least: i64 = if (shell) 0 else 500;
    var placed = !shell;
    while (sys.monoMs() - start < 1500) {
        try hud.draw();
        _ = try hud.poll(10);
        // (mutter places a window as it maps: moved after that)
        if (!placed and hud.onScreen()) if (besideRegion(cap, region)) |p| {
            placed = shell_seam.place(c.gpa, c.bus, hud_mod.title, p[0], p[1]);
        };
        if (placed and sys.monoMs() - start >= least) break;
    }
}

/// Where the control goes (logical): right of the region, else left,
/// else the monitor's top-right corner.
fn besideRegion(cap: *const capture.Capture, region: geom.Rect) ?[2]i32 {
    const l = (geom.imageToLogical(cap.monitors, region) orelse return null).rect;
    const m = cap.monitors[geom.monitorAt(cap.monitors, .{ l.x + @divTrunc(l.w, 2), l.y + @divTrunc(l.h, 2) })].logical orelse return null;
    const gap = 16;
    const w = hud_mod.width;
    const h = hud_mod.height;
    const right = m.right();
    const y = std.math.clamp(l.y, m.y + gap, m.bottom() - h - gap);
    if (l.x + l.w + gap + w <= right) return .{ l.x + l.w + gap, y };
    if (l.x - gap - w >= m.x) return .{ l.x - gap - w, y };
    return .{ right - w - gap, m.y + gap };
}
