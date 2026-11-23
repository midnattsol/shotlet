//! The command line's tests: the folder's test root (src/main.zig).

comptime {
    _ = @import("commands.zig");
    _ = @import("suggest.zig");
    _ = @import("value.zig");
    _ = @import("text.zig");
    _ = @import("errors.zig");
    _ = @import("out.zig");
    _ = @import("parse_test.zig");
    _ = @import("table_test.zig");
    _ = @import("help_test.zig");
    _ = @import("complete_test.zig");
}
