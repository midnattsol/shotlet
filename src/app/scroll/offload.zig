//! Slow work of a scrolling capture (a frame from the shell, stitching
//! it, the control's preview) on a worker thread, while the caller keeps
//! its window answering: input, and the compositor's pings (GNOME offers
//! to force quit a window that does not answer for a few seconds).

const std = @import("std");

fn Result(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

/// `func(args...)` on a worker thread; meanwhile `pump.pump(ms)` keeps
/// being called (its errors are the pump's to keep: it is not called
/// again once it failed). Without a thread, `func` runs here.
pub fn run(pump: anytype, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(func) {
    const Job = struct {
        args: @TypeOf(args),
        out: Result(func) = undefined,
        done: std.atomic.Value(bool) = .init(false),

        fn work(self: *@This()) void {
            self.out = @call(.auto, func, self.args);
            self.done.store(true, .release);
        }
    };
    var job: Job = .{ .args = args };
    const t = std.Thread.spawn(.{}, Job.work, .{&job}) catch return @call(.auto, func, args);
    var pumping = true;
    while (!job.done.load(.acquire)) {
        if (pumping) {
            pump.pump(5) catch {
                pumping = false;
            };
        } else std.Thread.yield() catch {};
    }
    t.join();
    return job.out;
}

test "the work runs beside the pump, which keeps being called" {
    const Pump = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn pump(self: *@This(), ms: i32) !void {
            _ = ms;
            _ = self.calls.fetchAdd(1, .monotonic);
        }
    };
    const Work = struct {
        fn slow(p: *Pump, x: u32) !u32 {
            // until the pump went round a few times
            while (p.calls.load(.monotonic) < 3) std.Thread.yield() catch {};
            return x * 2;
        }
    };
    var p: Pump = .{};
    try std.testing.expectEqual(@as(u32, 42), try run(&p, Work.slow, .{ &p, 21 }));
    try std.testing.expect(p.calls.load(.monotonic) >= 3);
}
