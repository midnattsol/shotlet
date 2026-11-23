//! The editor's area selection: ui/areasel.zig (the same as the recording
//! and scrolling capture pickers') on the document's selection, in image
//! pixels. `ed.area` holds the gesture; the document holds the area, so
//! each step reads it from there and puts it back (repainting both).
//! The whole image is selectable (an area may span monitors); a click
//! takes the window under it (area and text captures, when the desktop
//! says where windows are, winpick.zig), else its monitor.

const std = @import("std");
const log = std.log.scoped(.editor);
const editor = @import("../editor.zig");
const window = @import("../../platform/api.zig").window;
const areasel = @import("../areasel.zig");
const shapes_mod = @import("../shapes.zig");
const ui = @import("../editor_ui.zig");
const tools = @import("../tools/mod.zig");
const caches = @import("caches.zig");
const winpick = @import("winpick.zig");

const Editor = editor.Editor;
const Point = shapes_mod.Point;

/// Where areas can be: the image, its monitors (none while cropping:
/// a click takes the whole picture), the windows while a capture mode is
/// offered.
fn areaOf(ed: *Editor) areasel.Area {
    const n = if (ed.tools.mode == .crop) 0 else @min(ed.monitors.len, ed.area_mons.len);
    for (ed.monitors[0..n], 0..) |m, i| ed.area_mons[i] = m.pixelRect();
    const windows = if (ed.capmode.on and ed.tools.mode == .none) ed.capmode.windows else &.{};
    const min: i32 = @intFromFloat(@ceil(ed.pn().view.lenToImg(4.0)));
    return .{ .bounds = ed.doc.imageRect(), .monitors = ed.area_mons[0..n], .windows = windows, .min = @max(1, min) };
}

/// `ed.area` up to date with the document and the held modifiers.
fn get(ed: *Editor) *areasel.Selection {
    const a = &ed.area;
    a.sel = ed.doc.sel;
    a.area = areaOf(ed);
    a.mods = .{ .square = ed.mod_shift, .ctrl = ed.mod_ctrl, .alt = ed.mod_alt, .space = ed.space.held };
    return a;
}

/// The area changed: into the document, repainted where it was and is.
fn put(ed: *Editor) void {
    caches.selDirty(ed);
    ed.doc.sel = ed.area.sel;
    caches.selDirty(ed);
}

/// The area is being dragged out (not moved or resized).
pub fn drawing(ed: *const Editor) bool {
    return ed.drag == .area and ed.area.drag == .drawing;
}

/// What a press at buffer point `m` would take hold of.
pub fn grabAt(ed: *const Editor, m: Point) areasel.Grab {
    return areasel.grabAt(ed.selBuf(), m, ed.handleRadius());
}

/// A press at image point `ip` (buffer point `m`): move, resize or draw
/// anew.
pub fn press(ed: *Editor, m: Point, ip: Point) void {
    const g = grabAt(ed, m);
    const a = get(ed);
    a.press(ip, g);
    ed.drag = .area;
    switch (a.drag) {
        .resizing => ui.loupeEdgeDragged(ed),
        .drawing => {
            winpick.onPress(ed);
            put(ed);
        },
        else => {},
    }
}

/// The pointer at image point `ip` during the drag.
pub fn motion(ed: *Editor, ip: Point) void {
    get(ed).motion(ip);
    put(ed);
    if (ed.area.drag == .drawing) winpick.onDrag(ed);
    tools.afterSelDrag(ed);
}

/// The drag ends: a drawn area or a click is selected (tools.onSelected).
pub fn release(ed: *Editor) void {
    const a = get(ed);
    const was = a.drag;
    const click = a.clickPending();
    a.release();
    ed.drag = .none;
    put(ed);
    winpick.released(ed);
    if (was != .drawing) return;
    if (click) logClick(ed, was.drawing.anchor);
    tools.onSelected(ed);
}

fn logClick(ed: *const Editor, at: Point) void {
    const r = ed.doc.sel orelse return log.info("clicked off the picture: nothing selected", .{});
    const what = if (ed.area.area.windows.len > 0 and winpick.windowAt(ed, at) != null) "window" else "monitor";
    log.info("{s} clicked: {d}x{d} at {d},{d}", .{ what, r.w, r.h, r.x, r.y });
}

/// Abandon the drag: a moved or resized area goes back, a new one goes.
pub fn cancel(ed: *Editor) void {
    get(ed).cancel();
    ed.drag = .none;
    put(ed);
    winpick.released(ed);
}

/// An arrow key with no shape selected: the area nudged (see
/// areasel.Selection.arrow); the magnifier looks at the edge that moved.
pub fn arrow(ed: *Editor, k: window.Key) void {
    const s = (ed.doc.sel orelse return).normalized();
    const a = get(ed);
    const edge = a.nudgeEdge(k);
    _ = a.arrow(k);
    put(ed);
    ui.loupeNudged(ed, edge orelse shapes_mod.nearestCorner(s, ed.imgAt(ed.mouse)));
}

/// Enter with nothing selected: what a click at the pointer takes.
pub fn confirm(ed: *Editor) void {
    if (ed.doc.sel != null) return;
    const a = get(ed);
    a.sel = a.confirm(ed.imgAt(ed.mouse));
    put(ed);
}
