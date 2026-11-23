//! Text recognition's test root (src/main.zig).

comptime {
    _ = @import("search.zig");
    _ = @import("page.zig");
    _ = @import("reflow.zig");
    _ = @import("tesseract.zig");
}
