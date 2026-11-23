//! Small ease-out transitions for UI chrome. Nothing here blocks: a Tween
//! is a value that moves toward its target over a short time, read when
//! a frame is drawn; the caller keeps drawing frames while any is active.
//!
//!   motion.enabled     false (reduced motion) makes every Tween jump
//!   Tween.to(v, now)   retarget from wherever it is now
//!   Tween.snap(v)      jump without a transition
//!   Tween.at(now)      current value;  Tween.busy(now): still moving
//!   Life               a surface's opacity over its life: eased in when
//!                      shown, eased out when it leaves (start, leave,
//!                      alpha, busy, gone); reduced motion: no fades

const std = @import("std");
const sys = @import("../platform/api.zig").sys;
const theme = @import("theme.zig");

/// Off when the desktop asks for reduced motion (or for scripted runs,
/// whose frame dumps must not depend on timing).
pub var enabled: bool = true;

pub fn now() i64 {
    return sys.monoMs();
}

/// Cubic ease-out on 0..1.
pub fn easeOut(t: f64) f64 {
    const k = 1.0 - std.math.clamp(t, 0, 1);
    return 1.0 - k * k * k;
}

pub const Tween = struct {
    from: f64 = 0,
    target: f64 = 0,
    start_ms: i64 = 0,
    dur_ms: i64 = theme.motion,

    pub fn snap(self: *Tween, v: f64) void {
        self.from = v;
        self.target = v;
        self.start_ms = 0;
    }

    /// Move toward `v`, starting from the current value.
    pub fn to(self: *Tween, v: f64, t: i64) void {
        if (v == self.target) return;
        if (!enabled) return self.snap(v);
        self.from = self.at(t);
        self.target = v;
        self.start_ms = t;
    }

    pub fn at(self: Tween, t: i64) f64 {
        if (self.start_ms == 0 or self.dur_ms <= 0) return self.target;
        const p = @as(f64, @floatFromInt(t - self.start_ms)) / @as(f64, @floatFromInt(self.dur_ms));
        if (p >= 1) return self.target;
        return self.from + (self.target - self.from) * easeOut(p);
    }

    pub fn busy(self: Tween, t: i64) bool {
        return self.start_ms != 0 and t - self.start_ms < self.dur_ms and self.from != self.target;
    }
};

/// The opacity of something that fades in when shown and out when it
/// leaves (a floating window, a card): eased, `theme.motion_enter` in and
/// `theme.motion_exit` out. With motion disabled it shows at once and
/// is gone as soon as it leaves. Times are motion.now() milliseconds;
/// 0 means "not yet".
pub const Life = struct {
    in_ms: i64 = theme.motion_enter,
    out_ms: i64 = theme.motion_exit,
    /// when it was first shown (start)
    born: i64 = 0,
    /// when it started to leave (leave)
    leaving: i64 = 0,

    /// Shown from `t` on (the first frame); later calls keep the first.
    pub fn start(self: *Life, t: i64) void {
        if (self.born == 0) self.born = t;
    }

    /// Start fading out at `t` (once).
    pub fn leave(self: *Life, t: i64) void {
        if (self.leaving == 0) self.leaving = t;
    }

    /// Opacity at `t`, 0..1: 0 before start, eased in, then eased out
    /// after leave.
    pub fn alpha(self: Life, t: i64) f64 {
        if (self.born == 0) return 0;
        if (!enabled) return if (self.leaving != 0) 0 else 1;
        var a = easeOut(progress(t - self.born, self.in_ms));
        if (self.leaving != 0) a = @min(a, easeOut(1 - progress(t - self.leaving, self.out_ms)));
        return a;
    }

    /// Still changing at `t` (or not shown yet): keep drawing frames.
    pub fn busy(self: Life, t: i64) bool {
        if (self.born == 0) return true;
        if (!enabled) return false;
        if (t - self.born < self.in_ms) return true;
        return self.leaving != 0 and t - self.leaving < self.out_ms;
    }

    /// Faded out completely: it can be dropped.
    pub fn gone(self: Life, t: i64) bool {
        if (self.leaving == 0) return false;
        return !enabled or t - self.leaving >= self.out_ms;
    }
};

/// How far `dt` is into `dur`, 0..1.
fn progress(dt: i64, dur: i64) f64 {
    if (dur <= 0) return 1;
    return std.math.clamp(@as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(dur)), 0, 1);
}

test "a life fades in eased, out eased, and is then gone" {
    var l: Life = .{ .in_ms = 100, .out_ms = 200 };
    try std.testing.expectEqual(@as(f64, 0), l.alpha(5));
    try std.testing.expect(l.busy(5));
    l.start(1000);
    l.start(1050); // the first start counts
    try std.testing.expectEqual(@as(f64, 0), l.alpha(1000));
    const mid = l.alpha(1050);
    try std.testing.expect(mid > 0.5 and mid < 1); // ease-out: past halfway
    try std.testing.expect(l.busy(1050));
    try std.testing.expectEqual(@as(f64, 1), l.alpha(1100));
    try std.testing.expect(!l.busy(1500));
    try std.testing.expect(!l.gone(1500));
    l.leave(2000);
    l.leave(2100); // the first leave counts
    try std.testing.expectEqual(@as(f64, 1), l.alpha(2000));
    const out = l.alpha(2100);
    try std.testing.expect(out > 0.5 and out < 1); // slow at first
    try std.testing.expect(l.busy(2100) and !l.gone(2100));
    try std.testing.expectEqual(@as(f64, 0), l.alpha(2200));
    try std.testing.expect(l.gone(2200) and !l.busy(2200));
}

test "with reduced motion a life shows at once and leaves at once" {
    enabled = false;
    defer enabled = true;
    var l: Life = .{};
    l.start(1000);
    try std.testing.expectEqual(@as(f64, 1), l.alpha(1000));
    try std.testing.expect(!l.busy(1000));
    l.leave(1001);
    try std.testing.expectEqual(@as(f64, 0), l.alpha(1001));
    try std.testing.expect(l.gone(1001));
}

test "tween eases toward its target and can be retargeted" {
    var tw: Tween = .{ .dur_ms = 100 };
    tw.snap(0);
    tw.to(10, 1000);
    try std.testing.expect(tw.busy(1050));
    const mid = tw.at(1050);
    try std.testing.expect(mid > 5 and mid < 10); // ease-out: past halfway
    try std.testing.expectEqual(@as(f64, 10), tw.at(1100));
    try std.testing.expect(!tw.busy(1100));
    tw.to(0, 1050);
    try std.testing.expectEqual(mid, tw.at(1050));
    enabled = false;
    defer enabled = true;
    tw.to(5, 1060);
    try std.testing.expectEqual(@as(f64, 5), tw.at(1060));
}
