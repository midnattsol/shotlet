//! Internal development commands (not part of the user-facing CLI):
//! test-window, test-capture, test-grab, test-font, test-decode.

const std = @import("std");
const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const png = @import("../../gfx/png.zig");
const sys = @import("sys.zig");
const dump = @import("window/dump.zig");
const Env = @import("../../app/env.zig").Env;
const DevCommand = @import("../api/devtools.zig").DevCommand;
const screencast = @import("capture/screencast.zig");
const text = @import("../../gfx/text.zig");
const render = @import("../../gfx/render.zig");

pub fn run(gpa: std.mem.Allocator, env: Env, cmd: DevCommand) !void {
    switch (cmd) {
        .window => try testWindow(gpa, env),
        .grab => try testGrab(gpa, env),
        .font => |f| try testFont(gpa, env, f.lines, f.out, f.font),
        .decode => |file| try testDecode(gpa, env, file),
    }
}

/// `test-window`: fullscreen gradient for ~3s, Esc to close.
fn testWindow(gpa: std.mem.Allocator, env: Env) !void {
    const window = @import("window.zig");
    var win = try window.Window.init(gpa, env);
    defer win.deinit();
    try win.open("Shotlet test", .{});
    var elapsed_ms: i64 = 0;
    var frames: u32 = 0;
    outer: while (elapsed_ms < 3000) {
        while (try win.nextEventTimeout(100)) |ev| {
            switch (ev) {
                .resize => {
                    const px = try win.backBuffer();
                    for (px, 0..) |*p, i| {
                        const x: u32 = @intCast(i % win.width);
                        const y: u32 = @intCast(i / win.width);
                        p.* = 0xFF000000 | ((x * 255 / win.width) << 16) | ((y * 255 / win.height) << 8) | 0x40;
                    }
                    try win.present();
                    frames += 1;
                },
                .key => |k| if (k.pressed and k.code == .escape) break :outer,
                .close => break :outer,
                else => {},
            }
        }
        elapsed_ms += 100;
    }
    std.debug.print("window ok: {d}x{d}, {d} frames presented\n", .{ win.width, win.height, frames });
}

/// `test-grab`: ScreenCast + PipeWire, every monitor, stitched to a PNG.
fn testGrab(gpa: std.mem.Allocator, env: Env) !void {
    var cfg = @import("../../app/config.zig").load(gpa, env.home);
    var bus = try dbus.Connection.connectSession(gpa, env.session.bus);
    defer bus.deinit();
    portal.registerApp(gpa, &bus);
    const t0 = sys.monoMs();
    var sc = switch (try portal.openScreenCast(gpa, &bus, .{ .restore_token = cfg.scToken() })) {
        .granted => |s| s,
        else => |o| {
            std.debug.print("screencast: {t}\n", .{o});
            return;
        },
    };
    defer sc.close(gpa, &bus);
    const t1 = sys.monoMs();
    if (sc.start.restore_token) |t| screencast.rememberToken(gpa, env.home, &cfg, t);
    std.debug.print("session: streams={d} fd={d} portal={d}ms token={s}\n", .{
        sc.start.streams.len, sc.fd, t1 - t0, if (sc.start.restore_token != null) "new" else "reused",
    });
    for (sc.start.streams) |st| std.debug.print("  node {d} position={any} size={any}\n", .{ st.node_id, st.position, st.size });
    var cap = try screencast.grabStitched(gpa, &bus, &sc);
    defer cap.deinit(gpa);
    const t2 = sys.monoMs();
    std.debug.print("image: {d}x{d} grab+stitch={d}ms total={d}ms\n", .{ cap.image.width, cap.image.height, t2 - t1, t2 - t0 });
    const out = try png.encode(gpa, cap.image.pixels, cap.image.width, cap.image.height);
    defer gpa.free(out);
    try writeDebug(gpa, env, "shotlet-grab.png", out);
}

