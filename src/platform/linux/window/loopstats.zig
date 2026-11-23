//! How responsive the event loop is (SHOTLET_LOOP_STATS): the time spent
//! between two visits to the Wayland socket is time the compositor's
//! pings (xdg_wm_base) go unanswered and input waits. Each such span is
//! recorded; a span in which a frame was presented is a frame's time.
//! When the window closes, one log line sums them up:
//!
//!   loop: shotlet:scroll: 412 frames p50 3.1 ms p95 6.0 ms max 9.8 ms; longest away from the socket 140 ms
//!
//! The e2e suites read that line (a responsiveness check). Off, it costs
//! a clock read per wait.

const std = @import("std");
const sys = @import("../sys.zig");
const switches = @import("../../api/switches.zig");

const log = std.log.scoped(.loop);

/// frame times kept for the percentiles (the newest win)
const keep = 4096;

var frames: [keep]u32 = undefined;
var n_frames: usize = 0;
/// the longest span away from the socket, frames or not (µs)
var longest_us: u64 = 0;
/// when the loop last left the socket (ns; 0: not yet)
var left_at: i64 = 0;
var presents: u64 = 0;
var presents_at_leave: u64 = 0;
/// the window's title (the summary's name)
var name_buf: [48]u8 = undefined;
var name_len: usize = 0;

fn on() bool {
    return switches.get().loop_stats;
}

/// The loop is back at the socket: the span since it left ends.
pub fn arrive() void {
    if (!on() or left_at == 0) return;
    const us: u64 = @intCast(@divTrunc(@max(0, sys.monoNs() - left_at), 1000));
    longest_us = @max(longest_us, us);
    if (presents != presents_at_leave) {
        frames[n_frames % keep] = @intCast(@min(us, std.math.maxInt(u32)));
        n_frames += 1;
    }
    left_at = 0;
}

/// The loop leaves the socket (to handle what it read, to draw).
pub fn leave() void {
    if (!on()) return;
    left_at = sys.monoNs();
    presents_at_leave = presents;
}

/// A frame went to the compositor.
pub fn presented() void {
    presents +%= 1;
}

pub const Summary = struct { frames: usize, p50_us: u32, p95_us: u32, max_us: u32, longest_us: u64 };

/// The spans so far, and a fresh start.
pub fn take() Summary {
    defer reset();
    const n: usize = @min(n_frames, keep);
    const xs = frames[0..n];
    std.mem.sort(u32, xs, {}, std.sort.asc(u32));
    return .{
        .frames = n_frames,
        .p50_us = if (n > 0) xs[n / 2] else 0,
        .p95_us = if (n > 0) xs[@min(n - 1, n * 95 / 100)] else 0,
        .max_us = if (n > 0) xs[n - 1] else 0,
        .longest_us = longest_us,
    };
}

fn reset() void {
    n_frames = 0;
    longest_us = 0;
    left_at = 0;
}

/// A window titled `title` opens: the spans start afresh.
pub fn opened(title: []const u8) void {
    name_len = @min(title.len, name_buf.len);
    @memcpy(name_buf[0..name_len], title[0..name_len]);
    reset();
}

/// Log the summary of the window that closes (when on).
pub fn report() void {
    if (!on() or name_len == 0) return;
    const title = name_buf[0..name_len];
    name_len = 0;
    const s = take();
    log.info("{s}: {d} frames p50 {d}.{d} ms p95 {d}.{d} ms max {d}.{d} ms; longest away from the socket {d} ms", .{
        title,
        s.frames,
        s.p50_us / 1000,
        s.p50_us % 1000 / 100,
        s.p95_us / 1000,
        s.p95_us % 1000 / 100,
        s.max_us / 1000,
        s.max_us % 1000 / 100,
        s.longest_us / 1000,
    });
}

test "frame spans and the longest span away from the socket" {
    switches.set(.{ .loop_stats = true });
    defer switches.set(.{});
    reset();
    for (0..10) |i| {
        frames[i] = @intCast((i + 1) * 1000);
        n_frames += 1;
    }
    longest_us = 50_000;
    const s = take();
    try std.testing.expectEqual(@as(usize, 10), s.frames);
    try std.testing.expectEqual(@as(u32, 6000), s.p50_us);
    try std.testing.expectEqual(@as(u32, 10_000), s.p95_us);
    try std.testing.expectEqual(@as(u64, 50_000), s.longest_us);
    try std.testing.expectEqual(@as(usize, 0), take().frames);
    // more frames than kept: the newest count, the total stays
    for (0..keep + 100) |i| {
        frames[n_frames % keep] = @intCast(i);
        n_frames += 1;
    }
    try std.testing.expectEqual(@as(usize, keep + 100), take().frames);
}
