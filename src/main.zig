const std = @import("std");
const capture = @import("platform/api.zig").capture;
const front = @import("cli/front.zig");
const out = @import("cli/out.zig");
const env_mod = @import("app/env.zig");
const Env = env_mod.Env;
const launch = @import("ui/tools/launch.zig");
const desktop = @import("platform/api.zig").desktop;
const proc = @import("platform/api.zig").proc;
const switches = @import("platform/api/switches.zig");

const is_debug = @import("builtin").mode == .debug;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // help, the version and mistyped command lines need no session
    const parsed = switch (try front.handle(arena, args, nonEmpty(init.environ_map.get("NO_COLOR")) != null)) {
        .run => |p| p,
        .exit => |code| std.process.exit(code),
    };

    // DebugAllocator catches leaks in Debug; smp_allocator is the fast
    // thread-safe choice for release builds
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (is_debug) gpa_state.allocator() else std.heap.smp_allocator;

    // the environment is read here, once: switches and XDG directories
    // for code handed no Env, then the Env everyone else gets
    switches.init(init.environ_map);
    env_mod.xdg = .read(init.environ_map);
    out.command = parsed.chain;
    const env = readEnv(arena, init) catch |err| switch (err) {
        error.NoRuntimeDir => out.fail(.failure, "XDG_RUNTIME_DIR is not set to an absolute path", .{}),
        error.NoHome => out.fail(.failure, "HOME is not set to an absolute path", .{}),
        else => out.failWith(err),
    };
    launch.env = env;
    try @import("app/dispatch.zig").run(gpa, env, parsed);
}

/// The process environment Shotlet needs, from the variables.
fn readEnv(arena: std.mem.Allocator, init: std.process.Init) !Env {
    const vars = init.environ_map;
    const runtime_dir = env_mod.absolute(vars.get("XDG_RUNTIME_DIR")) orelse return error.NoRuntimeDir;
    return .{
        .session = try desktop.addresses(arena, vars, runtime_dir),
        .runtime_dir = runtime_dir,
        .home = env_mod.absolute(vars.get("HOME")) orelse return error.NoHome,
        .envp = proc.processEnv(init.minimal.environ),
        .tz = vars.get("TZ"),
    };
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// The test root, the one `test {}` that reaches other files. Every folder
// has one root that reaches, in a `comptime {}` block (which, unlike
// `test {}`, does not count as a test), the files of the folder that
// have tests and the roots of its subfolders, nothing outside it. A
// folder's root is the file that fronts it (`gfx/text.zig` for gfx/text/,
// ui/tools/mod.zig, linux/backend.zig, platform/api.zig for platform/ and
// api/), else a `tests.zig` inside it. A file with tests kept apart
// reaches them itself (`material.zig` → material_test.zig). Shared test
// helpers: src/testutil.zig.
test {
    _ = @import("app/tests.zig");
    _ = @import("cli/tests.zig");
    _ = @import("encode/tests.zig");
    _ = @import("gfx/tests.zig");
    _ = @import("ocr/tests.zig");
    _ = @import("platform/api.zig");
    _ = @import("record/tests.zig");
    _ = @import("redact/tests.zig");
    _ = @import("ui/tests.zig");
    _ = @import("testutil.zig");
}
