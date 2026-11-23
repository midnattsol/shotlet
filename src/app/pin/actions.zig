//! What the pin's menu items (and their shortcuts) do: copy the picture,
//! save it (the editor's Save As), annotate it, set its opacity, lock it
//! in place, show the window menu (Keep on Top), close it or every pin.

const std = @import("std");
const log = std.log.scoped(.pin);
const config = @import("../config.zig");
const deliver = @import("../deliver.zig");
const desktop = @import("../../platform/api.zig").desktop;
const sys = @import("../../platform/api.zig").sys;
const state = @import("state.zig");
const menu = @import("menu.zig");
const view = @import("view.zig");
const keys = @import("keys.zig");
const ipc = @import("ipc.zig");
const annotate = @import("annotate.zig");

const Pin = state.Pin;

/// A menu row clicked (or Enter on it): opacity segments set it there,
/// the row itself steps it; the rest close the menu and act.
pub fn activate(p: *Pin, h: menu.Hit) void {
    const now = sys.monoMs();
    const it = p.menu.lay.items[h.index];
    if (it == .opacity) {
        if (h.seg) |s| {
            p.setOpacity(view.Opacity.all[s]);
            p.closeMenu(now);
        } else p.setOpacity(nextOpacity(p.opacity));
        return;
    }
    p.closeMenu(now);
    run(p, it);
}

fn nextOpacity(o: view.Opacity) view.Opacity {
    return if (o == .quarter) .full else keys.stepOpacity(o, 1);
}

pub fn run(p: *Pin, it: menu.Item) void {
    runInner(p, it) catch |err| log.warn("{t} failed: {t}", .{ it, err });
}

fn runInner(p: *Pin, it: menu.Item) !void {
    switch (it) {
        .copy => try copy(p),
        .save => try save(p),
        .annotate => try annotate.start(p),
        .opacity => p.setOpacity(nextOpacity(p.opacity)),
        .lock => if (p.offer().lock) setLocked(p, !p.locked),
        .keep_on_top => {
            const k = p.scale();
            try p.win.showWindowMenu(0, @intFromFloat(p.pointer[0] / k), @intFromFloat(p.pointer[1] / k));
        },
        .close => p.quit = true,
        .close_all => {
            const n = ipc.closeOthers(p.gpa, p.env, &p.ipc);
            log.info("closing every pin ({d} more)", .{n});
            p.quit = true;
        },
    }
}

/// The picture at 1:1 on the clipboard (served once the pin closes,
/// until something else is copied).
fn copy(p: *Pin) !void {
    const px = try p.gpa.dupe(u32, p.img.pixels);
    p.win.setClipboardImage(px, p.img.width, p.img.height) catch |err| {
        p.gpa.free(px);
        return err;
    };
    log.info("copied", .{});
}

/// Where the person says, as the editor's Save As does (copy_on_save
/// and the notification included).
fn save(p: *Pin) !void {
    const data = try deliver.encodePng(p.gpa, .{ .pixels = p.img.pixels, .width = p.img.width, .height = p.img.height }, .{}, true);
    defer p.gpa.free(data);
    var bus = try desktop.connect(p.gpa, p.env);
    defer bus.deinit();
    const cfg = config.load(p.gpa, p.env.home);
    const c: deliver.Ctx = .{ .gpa = p.gpa, .env = p.env, .cfg = &cfg, .bus = &bus, .win = p.win, .over = p.win, .who = "pin" };
    const path = (try deliver.savePng(c, data, .ask)) orelse return;
    p.gpa.free(path);
}

/// Locked, clicks go through the pin to what lies below, but for its
/// badge, which unlocks it (and takes a right-click for the menu).
pub fn setLocked(p: *Pin, on: bool) void {
    if (p.locked == on) return;
    p.locked = on;
    p.drag_from = null;
    p.dirty = true;
    log.info("{s}", .{if (on) "locked in place" else "unlocked"});
}
