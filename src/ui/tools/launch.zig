//! How the editor was started, set by the command before it runs (the
//! editor is opened from several places; these few settings ride along).

const Env = @import("../../app/env.zig").Env;

/// `shotlet text`: select a region, its text goes to the clipboard
pub var text_capture = false;
/// start with the whole picture selected (an opened file)
pub var select_all = false;
/// a pin's Annotate (`edit FILE --pin-fd N`): what is copied, saved or
/// pinned goes back to that pin through this pipe (app/pin/annotate.zig)
pub var pin_fd: ?sys.fd_t = null;

const std = @import("std");
const log = std.log.scoped(.editor);
const sys = @import("../../platform/api.zig").sys;
const ipc = @import("../../app/ipc.zig");
const testutil = @import("../../testutil.zig");

/// Hand `png` back to the pin this edit is for, once, and let it show
/// again (null: a Cancel, it stays as it was). False when no pin asked.
pub fn backToPin(png: ?[]const u8) bool {
    const fd = pin_fd orelse return false;
    pin_fd = null;
    defer sys.close(fd);
    if (png) |d| sys.writeAllBlocking(fd, d) catch |err| log.warn("pin: could not hand the picture back: {t}", .{err});
    return true;
}

/// With the GNOME integration the shell takes the screenshot and starts a
/// new shotlet on it: a text capture leaves a note for that one, in the
/// runtime directory, per desktop session (ipc.sessionPath).
fn notePath(buf: []u8, runtime_dir: []const u8, session: []const u8) ![]const u8 {
    return ipc.sessionPath(buf, runtime_dir, session, "next-capture", "");
}

pub fn handOff(env: Env) void {
    noteFor(env.runtime_dir, env.session.tag());
}

fn noteFor(runtime_dir: []const u8, session: []const u8) void {
    if (!text_capture) return;
    var buf: [512]u8 = undefined;
    const path = notePath(&buf, runtime_dir, session) catch return;
    var line: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "text {d}\n", .{sys.monoMs()}) catch return;
    sys.unlink(path) catch {};
    sys.writeFileExclusive(path, s, 0o600) catch {};
}

/// The note, when fresh (the last few seconds), sets the mode.
pub fn takeHandOff(env: Env) void {
    takeNote(env.runtime_dir, env.session.tag());
}

fn takeNote(runtime_dir: []const u8, session: []const u8) void {
    var buf: [512]u8 = undefined;
    const path = notePath(&buf, runtime_dir, session) catch return;
    // no allocator: a FixedBufferAllocator smaller than an ArrayList's
    // first growth (a cache line, 128 bytes on x86_64) failed every read
    var mem: [64]u8 = undefined;
    const data = sys.readFileBuf(path, &mem) catch return;
    sys.unlink(path) catch {};
    if (parseNote(data, sys.monoMs())) text_capture = true;
}

fn parseNote(data: []const u8, now: i64) bool {
    var it = std.mem.tokenizeAny(u8, data, " \n");
    if (!std.mem.eql(u8, it.next() orelse return false, "text")) return false;
    const t = std.fmt.parseInt(i64, it.next() orelse return false, 10) catch return false;
    return now - t >= 0 and now - t < 10_000;
}

test "a text capture's note reaches the shotlet the shell starts" {
    var tmp = try testutil.TmpDir.init("shotlet-launch");
    defer tmp.deinit();
    defer text_capture = false;
    text_capture = true;
    noteFor(tmp.path, "wl0");
    text_capture = false;
    // another desktop session's shotlet does not take it
    takeNote(tmp.path, "wl1");
    try std.testing.expect(!text_capture);
    takeNote(tmp.path, "wl0");
    try std.testing.expect(text_capture);
    // taken once: the next shell capture is a plain one
    text_capture = false;
    takeNote(tmp.path, "wl0");
    try std.testing.expect(!text_capture);
}

test "a capture note is honoured only while fresh" {
    try std.testing.expect(parseNote("text 1000\n", 5000));
    try std.testing.expect(!parseNote("text 1000\n", 20000));
    try std.testing.expect(!parseNote("edit 1000\n", 1500));
    try std.testing.expect(!parseNote("text x", 1500));
}
