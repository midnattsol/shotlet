//! A few pieces of work side by side, a thread each. A piece whose thread
//! cannot be started runs at once, on the caller's: every piece is done
//! when wait() returns, with or without threads.
//!
//!   var g: parallel.Group(8) = .{};
//!   for (parts) |*p| g.go(work, .{p});
//!   g.wait();

const std = @import("std");

/// At most `max` pieces.
pub fn Group(comptime max: usize) type {
    return struct {
        const Self = @This();

        threads: [max]std.Thread = undefined,
        n: usize = 0,

        /// `f(args...)` on a thread of its own, else here.
        pub fn go(self: *Self, comptime f: anytype, args: anytype) void {
            if (self.n < max) if (std.Thread.spawn(.{}, f, args)) |t| {
                self.threads[self.n] = t;
                self.n += 1;
                return;
            } else |_| {};
            @call(.auto, f, args);
        }

        pub fn wait(self: *Self) void {
            for (self.threads[0..self.n]) |t| t.join();
            self.n = 0;
        }
    };
}

test "every piece is done once, also past the threads there are" {
    const Work = struct {
        fn add(to: *std.atomic.Value(u32), v: u32) void {
            _ = to.fetchAdd(v, .monotonic);
        }
    };
    var sum: std.atomic.Value(u32) = .init(0);
    var g: Group(2) = .{};
    for (1..6) |v| g.go(Work.add, .{ &sum, @as(u32, @intCast(v)) });
    g.wait();
    try std.testing.expectEqual(@as(u32, 15), sum.load(.monotonic));
}
