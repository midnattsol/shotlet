//! What the quick access thumbnails do: copy, save, save as, annotate,
//! pin and close a card, enable the GNOME integration from the hint, and
//! drag a card's capture out into other apps.

const std = @import("std");
const log = std.log.scoped(.quick_access);
const uri_mod = @import("../../uri.zig");
const env_mod = @import("../env.zig");
const history = @import("../history.zig");
const deliver = @import("../deliver.zig");
const filename = @import("../filename.zig");
const shell = @import("../../platform/api.zig").shell;
const sys = @import("../../platform/api.zig").sys;
const fui = @import("../../ui/floatui.zig");
const notice_mod = @import("../../ui/notice.zig");
const layout = @import("layout.zig");
const stack = @import("stack.zig");

const Quick = stack.Quick;
const Action = layout.Action;
const Control = layout.Control;
const Hit = layout.Hit;

pub fn act(self: *Quick, i: usize, a: Action) void {
    if (i >= self.cards.items.len) return;
    actInner(self, i, a) catch |err| {
        log.warn("{t} failed: {t}", .{ a, err });
        notice(self, i, "Failed");
    };
}

/// A short word over card i ("Copied"); the card stays a while for it.
pub fn notice(self: *Quick, i: usize, s: []const u8) void {
    const c = &self.cards.items[i];
    c.notice.show(s, sys.monoMs(), notice_mod.word_ms);
    c.deadline_ms = @max(c.deadline_ms, c.notice.until + 1500);
    self.dirty = true;
}

/// Card i was saved: "✓ Saved", then the card goes (as CleanShot X's
/// overlay does); Alt held keeps it, as CleanShot's Option does.
fn saved(self: *Quick, i: usize) void {
    const c = &self.cards.items[i];
    const now = sys.monoMs();
    self.dirty = true;
    if (self.win.alt) {
        log.info("saved, kept open (Alt)", .{});
        c.notice.showSaved(now, notice_mod.word_ms);
        c.deadline_ms = @max(c.deadline_ms, c.notice.until + 1500);
        return;
    }
    c.notice.showSaved(now, notice_mod.end_ms);
    c.ending = true;
    c.deadline_ms = now + notice_mod.end_ms;
}

/// What Show in Files shows: the saved file, else the capture as kept
/// in the history (a file on disk too, as macOS's thumbnail always has
/// one to show).
fn shownFile(c: *const stack.Card, buf: *env_mod.PathBuf) ![]const u8 {
    if (c.meta.saved.len > 0 and (sys.fileSize(c.meta.saved) catch null) != null) return c.meta.saved;
    return history.entryPath(buf, c.kept.root(), c.kept.id.slice(), history.File.image.name());
}

/// Card i's capture, for deliver.zig.
fn entry(self: *Quick, i: usize) deliver.Entry {
    const c = &self.cards.items[i];
    return .{ .root = c.kept.root(), .id = c.kept.id.slice(), .meta = &c.meta };
}

/// Saving from a card is saving from the editor; the card itself says
/// "Saved" (no notification).
fn ctx(self: *Quick) deliver.Ctx {
    return .{ .gpa = self.gpa, .env = self.env, .cfg = &self.cfg, .bus = self.bus_(), .win = &self.win, .thumbnail_shows = true, .who = "quick access" };
}

fn actInner(self: *Quick, i: usize, a: Action) !void {
    const c = &self.cards.items[i];
    c.menu = false;
    self.dirty = true;
    switch (a) {
        .copy => {
            try entry(self, i).copy(ctx(self));
            notice(self, i, "Copied");
        },
        .save, .save_as => if (try entry(self, i).save(ctx(self), if (a == .save_as) .ask else .folder)) saved(self, i),
        .annotate => {
            if (!c.editable) return;
            entry(self, i).edit(self.env);
            self.remove(i);
        },
        .pin => {
            try entry(self, i).pin(self.env);
            self.remove(i);
        },
        // the file manager takes over: the card goes, as after Annotate
        // (it stays, and a problem card says why, when none answered)
        .show_in_files => {
            var buf: env_mod.PathBuf = undefined;
            const path = try shownFile(c, &buf);
            if (deliver.showInFiles(self.gpa, self.env, self.bus_(), path, "quick access")) c.life.leave(sys.monoMs());
        },
        .close => {
            log.info("closed {s}", .{c.kept.id.slice()});
            c.life.leave(sys.monoMs());
        },
    }
}

