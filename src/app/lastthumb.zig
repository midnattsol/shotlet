//! `shotlet thumbnail`: the floating thumbnail of the last capture or
//! recording kept, again (from the history, or the thumbnail's cache
//! when the history is off), whatever the thumbnail setting says.

const std = @import("std");
const log = std.log.scoped(.thumbnail);
const config = @import("config.zig");
const env_mod = @import("env.zig");
const history = @import("history.zig");
const keep = @import("keep.zig");
const out = @import("../cli/out.zig");
const keepvid = @import("../record/keepvid.zig");
const Env = env_mod.Env;

pub fn run(gpa: std.mem.Allocator, env: Env) !void {
    const cfg = config.load(gpa, env.home);
    var root_buf: [1024]u8 = undefined;
    const root = try keep.rootFor(&cfg, env, &root_buf);
    const entries = try history.list(gpa, root);
    defer history.freeList(gpa, entries);
    if (entries.len == 0) out.fail(.failure, "no capture kept yet", .{});
    const id = entries[0].id.slice();
    log.info("{s} again", .{id});
    if (keepvid.read(gpa, root, id)) |v| {
        gpa.free(v.buf);
        return @import("../record/quickvid.zig").run(gpa, env, root, id);
    }
    return @import("quick.zig").run(gpa, env, root, id, null);
}
