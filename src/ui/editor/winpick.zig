//! Clicking a window while selecting an area, as on macOS: with the
//! windows' frames from the capture (api.capture.windows), the window under
//! the pointer is lit (bright, the rest dimmed, an accent outline); a
//! click without a drag selects exactly it (ui/areasel.zig, editor/
//! area.zig), a drag still draws a free area. With no frames (a desktop that does not say where its windows
//! are) none of this shows.

const std = @import("std");
const editor = @import("../editor.zig");
const shapes_mod = @import("../shapes.zig");
const ui = @import("../editor_ui.zig");
const render = @import("../../gfx/render.zig");
const area = @import("area.zig");

const Editor = editor.Editor;
const Rect = shapes_mod.Rect;
const Point = shapes_mod.Point;

/// Windows can be clicked now: an area or text capture with nothing
/// selected or dragged and no tool's mode.
fn active(ed: *const Editor) bool {
    return ed.capmode.on and ed.capmode.windows.len > 0 and ed.doc.sel == null and
        ed.drag == .none and ed.tools.mode == .none and !ed.help_open;
}

/// The topmost window at image point `ip`.
pub fn windowAt(ed: *const Editor, ip: Point) ?u16 {
    for (ed.capmode.windows, 0..) |r, i| if (r.contains(ip.x, ip.y)) return @intCast(i);
    return null;
}

/// The pointer moved: light the window under it (none over the chrome).
pub fn hover(ed: *Editor) void {
    const m = ed.mouse;
    const now: ?u16 = if (!active(ed) or ui.onChrome(ed, m)) null else windowAt(ed, ed.imgAt(m));
    if (now == ed.capmode.hover) return;
    if (ed.capmode.hover) |i| dirty(ed, i);
    if (now) |i| dirty(ed, i);
    ed.capmode.hover = now;
}

/// A press starts a selection: remember the window under it.
pub fn onPress(ed: *Editor) void {
    hover(ed);
    ed.capmode.press = ed.capmode.hover;
}

/// The area being drawn out: past a click's size the window under the
/// press is let go (dimmed again).
pub fn onDrag(ed: *Editor) void {
    const i = ed.capmode.press orelse return;
    if (ed.area.clickPending()) return;
    ed.capmode.press = null;
    ed.capmode.hover = null;
    dirty(ed, i);
}

/// The press ended (a click takes the window, ui/areasel.zig): nothing
/// is lit any more.
pub fn released(ed: *Editor) void {
    if (ed.capmode.press) |i| dirty(ed, i);
    ed.capmode.press = null;
    ed.capmode.hover = null;
}

/// A press on a window that has not moved enough to be a drag.
pub fn mayBeClick(ed: *const Editor) bool {
    return ed.capmode.press != null and area.drawing(ed) and ed.area.clickPending();
}

/// The lit window in this pane's buffer pixels, if one is.
pub fn lit(ed: *const Editor) ?Rect {
    const i = if (mayBeClick(ed)) ed.capmode.press.? else if (ed.doc.sel == null) ed.capmode.hover orelse return null else return null;
    if (i >= ed.capmode.windows.len) return null;
    return Rect.intersect(ed.pn().view.rectToBuf(ed.capmode.windows[i]), ed.screenRect());
}

/// Window `i` changes how it shows: repaint it, outline included, on
/// every pane.
fn dirty(ed: *Editor, i: u16) void {
    if (i >= ed.capmode.windows.len) return;
    const saved = ed.pane_i;
    defer ed.pane_i = saved;
    for (ed.panes[0..ed.n_panes], 0..) |*p, k| {
        if (!p.alive) continue;
        ed.pane_i = @intCast(k);
        p.content_dirty.add(p.view.rectToBufOuter(ed.capmode.windows[i]).expand(outlinePad(ed) + 2));
        p.gen +%= 1;
    }
    ed.needs_render = true;
}

fn outlinePad(ed: *const Editor) i32 {
    return @max(2, ed.sc(3));
}

/// What drawOutline may paint.
pub fn footprint(ed: *const Editor) ?Rect {
    const r = lit(ed) orelse return null;
    return r.expand(outlinePad(ed) + 1);
}

/// The lit window's accent outline, just outside it.
pub fn drawOutline(ed: *const Editor, canvas: *render.Canvas) void {
    const r = lit(ed) orelse return;
    const t = @max(2, ed.sc(2));
    const o = r.expand(t);
    canvas.rectOutline(o.x, o.y, o.w, o.h, t, ed.theme.accent);
}
