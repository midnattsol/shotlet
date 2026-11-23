//! TODO(wave 2): remove. record/source.zig still names this module;
//! recording through the extension lives in shell1.zig.

const std = @import("std");
const dbus = @import("../dbus.zig");
const shell1 = @import("shell1.zig");

pub const Options = shell1.RecordOptions;

pub fn available(_: std.mem.Allocator, bus: *dbus.Connection) bool {
    return shell1.supports(bus, .recording);
}

pub fn start(_: std.mem.Allocator, bus: *dbus.Connection, o: Options) !u32 {
    return shell1.startRecording(bus, o);
}

pub const stop = shell1.stopRecording;