/// `test-font`: renders sample text to a PNG; `test-font "line|line..."
/// [out.png [font.ttf]]` renders the given lines (with that font first in
/// the fallback chain).
fn testFont(gpa: std.mem.Allocator, env: Env, lines: ?[]const u8, dest: ?[]const u8, font: ?[]const u8) !void {
    text.initWith(gpa, font);
    defer text.deinit();
    if (lines) |l| {
        const out = try fontLines(gpa, l);
        defer gpa.free(out);
        if (dest) |d| {
            try dump.write(d, out);
        } else try writeDebug(gpa, env, "shotlet-font.png", out);
        return;
    }
    const out = try fontSample(gpa);
    defer gpa.free(out);
    try writeDebug(gpa, env, "shotlet-font.png", out);
}

/// PNG of the `|`-separated lines, each on a highlighted row.
fn fontLines(gpa: std.mem.Allocator, lines: []const u8) ![]u8 {
    const W = 1000;
    const n_lines = std.mem.count(u8, lines, "|") + 1;
    const row = text.height(44.0) + 20;
    const H: usize = @intCast(20 + row * @as(i32, @intCast(n_lines)));
    const px = try gpa.alloc(u32, W * H);
    defer gpa.free(px);
    @memset(px, 0xFFFFFFFF);
    var canvas = render.Canvas.init(px, W, @intCast(H));
    var it = std.mem.splitScalar(u8, lines, '|');
    var y: i32 = 10;
    while (it.next()) |line| : (y += row) {
        const w = text.width(44.0, line);
        canvas.fillRect(20, y, w, text.height(44.0), 0xFFE7F0FF);
        text.draw(&canvas, 20, y, 44.0, 0xFF101010, line);
    }
    return png.encode(gpa, px, W, @intCast(H));
}

/// PNG of a fixed sample at the UI's sizes.
fn fontSample(gpa: std.mem.Allocator) ![]u8 {
    const W = 900;
    const H = 240;
    const px = try gpa.alloc(u32, W * H);
    defer gpa.free(px);
    @memset(px, 0xFF1B1F23);
    var canvas = render.Canvas.init(px, W, H);
    text.draw(&canvas, 20, 16, 34.0, 0xFFE9ECEF, "Shotlet Settings — AaBbGg 0123");
    text.draw(&canvas, 20, 70, 22.0, 0xFF4DABF7, "Notification after saving");
    text.draw(&canvas, 20, 105, 16.0, 0xFF8B939B, "Bind a key to \"shotlet\" — áéíóú ñ ç ü");
    text.draw(&canvas, 20, 140, 13.0, 0xFFE9ECEF, "Small 13px: The quick brown fox jumps over the lazy dog");
    text.draw(&canvas, 20, 170, 11.0, 0xFFE9ECEF, "Tiny 11px: The quick brown fox jumps over the lazy dog");
    return png.encode(gpa, px, W, H);
}

/// `test-decode FILE`: decodes a PNG and writes it back re-encoded.
fn testDecode(gpa: std.mem.Allocator, env: Env, file: []const u8) !void {
    const data = try sys.readFileAlloc(gpa, file, 256 * 1024 * 1024);
    defer gpa.free(data);
    var img = try png.decode(gpa, data);
    defer img.deinit(gpa);
    std.debug.print("decoded {d}x{d}, pixel[0]=0x{x:0>8}\n", .{ img.width, img.height, img.pixels[0] });
    const out = try png.encode(gpa, img.pixels, img.width, img.height);
    defer gpa.free(out);
    try writeDebug(gpa, env, "shotlet-reencoded.png", out);
}

/// Debug output goes to $XDG_RUNTIME_DIR (private to the user, 0700), never
/// to a fixed, world-readable /tmp path another user could pre-create.
fn writeDebug(gpa: std.mem.Allocator, env: Env, name: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ env.runtime_dir, name });
    defer gpa.free(path);
    try dump.write(path, data);
    std.debug.print("wrote {s}\n", .{path});
}
