//! The backend's development commands (`shotlet test-window` ...), as
//! parsed (src/cli/cmds_internal.zig has their words).

pub const DevCommand = union(enum) {
    /// `test-window`: a test window for a few seconds
    window,
    /// `test-grab`: every monitor through the portal, to a PNG
    grab,
    /// `test-font [LINES [OUT.png [FONT.ttf]]]`: text rendered to a PNG
    font: struct {
        /// the lines, separated by `|` (null: a fixed sample)
        lines: ?[]const u8 = null,
        /// where the PNG goes (null: the runtime directory)
        out: ?[]const u8 = null,
        /// the font tried first
        font: ?[]const u8 = null,
    },
    /// `test-decode FILE`: a PNG decoded and written back
    decode: []const u8,
};
