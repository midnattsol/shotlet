//! Clipboard and drag payloads of the core: the text/uri-list of a file
//! (src/uri.zig has the URIs; the backend reads and offers the payloads
//! itself).

// TODO(wave 3b): remove this file; callers (record/files.zig,
// app/quick/actions.zig, record/quickvid.zig) use uri.fileUriList, and
// main.zig's test block drops its import.
pub const fileUriList = @import("../uri.zig").fileUriList;

test {
    _ = @import("../uri.zig");
}
