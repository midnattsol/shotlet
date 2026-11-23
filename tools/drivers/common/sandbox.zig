//! The guard every e2e helper runs first: it refuses to start outside the
//! test sandboxes, so it can never type into or cover a real desktop.
//! Both runners set SHOTLET_E2E_SANDBOX: `gnome` (tools/e2e/session.sh's
//! private session) or `container` (tools/container/run.sh).

const std = @import("std");

pub const Kind = enum { gnome, container };

/// The variable both runners set.
pub const variable = "SHOTLET_E2E_SANDBOX";

/// The sandbox this process runs in, or null outside any.
pub fn current(vars: *const std.process.Environ.Map) ?Kind {
    const v = vars.get(variable) orelse return null;
    return std.meta.stringToEnum(Kind, v);
}

/// Exit with status 2 unless running in one of the sandboxes `allowed`.
pub fn require(vars: *const std.process.Environ.Map, comptime name: []const u8, comptime allowed: []const Kind) void {
    if (current(vars)) |k| for (allowed) |a| if (k == a) return;
    std.debug.print(name ++ ": refusing to run outside the e2e sandbox (" ++ variable ++ "=" ++ comptime names(allowed) ++ ", set by tools/e2e.sh and tools/container/run.sh)\n", .{});
    std.process.exit(2);
}

fn names(comptime allowed: []const Kind) []const u8 {
    var s: []const u8 = "";
    for (allowed, 0..) |a, i| s = s ++ (if (i > 0) "|" else "") ++ @tagName(a);
    return s;
}

test "sandbox kinds" {
    var vars: std.process.Environ.Map = .init(std.testing.allocator);
    defer vars.deinit();
    try std.testing.expectEqual(@as(?Kind, null), current(&vars));
    // the runners' older variables no longer count
    try vars.put("HL_INNER", "1");
    try vars.put("SHOTLET_CONTAINER", "1");
    try std.testing.expectEqual(@as(?Kind, null), current(&vars));
    try vars.put(variable, "container");
    try std.testing.expectEqual(@as(?Kind, .container), current(&vars));
    try vars.put(variable, "gnome");
    try std.testing.expectEqual(@as(?Kind, .gnome), current(&vars));
    try vars.put(variable, "desktop");
    try std.testing.expectEqual(@as(?Kind, null), current(&vars));
}
