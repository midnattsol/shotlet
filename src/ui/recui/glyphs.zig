//! The recorder's icons, now part of ui/icons.zig's catalogue (mic,
//! speaker, click, film, scissors, play, pause).
//! TODO(wave 2): remove; callers use icons.Icon and icons.draw/drawAt.

const icons = @import("../icons.zig");

pub const Glyph = icons.Icon;
pub const draw = icons.draw;
pub const drawCentered = icons.drawCentered;