/// What control `c` of a card does.
fn controlAction(c: Control) ?Action {
    const pills = layout.pill_actions;
    return switch (c) {
        .close => .close,
        .annotate => .annotate,
        .pin => .pin,
        .primary => pills[0],
        .secondary => pills[1],
        else => null,
    };
}

pub fn activate(self: *Quick, h: Hit) void {
    switch (h.control) {
        .menu => act(self, h.card, layout.menu_items[h.item].action),
        .hint => enableGnome(self),
        else => if (h.card < self.cards.items.len) if (controlAction(h.control)) |a| act(self, h.card, a),
    }
}

/// The hint's link: install the GNOME integration and say how it went.
fn enableGnome(self: *Quick) void {
    const res = shell.install(self.gpa, self.env, self.bus_());
    self.hint_text = switch (res) {
        .active => "GNOME integration is on.",
        .installed => "Installed. Log out and in once",
        else => "Could not install; see the log",
    };
    self.hint_link = switch (res) {
        .active => "Next thumbnails stay above",
        .installed => "to finish (GNOME needs it).",
        else => "shotlet gnome-integration",
    };
    self.dirty = true;
}

// --- drag out ---

pub fn startDrag(self: *Quick, i: usize) !void {
    const c = &self.cards.items[i];
    const data = try history.readFile(self.gpa, c.kept.root(), c.kept.id.slice(), .image);
    errdefer self.gpa.free(data);
    var file_buf: [1200]u8 = undefined;
    const file = try dragFile(self, c, data, &file_buf);
    const uri = try uri_mod.fileUriList(self.gpa, file);
    errdefer self.gpa.free(uri);
    // the icon: the card's picture, smaller, rounded and a bit see-through
    const k: i32 = @max(1, @as(i32, @intCast((self.win.scale120 + 119) / 120)));
    const iw: u32 = @intCast(160 * k);
    const ih: u32 = @intCast(100 * k);
    const icon_px = try fui.dragIcon(self.gpa, .{ .px = c.thumb.pixels, .w = c.thumb.width, .h = c.thumb.height }, iw, ih, k);
    defer self.gpa.free(icon_px);
    try self.drag.start(&self.win, data, uri, .{ .pixels = icon_px, .width = iw, .height = ih, .scale = k });
    self.dragging = i;
    log.info("dragging {s} (file {s})", .{ c.kept.id.slice(), file });
}

/// A file for apps that take paths: the saved one, else a copy with a
/// readable name in the cache (a capture taken in the same second gets
/// its own copy; dragging the same one again reuses it).
fn dragFile(self: *Quick, c: *const stack.Card, data: []const u8, file_buf: []u8) ![]const u8 {
    if (c.meta.saved.len > 0 and (sys.fileSize(c.meta.saved) catch null) != null) return c.meta.saved;
    var dir_buf: [1024]u8 = undefined;
    const cache = try env_mod.cacheDir(&dir_buf, self.env.home);
    var drag_dir_buf: [1100]u8 = undefined;
    const drag_dir = try std.fmt.bufPrint(&drag_dir_buf, "{s}/drag", .{cache});
    sys.mkdirAll(drag_dir, 0o700);
    var name_buf: [64]u8 = undefined;
    const base = try filename.baseName(self.gpa, self.env, @divFloor(c.meta.time_ms, 1000), &name_buf);
    const p = try filename.writeOrReuse(self.gpa, drag_dir, base, ".png", data);
    defer self.gpa.free(p);
    if (p.len > file_buf.len) return error.NameTooLong;
    @memcpy(file_buf[0..p.len], p);
    return file_buf[0..p.len];
}

/// A finished drag removes the card; a cancelled one keeps it.
pub fn checkDrag(self: *Quick) void {
    const i = self.dragging orelse return;
    const out = self.drag.poll(&self.win) orelse return;
    self.dragging = null;
    self.dirty = true;
    switch (out) {
        .finished => {
            log.info("dropped", .{});
            if (i < self.cards.items.len) self.remove(i);
        },
        .cancelled => log.info("drag cancelled", .{}),
    }
}
