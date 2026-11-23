//! How a capture leaves shotlet, the same wherever it happens (the
//! editor, the floating thumbnail, the history panel, a pin, a capture
//! mode that skips the editor):
//!
//! - Save writes to the screenshots folder under a new name
//!   (filename.zig: never over a file), or where the save dialog says
//!   (over a file only when the dialog asked; Save As falls back to the
//!   folder on a desktop without one);
//! - a saved capture is also copied when `copy_on_save` is on, and a
//!   desktop notification says where it went when `notify` is on, unless
//!   a thumbnail reports the save already (`policy`);
//! - PNGs carry an alpha channel only for see-through pixels that are
//!   meant (`alphaFor`);
//! - a kept capture (a history entry) is copied, saved, annotated and
//!   pinned through `Entry`;
//! - a saved file is shown in the file manager through `showInFiles`
//!   (the thumbnails' "Saved · Show in Files" and Show in Files).

const std = @import("std");
const api = @import("../platform/api.zig");
const config = @import("config.zig");
const env_mod = @import("env.zig");
const filename = @import("filename.zig");
const history = @import("history.zig");
const relaunch = @import("relaunch.zig");
const report = @import("report.zig");
const clip = @import("modes/clip.zig");
const png = @import("../gfx/png.zig");
const doc_mod = @import("../ui/doc.zig");
const sys = api.sys;
const desktop = api.desktop;
const window = api.window;
const Env = env_mod.Env;

/// Who delivers, and with what.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: *const config.Config,
    /// the desktop session, for the save dialog and the notification
    /// (null: no dialog, so the folder, and no notification)
    bus: ?*desktop.Bus,
    /// takes the clipboard (copy on save, Copy)
    win: *window.Window,
    /// `win` shows no surface: a moment's one takes the clipboard
    /// (modes/clip.zig), as compositors give it only to a focused client
    win_closed: bool = false,
    /// the save dialog's parent window
    over: ?*window.Window = null,
    /// a thumbnail will report this save: no notification then
    thumbnail_shows: bool = false,
    /// the caller's name in the log ("history", "pin", ...)
    who: []const u8,
};

pub const Where = enum {
    /// the screenshots folder
    folder,
    /// the save dialog
    ask,
};

/// What follows a save.
pub const Policy = struct {
    copy: bool,
    notify: bool,
};

pub fn policy(cfg: *const config.Config, thumbnail_shows: bool) Policy {
    return .{ .copy = cfg.copy_on_save, .notify = cfg.notify and !thumbnail_shows };
}

/// Save `data` (a PNG), then copy and notify as the policy says. The path
/// written (owned), or null when the save dialog was cancelled. On an
/// error nothing was written, copied or notified.
pub fn savePng(c: Ctx, data: []const u8, where: Where) !?[]u8 {
    const path = (try writePng(c, data, where)) orelse return null;
    std.log.info("{s}: saved to {s}", .{ c.who, path });
    const p = policy(c.cfg, c.thumbnail_shows);
    // compositors take the clipboard only from the focused client: the
    // save dialog had the focus, so wait for it to come back (a while at
    // most), else the copy would be dropped without a word
    if (p.copy and where == .ask and !c.win_closed and !c.win.kb_focus and !(c.win.waitKeyboardFocus(refocus_ms) catch false))
        std.log.info("{s}: no keyboard focus back for the copy", .{c.who});
    if (p.copy) copyPng(c, data) catch |err| std.log.warn("{s}: copy on save failed: {t}", .{ c.who, err });
    if (p.notify) notifySaved(c, path);
    return path;
}

fn writePng(c: Ctx, data: []const u8, where: Where) !?[]u8 {
    var dir_buf: env_mod.PathBuf = undefined;
    const dir = try saveDir(c, &dir_buf);
    sys.mkdirAll(dir, 0o755); // best effort; may already exist
    var name_buf: [64]u8 = undefined;
    const base = try filename.baseNameNow(c.gpa, c.env, &name_buf);
    if (where == .ask) {
        var file_buf: [80]u8 = undefined;
        const name = try std.fmt.bufPrint(&file_buf, "{s}.png", .{base});
        const target: Target = if (c.bus) |b| try askTarget(c.gpa, b, .{ .current_name = name, .current_folder = dir }, ".png", c.over) else .unavailable;
        switch (target) {
            .path => |p| {
                errdefer c.gpa.free(p);
                try sys.writeFile(p, data);
                return p;
            },
            .cancelled => return null,
            .unavailable => std.log.warn("{s}: no file chooser portal; saving to {s}", .{ c.who, dir }),
        }
    }
    return try filename.writeUnique(c.gpa, dir, base, ".png", data);
}

