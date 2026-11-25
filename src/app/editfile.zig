//! `shotlet edit FILE`: any PNG, JPEG or WebP in the editor, all of it
//! selected, then copied or saved like a capture. A file that cannot
//! be opened is reported (report.zig) and ends with status 1.

const std = @import("std");
const log = std.log.scoped(.edit);
const env_mod = @import("env.zig");
const config = @import("config.zig");
const capture = @import("capture.zig");
const shot = @import("shot.zig");
const imgload = @import("../gfx/imgload.zig");
const launch = @import("../ui/tools/launch.zig");
const report = @import("report.zig");
const Env = env_mod.Env;

pub fn run(gpa: std.mem.Allocator, env: Env, path: []const u8) !void {
    var img = imgload.loadFile(gpa, path) catch |err| {
        log.warn("cannot open {s}: {t}", .{ path, err });
        report.failed(env, "Couldn\u{2019}t open the image", err);
        return report.exitIfReported(report.Reported);
    };
    var cap = capture.Capture.single(gpa, img) catch |err| {
        img.deinit(gpa);
        return err;
    };
    defer cap.deinit(gpa);
    launch.select_all = true;

    log.info("showing {s} ({d}x{d})", .{ path, cap.image.width, cap.image.height });
    try shot.editGiven(gpa, env, &cap, null);
}
