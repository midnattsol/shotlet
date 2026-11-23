//! The command set both input drivers speak (tools/e2e/drive.zig on
//! GNOME, tools/container/wldrive.zig on wlroots and KWin), one command
//! per line (loop.zig). MON is a monitor's connector name or its number.
//!
//!   key COMBO [down|up]   tap (or press/release) evdev keys: ctrl+shift+s,
//!                         altgr+e, semicolon, 2, #30 (raw evdev code)
//!   hold NAME MS          press, wait MS, release (key repeat)
//!   type TEXT             tap the keys of lowercase letters, digits, spaces
//!   keysym HEX            tap a keysym (the compositor picks the keycode)
//!   move MON X Y          absolute motion, logical pixels of monitor MON
//!   rel DX DY             relative motion
//!   down|up|click [BTN]   left (default), right, middle
//!   wheel STEPS           discrete vertical scroll (+ is down)
//!   monitors              the monitors (the format is the backend's)
//!   shot MON PATH         write the monitor's current picture as a PNG;
//!                         answers WxH
//!   find MON RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]
//!                         "cx cy w h" of the first blob of that colour (at
//!                         least MINW wide), in the monitor's pixels
//!   findpng PATH RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]   the same in a PNG
//!   png PATH              the image size, WxH
//!   pixel PATH X Y        one pixel as AARRGGBB hex
//!   runs PATH X RRGGBB [TOL]  how many vertical runs of that colour
//!                         column X of the PNG has
//!   mkpng PATH W H BG [X0,Y0,X1,Y1,RRGGBB ...]   a test picture
//!                         (images.zig: no box frames BG in grey, `plain`
//!                         leaves it plain)
//!   textpng PATH SIZE TEXT  black TEXT on white (Shotlet's text renderer)
//!   film MON              start filming the monitor
//!   cut DIR|- [X0 Y0 X1 Y1]  stop filming; answer "frames N ghosts G
//!                         blends B worst I PERMILLE" (the box, monitor
//!                         pixels, left out); DIR gets each frame as PNG
//!   sni-watcher [MS]      own org.kde.StatusNotifierWatcher; answer the
//!                         first RegisterStatusNotifierItem within MS
//!   sleep MS
//!   quit
//!
//! A backend lacking a command (keysym, film and cut need Mutter) answers
//! `err Unsupported`. The backend `d` provides `gpa`, an `out` buffer,
//! and key, button, move, rel, wheel, keysym, monitors, grab, film, cut,
//! sniWatcher and idle.

const std = @import("std");
const loop = @import("loop.zig");
const keys = @import("keys.zig");
const images = @import("images.zig");
const Args = loop.Args;
const eql = loop.eql;

/// Run one command line; its answer's value (empty for a plain `ok`).
pub fn run(d: anytype, line: []const u8) ![]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return "";
    if (try input(d, cmd, line, &it)) return "";
    if (eql(cmd, "monitors")) return d.monitors();
    if (eql(cmd, "shot")) return shot(d, &it);
    if (eql(cmd, "find")) {
        var f = try d.grab(try loop.arg(&it));
        defer f.deinit();
        return images.find(d.gpa, &d.out, &f, &it);
    }
    if (eql(cmd, "findpng")) return images.findPng(d.gpa, &d.out, &it);
    if (eql(cmd, "png")) return images.size(d.gpa, &d.out, &it);
    if (eql(cmd, "pixel")) return images.pixel(d.gpa, &d.out, &it);
    if (eql(cmd, "runs")) return images.runs(d.gpa, &d.out, &it);
    if (eql(cmd, "mkpng")) return images.mkpng(d.gpa, &d.out, &it);
    if (eql(cmd, "textpng")) return images.textpng(d.gpa, &d.out, line, &it);
    if (eql(cmd, "film")) {
        try d.film(try loop.arg(&it));
        return "";
    }
    if (eql(cmd, "cut")) return d.cut(try loop.arg(&it), try loop.optBox(&it));
    if (eql(cmd, "sni-watcher")) return d.sniWatcher(try loop.optInt(u32, &it, 5000));
    if (eql(cmd, "sleep")) {
        loop.sleepMs(try loop.int(u32, &it));
        return "";
    }
    if (eql(cmd, "quit")) return "";
    return error.UnknownCommand;
}

