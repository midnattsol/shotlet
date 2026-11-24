//! The editor's mode strip asked for another capture mode
//! (ui/editor/capmode.zig): the editor eases back to the plain capture
//! and closes, then
//!
//! - Screen: the monitor it chose is delivered like `shotlet fullscreen`
//!   (after_fullscreen: copy, thumbnail or save);
//! - Record: the recording picker opens on this same frozen frame;
//! - Scroll: the scrolling capture's region picker opens on this same
//!   frozen frame (and monitor layout), as `shotlet scroll` would after
//!   capturing: no second capture; the tall image opens in a new editor
//!   (app/shot.zig editAndFinish);
//! - Window, Timer: that capture starts anew in a fresh shotlet.

const std = @import("std");
const log = std.log.scoped(.capture);
const capture = @import("../capture.zig");
const relaunch = @import("../relaunch.zig");
const mode_flow = @import("../modes/flow.zig");
const editor_mod = @import("../../ui/editor.zig");
const record_cli = @import("../../record/cli.zig");
const scroll_available = @import("../scroll/available.zig");

const Editor = editor_mod.Editor;

/// Ease the editor out and close its window: nothing of it stays on
/// screen for what comes next.
pub fn leave(ed: *Editor, win: anytype) void {
    ed.fadeOut() catch |err| log.debug("editor fade: {t}", .{err});
    win.closeWindow();
}

pub fn screen(c: mode_flow.Ctx, ed: *Editor, cap: *capture.Capture) !void {
    const r = ed.capmode.screen_rect;
    leave(ed, c.win);
    try mode_flow.deliverScreen(c, cap, .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
}

/// The recording picker over `cap`; `overlays`: the capture came from
/// the GNOME extension (clicks and keys can be shown).
pub fn record(c: mode_flow.Ctx, ed: *Editor, cap: *const capture.Capture, overlays: bool) !void {
    leave(ed, c.win);
    log.info("capture mode: record, the picker on this capture", .{});
    try record_cli.pickOnCapture(c.gpa, c.env, cap, overlays);
}

/// The scrolling capture on `cap` (the editor has left): its region
/// picker at once, the scrolling live. How the editor opens on the tall
/// image (it replaces `cap`); null when there is nothing to edit (it
/// cannot run here: the person was told why; cancelled; failed).
pub fn scroll(c: mode_flow.Ctx, cap: *capture.Capture) !?mode_flow.Edit {
    log.info("capture mode: scroll, the picker on this capture", .{});
    if (!scroll_available.ensure(c.gpa, c.env)) return null;
    return switch (try mode_flow.afterCapture(c, cap, .{ .mode = .scroll })) {
        .done => null,
        .edit => |e| e,
    };
}

pub fn restart(c: mode_flow.Ctx, ed: *Editor) void {
    leave(ed, c.win);
    relaunch.capture(c.env, ed.next_capture);
}