/// Where screenshots go: the configured save_dir (with ~ expanded), else
/// the user's XDG Pictures directory.
fn saveDir(c: Ctx, buf: []u8) ![]u8 {
    if (c.cfg.saveDir()) |d| return env_mod.expandHome(buf, c.env.home, d);
    return env_mod.userDir(c.gpa, buf, c.env.home, .pictures);
}

/// A save dialog's answer, as the file to write.
pub const Target = union(enum) {
    /// owned; over an existing file only when the dialog asked
    path: []u8,
    cancelled,
    /// no save dialog on this desktop
    unavailable,
};

/// Ask where to save a file of type `ext` (".png", ".mp4"); a name typed
/// without it gets it (filename.completeChosen).
pub fn askTarget(gpa: std.mem.Allocator, bus: *desktop.Bus, opts: desktop.SaveOptions, ext: []const u8, over: ?*window.Window) !Target {
    return switch (try desktop.askSavePath(gpa, bus, opts, over)) {
        .chosen => |p| .{ .path = try filename.completeChosen(gpa, p, ext) },
        .cancelled => .cancelled,
        .unavailable => .unavailable,
    };
}

/// How long a window waits to get the keyboard focus back (after the
/// save dialog) before it takes the clipboard.
const refocus_ms = 1500;

/// Put a copy of `data` (a PNG) on the clipboard.
pub fn copyPng(c: Ctx, data: []const u8) !void {
    const own = try c.gpa.dupe(u8, data);
    const set = if (c.win_closed) clip.copyPng(c.win, own) else c.win.setClipboardPng(own);
    set catch |err| {
        c.gpa.free(own);
        return err;
    };
}

fn notifySaved(c: Ctx, path: []const u8) void {
    const b = c.bus orelse return;
    var buf: [512]u8 = undefined;
    desktop.notify(c.gpa, b, "Shotlet", std.fmt.bufPrint(&buf, "Saved to {s}", .{path}) catch "Saved");
}

/// The PNG alpha channel for exported pixels: only for see-through pixels
/// that are meant, a window's (`keep_alpha`) or a transparent beautify
/// backdrop; everything else stays RGB.
pub fn alphaFor(b: doc_mod.Beautify, keep_alpha: bool) png.EncodeOptions.Alpha {
    return if (keep_alpha or (b.enabled and b.background().transparent())) .auto else .never;
}

pub fn encodePng(gpa: std.mem.Allocator, e: doc_mod.Exported, b: doc_mod.Beautify, keep_alpha: bool) ![]u8 {
    return png.encodeWith(gpa, e.pixels, e.width, e.height, .{ .alpha = alphaFor(b, keep_alpha) });
}

/// What a failed save says: the file was not written.
pub fn failureText(buf: []u8, err: anyerror) []const u8 {
    const why = switch (err) {
        error.AccessDenied => "no permission to write there",
        error.ReadOnlyFileSystem => "the disk is read-only",
        error.NoSpaceLeft, error.DiskQuota => "the disk is full",
        error.NotFound, error.NotDir => "the folder does not exist",
        error.NameTooLong, error.BadPath => "the path is too long or invalid",
        else => @errorName(err),
    };
    return std.fmt.bufPrint(buf, "Not saved: {s}", .{why}) catch "Not saved";
}

/// Show the saved file `path` in the file manager, selected. True when
/// shown; when no file manager answered, a problem card says so and
/// where the file is. A file manager that is slow to start (no answer
/// in time) counts as shown: it got the request.
pub fn showInFiles(gpa: std.mem.Allocator, env: Env, bus: ?*desktop.Bus, path: []const u8, who: []const u8) bool {
    const err: ?anyerror = if (bus) |b| (if (desktop.revealFile(gpa, b, path)) null else |e| e) else error.NoBus;
    if (shown(err)) {
        std.log.info("{s}: showing {s} in the file manager", .{ who, path });
        return true;
    }
    std.log.warn("{s}: no file manager showed {s}: {t}", .{ who, path, err.? });
    var buf: [2200]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "The file is at {s}", .{path}) catch "The file is on disk";
    report.problem(env, "Couldn\u{2019}t open the file manager", body);
    return false;
}

/// Whether a file manager took the request that ended with `err`.
fn shown(err: ?anyerror) bool {
    const e = err orelse return true;
    return e == error.Timeout;
}

