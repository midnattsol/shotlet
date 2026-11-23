//! Debug aid: SHOTLET_DUMP_FRAME=/path/prefix writes each surface's last
//! presented frame to <prefix>-<index>.png when the window closes; and
//! `write`, the one way debug output reaches a file (devtools too).

const std = @import("std");
const log = std.log.scoped(.window);
const sys = @import("../sys.zig");
const png = @import("../../../gfx/png.zig");
const window = @import("../window.zig");
const switches = @import("../../api/switches.zig");

const Window = window.Window;

/// Write the last presented frame of each surface, once, so headless runs
/// can be inspected. No-op without SHOTLET_DUMP_FRAME.
pub fn dumpFrames(w: *Window) void {
    const prefix = switches.get().dump_frame orelse return;
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        const idx = s.last_presented orelse continue;
        const b = &s.buffers[idx];
        if (b.pixels.len == 0) continue;
        const px = @as([*]const u32, @ptrCast(b.pixels.ptr))[0 .. b.pixels.len / 4];
        writeDump(w.alloc, prefix, i, px, s.width, s.height);
        s.last_presented = null;
    }
}

fn writeDump(gpa: std.mem.Allocator, prefix: []const u8, index: usize, px: []const u32, w: u32, h: u32) void {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}-{d}.png", .{ prefix, index }) catch return;
    const data = png.encode(gpa, px, w, h) catch |err| {
        log.warn("frame dump: encode failed: {t}", .{err});
        return;
    };
    defer gpa.free(data);
    write(path, data) catch |err| log.warn("frame dump: cannot write {s}: {t}", .{ path, err });
}

/// Write a debug file: private (0600), replacing what was there without
/// following a symlink planted in its place; logged.
pub fn write(path: []const u8, data: []const u8) !void {
    try sys.writeAtomic(path, data, 0o600);
    log.info("debug output: wrote {s}", .{path});
}
