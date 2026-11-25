//! Where the config file lives.

const std = @import("std");

/// The config file in the config directory `dir`.
pub fn configFile(dir: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/config", .{dir});
}
