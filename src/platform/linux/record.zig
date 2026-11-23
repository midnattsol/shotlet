//! The screen recording seam on Linux: the source (the GNOME Shell
//! extension's screencast of exactly the area, or a ScreenCast portal
//! session), its PipeWire streams, and the shell's own stop button.

const std = @import("std");
const log = std.log.scoped(.record);
const dbus = @import("dbus.zig");
const gnome = @import("gnome.zig");
const shell1 = @import("gnome/shell1.zig");
const pwstream = @import("pwstream.zig");
const source = @import("record/source.zig");
const types = @import("../api/record.zig");

pub const Want = types.Want;
pub const VideoFormat = types.VideoFormat;
pub const Raw = types.Raw;
pub const VideoFn = types.VideoFn;
pub const AudioFn = types.AudioFn;
pub const AudioSource = types.AudioSource;
pub const audio_rate = types.audio_rate;

/// The pictures and sound of a source, delivered to callbacks on threads
/// of their own: addVideo(node, ...), addAudio(which, ...), failed(),
/// videoFrames(), close().
pub const Stream = pwstream.Capture;

/// An opened source: `cap` and its video `node`, the stream's logical
/// rectangle and the part to keep; label(), close().
pub const Source = source.Source;
pub const Opened = source.Opened;

/// Open the source for `want` (asking for consent where needed; the
/// restore token is kept in `cfg`).
pub const open = source.open;

/// The shell shows its own stop button for recordings (GNOME's top bar),
/// so no floating control is needed in the picture.
pub fn shellHasControls(_: std.mem.Allocator, bus: *dbus.Connection) bool {
    return gnome.isGnome() and shell1.supports(bus, .recording);
}

/// Put the area picker up in the shell (it captures and starts `shotlet
/// --from-shell ... --then record`); true when it did.
pub fn pickInShell(gpa: std.mem.Allocator, bus: *dbus.Connection) bool {
    if (!shellHasControls(gpa, bus)) return false;
    if (shell1.recordSelect(bus)) {
        log.info("the picker is up through the GNOME integration", .{});
        return true;
    } else |err| log.info("GNOME integration: {t}", .{err});
    return false;
}

/// Listen for the shell's stop requests (its stop button, the record
/// shortcut again).
pub fn watchStop(bus: *dbus.Connection) !void {
    return shell1.watchStop(bus);
}

/// What the session sent since the last call, without waiting: true when
/// it asked to stop.
pub fn pollStop(bus: *dbus.Connection, _: std.mem.Allocator) bool {
    var stop = false;
    bus.drain(16, &stop, struct {
        fn f(seen: *bool, msg: *const dbus.Message) bool {
            if (shell1.isStopRequest(msg)) seen.* = true;
            return false;
        }
    }.f);
    return stop;
}

comptime {
    _ = source;
    _ = pwstream;
}
