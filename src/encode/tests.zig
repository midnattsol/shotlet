//! The encoders' test root (src/main.zig): every file of the folder.

comptime {
    _ = @import("quantize.zig");
    _ = @import("lzw.zig");
    _ = @import("gif.zig");
    _ = @import("gifdec.zig");
    _ = @import("yuv.zig");
    _ = @import("av.zig");
    _ = @import("av_mp4.zig");
    _ = @import("ffmpeg_proc.zig");
    _ = @import("sink.zig");
}