/// The input commands, which answer a plain `ok`; whether `cmd` is one.
fn input(d: anytype, cmd: []const u8, line: []const u8, it: *Args) !bool {
    if (eql(cmd, "key")) {
        try key(d, it);
    } else if (eql(cmd, "hold")) {
        const code = keys.keyCode(try loop.arg(it)) orelse return error.UnknownKey;
        const ms = try loop.int(u32, it);
        try d.key(code, true);
        loop.sleepMs(ms);
        try d.key(code, false);
    } else if (eql(cmd, "type")) {
        try typeText(d, std.mem.trimStart(u8, line[cmd.len..], " \t"));
    } else if (eql(cmd, "keysym")) {
        try d.keysym(try loop.color(it));
    } else if (eql(cmd, "move")) {
        try d.move(try loop.arg(it), try loop.float(it), try loop.float(it));
    } else if (eql(cmd, "rel")) {
        try d.rel(try loop.float(it), try loop.float(it));
    } else if (eql(cmd, "down") or eql(cmd, "up") or eql(cmd, "click")) {
        try button(d, cmd, it);
    } else if (eql(cmd, "wheel")) {
        try d.wheel(try loop.int(i32, it));
    } else return false;
    return true;
}

/// key COMBO [down|up]
fn key(d: anytype, it: *Args) !void {
    const combo = try loop.arg(it);
    const mode = it.next() orelse "tap";
    var codes: [8]u32 = undefined;
    const n = try keys.parseCombo(combo, &codes);
    if (!eql(mode, "up")) for (codes[0..n]) |c| try d.key(c, true);
    if (!eql(mode, "down")) {
        var i = n;
        while (i > 0) {
            i -= 1;
            try d.key(codes[i], false);
        }
    }
}

/// type TEXT
fn typeText(d: anytype, text: []const u8) !void {
    for (text) |c| {
        const name: []const u8 = if (c == ' ') "space" else &.{c};
        const code = keys.keyCode(name) orelse return error.UnknownKey;
        try d.key(code, true);
        try d.key(code, false);
    }
}

/// down|up|click [BTN]
fn button(d: anytype, cmd: []const u8, it: *Args) !void {
    const name = it.next() orelse "left";
    const btn: u32 = if (eql(name, "left")) 0x110 else if (eql(name, "right")) 0x111 else if (eql(name, "middle")) 0x112 else return error.UnknownButton;
    if (!eql(cmd, "up")) try d.button(btn, true);
    if (!eql(cmd, "down")) try d.button(btn, false);
}

/// shot MON PATH
fn shot(d: anytype, it: *Args) ![]const u8 {
    var f = try d.grab(try loop.arg(it));
    defer f.deinit();
    return images.writePng(d.gpa, &d.out, try loop.arg(it), f.pixels, f.width, f.height);
}

/// A backend that records what it is told, for the tests.
const Fake = struct {
    gpa: std.mem.Allocator = std.testing.allocator,
    out: [512]u8 = undefined,
    log: [256]u8 = undefined,
    len: usize = 0,

    fn note(self: *Fake, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.log[self.len..], fmt ++ ";", args) catch return;
        self.len += s.len;
    }
    fn key(self: *Fake, code: u32, pressed: bool) !void {
        self.note("k{d}{s}", .{ code, if (pressed) "v" else "^" });
    }
    fn button(self: *Fake, btn: u32, pressed: bool) !void {
        self.note("b{x}{s}", .{ btn, if (pressed) "v" else "^" });
    }
    fn move(self: *Fake, mon: []const u8, x: f64, y: f64) !void {
        self.note("m{s}:{d},{d}", .{ mon, x, y });
    }
    fn rel(self: *Fake, dx: f64, dy: f64) !void {
        self.note("r{d},{d}", .{ dx, dy });
    }
    fn wheel(self: *Fake, steps: i32) !void {
        self.note("w{d}", .{steps});
    }
    fn keysym(self: *Fake, sym: u32) !void {
        self.note("s{x}", .{sym});
    }
    fn monitors(_: *Fake) []const u8 {
        return "M";
    }
    fn grab(_: *Fake, _: []const u8) !images.Frame {
        return error.Unsupported;
    }
    fn film(_: *Fake, _: []const u8) !void {}
    fn cut(_: *Fake, _: []const u8, _: ?[4]u32) ![]const u8 {
        return "cut";
    }
    fn sniWatcher(_: *Fake, _: u32) ![]const u8 {
        return error.Unsupported;
    }
};

test "commands reach the backend" {
    var d: Fake = .{};
    for ([_][]const u8{ "key ctrl+c", "type a 1", "click right", "move 0 1.5 2", "rel -3 4", "wheel 2", "keysym 0xff61", "hold esc 0" }) |line|
        try std.testing.expectEqualStrings("", try run(&d, line));
    try std.testing.expectEqualStrings(
        "k29v;k46v;k46^;k29^;k30v;k30^;k57v;k57^;k2v;k2^;b111v;b111^;m0:1.5,2;r-3,4;w2;sff61;k1v;k1^;",
        d.log[0..d.len],
    );
    try std.testing.expectEqualStrings("M", try run(&d, "monitors"));
    try std.testing.expectEqualStrings("cut", try run(&d, "cut - 1 2 3 4"));
    try std.testing.expectError(error.UnknownCommand, run(&d, "fly"));
    try std.testing.expectError(error.MissingArg, run(&d, "move 0 1"));
}
