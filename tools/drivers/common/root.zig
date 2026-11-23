//! What the e2e helpers share (imported as "driver_common"): the input
//! drivers' command set and loop, key names, picture commands and colour
//! search, and the sandbox guard. Each driver keeps only its backend's
//! input and grab code.

pub const commands = @import("commands.zig");
pub const images = @import("images.zig");
pub const keys = @import("keys.zig");
pub const loop = @import("loop.zig");
pub const pixels = @import("pixels.zig");
pub const sandbox = @import("sandbox.zig");
pub const sni = @import("sni.zig");

test {
    _ = commands;
    _ = images;
    _ = keys;
    _ = loop;
    _ = pixels;
    _ = sandbox;
    _ = sni;
}
