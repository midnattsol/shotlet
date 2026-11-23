//! Quick access runs once: a later capture hands its entry to the
//! running thumbnail process over its socket (app/ipc.zig),
//! $XDG_RUNTIME_DIR/shotlet-quick-<session>.sock:
//!
//!     add ROOT<tab>ID    ->  "ok" once its card shows

const std = @import("std");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const ipc = @import("ipc.zig");
const Env = env_mod.Env;

pub fn socketPath(buf: []u8, env: Env) ![]u8 {
    return ipc.sessionPath(buf, env.runtime_dir, env.session.tag(), "quick", ".sock");
}

/// Listen for hand-offs; error.AddressInUse when a running stack has
/// the socket (a stale one is taken over).
pub fn listen(env: Env) !ipc.Server {
    var buf: ipc.PathBuf = undefined;
    return ipc.Server.listen(try socketPath(&buf, env));
}

/// Hand an entry to a running quick-access process; false when none
/// answered.
pub fn handOff(env: Env, root: []const u8, id: []const u8) bool {
    var pbuf: ipc.PathBuf = undefined;
    const path = socketPath(&pbuf, env) catch return false;
    var lbuf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const line = std.fmt.bufPrint(&lbuf, "add {s}\t{s}", .{ root, id }) catch return false;
    var ans: [8]u8 = undefined;
    const a = ipc.request(path, line, &ans, 2000) orelse return false;
    return std.mem.startsWith(u8, a, "ok");
}

/// Parse "add ROOT\tID".
pub fn parseAdd(line: []const u8) ?struct { root: []const u8, id: []const u8 } {
    const l = std.mem.trimEnd(u8, line, "\r\n");
    if (!std.mem.startsWith(u8, l, "add ")) return null;
    const rest = l[4..];
    const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const root = rest[0..tab];
    const id = rest[tab + 1 ..];
    if (root.len == 0 or root[0] != '/' or !history.Id.valid(id)) return null;
    return .{ .root = root, .id = id };
}

test "hand-off lines are checked" {
    const a = parseAdd("add /home/u/.local/state/shotlet/history\t1763740953123-0a1b2c3d\n").?;
    try std.testing.expectEqualStrings("/home/u/.local/state/shotlet/history", a.root);
    try std.testing.expectEqualStrings("1763740953123-0a1b2c3d", a.id);
    try std.testing.expect(parseAdd("add relative\t1763740953123-0a1b2c3d") == null);
    try std.testing.expect(parseAdd("add /r\t../../x") == null);
    try std.testing.expect(parseAdd("del /r\t1763740953123-0a1b2c3d") == null);
    try std.testing.expect(parseAdd("add /r 1763740953123-0a1b2c3d") == null);
}
