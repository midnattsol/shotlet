//! What the editor remembers between captures: the beautify frame's
//! style, whether every capture starts with it ("always apply") and the
//! magnifier's zoom (in the config file); whether the first-run hint and
//! the magnifier's hint were shown (state flags, stateflag.zig).
//! Beautify itself is per capture.

const std = @import("std");
const config = @import("config.zig");
const stateflag = @import("stateflag.zig");
const Env = @import("env.zig").Env;

/// Store the editor's beautify style, "always apply" and the
/// magnifier's zoom, only the keys that changed from `cfg` (other
/// settings in the file are left alone); the hints once shown.
pub fn remember(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, ed: anytype) void {
    rememberAt(gpa, env.home, cfg, ed);
}

fn rememberAt(gpa: std.mem.Allocator, home: []const u8, cfg: *const config.Config, ed: anytype) void {
    if (ed.loupe.hint.seen) stateflag.set(home, .zoom_hint);
    if (ed.hint_seen) stateflag.set(home, .editor_hint);
    var next = cfg.*;
    // only what the editor changed is written, not what `cfg` may hold
    // in memory that differs from the file
    config.rebase(&next);
    apply(&next, ed);
    config.save(gpa, home, &next) catch |err|
        std.log.warn("could not save editor settings: {t}", .{err});
}

fn apply(c: *config.Config, ed: anytype) void {
    const b = ed.beautify;
    c.beautify_always = ed.beautify_always;
    c.beautify_background = b.bg;
    c.beautify_padding = b.padding;
    c.beautify_corners = b.rounded;
    c.beautify_shadow = b.shadow;
    c.loupe_zoom = ed.loupe.zoom;
}

test "only what the editor changed is saved" {
    const alloc = std.testing.allocator;
    var tmp = try @import("../testutil.zig").TmpDir.home();
    defer tmp.deinit();
    const root = tmp.path;

    var cfg = config.load(alloc, root);
    // held in memory only: never written by remember
    cfg.notify = false;
    const Ed = struct {
        beautify: struct { bg: u8 = 0, padding: u2 = 3, rounded: bool = true, shadow: bool = false } = .{},
        beautify_always: bool = false,
        loupe: struct { zoom: u8 = 8, hint: struct { seen: bool = false } = .{} } = .{},
        hint_seen: bool = false,
    };
    rememberAt(alloc, root, &cfg, &Ed{});
    const data = try tmp.read(".config/shotlet/config");
    defer alloc.free(data);
    try std.testing.expectEqualStrings("# shotlet configuration\nbeautify_padding=large\nbeautify_shadow=false\n", data);
}