/// A kept capture: history entry `id` under `root`, and its meta (the
/// caller's; Save records the path in it and on disk).
pub const Entry = struct {
    root: []const u8,
    id: []const u8,
    meta: *history.Meta,

    pub fn copy(e: Entry, c: Ctx) !void {
        const data = try history.readFile(c.gpa, e.root, e.id, .image);
        c.win.setClipboardPng(data) catch |err| {
            c.gpa.free(data);
            return err;
        };
        std.log.info("{s}: copied {s}", .{ c.who, e.id });
    }

    /// Save as savePng does; false when the save dialog was cancelled.
    pub fn save(e: Entry, c: Ctx, where: Where) !bool {
        const data = try history.readFile(c.gpa, e.root, e.id, .image);
        defer c.gpa.free(data);
        const path = (try savePng(c, data, where)) orelse return false;
        c.gpa.free(e.meta.saved);
        e.meta.saved = path;
        history.writeMeta(c.gpa, e.root, e.id, e.meta) catch |err|
            std.log.warn("{s}: could not record the saved path: {t}", .{ c.who, err });
        return true;
    }

    /// Open it in the editor again (a new process).
    pub fn edit(e: Entry, env: Env) void {
        relaunch.edit(env, e.root, e.id);
    }

    /// Pin its picture where it was taken (a new process).
    pub fn pin(e: Entry, env: Env) !void {
        var buf: env_mod.PathBuf = undefined;
        relaunch.pin(env, try history.entryPath(&buf, e.root, e.id, history.File.image.name()), e.meta.at);
    }
};

// --- tests ---

const testing = std.testing;

const testutil = @import("../testutil.zig");

test "copy on save and the notification follow the settings everywhere" {
    var cfg: config.Config = .{};
    cfg.copy_on_save = false;
    cfg.notify = true;
    try testing.expectEqual(Policy{ .copy = false, .notify = true }, policy(&cfg, false));
    // a thumbnail says it already
    try testing.expectEqual(Policy{ .copy = false, .notify = false }, policy(&cfg, true));
    cfg.copy_on_save = true;
    cfg.notify = false;
    try testing.expectEqual(Policy{ .copy = true, .notify = false }, policy(&cfg, false));
    try testing.expectEqual(Policy{ .copy = true, .notify = false }, policy(&cfg, true));
}

test "Show in Files: shown unless no file manager took it" {
    try testing.expect(shown(null));
    try testing.expect(shown(error.Timeout));
    try testing.expect(!shown(error.ServiceUnknown));
    try testing.expect(!shown(error.NoBus));
    try testing.expect(!shown(error.Unavailable));
}

test "PNGs keep alpha only for see-through pixels that are meant" {
    var b: doc_mod.Beautify = .{};
    try testing.expectEqual(png.EncodeOptions.Alpha.never, alphaFor(b, false));
    try testing.expectEqual(png.EncodeOptions.Alpha.auto, alphaFor(b, true));
    b.bg = @import("../ui/beautify.zig").backgrounds.len - 1; // Transparent
    try testing.expectEqual(png.EncodeOptions.Alpha.never, alphaFor(b, false)); // beautify off
    b.enabled = true;
    try testing.expectEqual(png.EncodeOptions.Alpha.auto, alphaFor(b, false));
    b.bg = 0;
    try testing.expectEqual(png.EncodeOptions.Alpha.never, alphaFor(b, false));
}

test "a failed save says why in words" {
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("Not saved: the disk is full", failureText(&buf, error.NoSpaceLeft));
    try testing.expectEqualStrings("Not saved: Unexpected", failureText(&buf, error.Unexpected));
}

test "Save writes into the folder under a new name each time" {
    const gpa = testing.allocator;
    var tmp = try testutil.TmpDir.init("shotlet-deliver");
    defer tmp.deinit();
    const dir = tmp.path;
    var cfg: config.Config = .{};
    var line_buf: [600]u8 = undefined;
    _ = @import("config/parse.zig").applyText(&cfg, try std.fmt.bufPrint(&line_buf, "save_dir={s}/shots\n", .{dir}));
    cfg.copy_on_save = false;
    var win: window.Window = undefined; // not touched: no copy
    const c: Ctx = .{ .gpa = gpa, .env = .{ .session = undefined, .runtime_dir = "", .home = dir, .tz = "UTC" }, .cfg = &cfg, .bus = null, .win = &win, .who = "test" };
    const a = (try savePng(c, "one", .folder)).?;
    defer gpa.free(a);
    const b = (try savePng(c, "two", .folder)).?;
    defer gpa.free(b);
    try testing.expect(std.mem.indexOf(u8, a, "/shots/shotlet-") != null and std.mem.endsWith(u8, a, ".png"));
    try testing.expect(!std.mem.eql(u8, a, b));
    const first = try sys.readFileAlloc(gpa, a, 16);
    defer gpa.free(first);
    try testing.expectEqualStrings("one", first);
}
