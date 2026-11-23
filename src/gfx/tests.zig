//! Graphics' test root (src/main.zig): its files and its folders' roots.

comptime {
    _ = @import("bidi.zig");
    _ = @import("cff.zig");
    _ = @import("codec_libs.zig");
    _ = @import("color.zig");
    _ = @import("effects.zig");
    _ = @import("font.zig");
    _ = @import("hint.zig");
    _ = @import("imgload.zig");
    _ = @import("jpeg.zig");
    _ = @import("otl.zig");
    _ = @import("path.zig");
    _ = @import("png.zig");
    _ = @import("render.zig");
    _ = @import("resample.zig");
    _ = @import("text.zig");
    _ = @import("ttf.zig");
    _ = @import("utf8.zig");
    _ = @import("wrap.zig");
}
