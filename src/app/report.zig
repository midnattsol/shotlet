//! Telling the person something went wrong, wherever Shotlet was started
//! from: a shortcut or the tray has no terminal, so a problem that only
//! reached the log was invisible. A problem goes to
//!
//! - the screen: a `shotlet toast --info` card (it outlives this
//!   process, so a command can say why and end at once);
//! - stderr, as every command's messages: "shotlet COMMAND: Title. Body."
//!   (cli/out.zig), which a terminal shows;
//! - the log.
//!
//! A command that stops because of a reported problem returns
//! error.Reported; its entry point ends with `exitIfReported`, status 1
//! and no second message.

const std = @import("std");
const out = @import("../cli/out.zig");
const relaunch = @import("relaunch.zig");
const Env = @import("env.zig").Env;

pub const Reported = error.Reported;

/// `title`: what went wrong, a short sentence without its full stop;
/// `body`: what to do about it, or the cause ("" for none).
pub fn problem(env: Env, title: []const u8, body: []const u8) void {
    var buf: [400]u8 = undefined;
    const line = sentence(&buf, title, body);
    std.log.warn("{s}", .{line});
    out.warn("{s}", .{line});
    relaunch.toast(env, .info, title, body);
}

/// A problem whose cause is an error: its words become the body.
pub fn failed(env: Env, title: []const u8, err: anyerror) void {
    var buf: [128]u8 = undefined;
    const words = out.describe(&buf, err);
    var cap: [128]u8 = undefined;
    problem(env, title, capitalised(&cap, words));
}

/// Something done, said once its window is gone (a card with a check).
pub fn done(env: Env, title: []const u8, body: []const u8) void {
    relaunch.toast(env, .done, title, body);
}

/// For a command's entry point: a problem already reported ends the
/// process with status 1 (the dispatcher would print a second message);
/// any other error is returned.
pub fn exitIfReported(err: anyerror) anyerror {
    if (err == error.Reported) out.exit(.failure);
    return err;
}

/// "Title. Body." ("Title." without a body).
fn sentence(buf: []u8, title: []const u8, body: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}.", .{title}) catch return w.buffered();
    if (body.len > 0) w.print(" {s}.", .{body}) catch {};
    return w.buffered();
}

fn capitalised(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

test "problems read as sentences" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("No image on the clipboard. Copy one first.", sentence(&buf, "No image on the clipboard", "Copy one first"));
    try std.testing.expectEqualStrings("Recording didn\u{2019}t start.", sentence(&buf, "Recording didn\u{2019}t start", ""));
    var small: [8]u8 = undefined;
    try std.testing.expect(sentence(&small, "A long title", "and more").len <= 8);
    var cap: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Permission denied", capitalised(&cap, "permission denied"));
    try std.testing.expectEqualStrings("", capitalised(&cap, ""));
}
