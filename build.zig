const std = @import("std");
const version = @import("tools/version.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version_mod = versionModule(b);
    const platform = platformOptions(b, false);

    const exe = b.addExecutable(.{ .name = "shotlet", .root_module = appModule(b, target, optimize, platform, version_mod) });
    b.installArtifact(exe);
    addManPage(b, exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run shotlet").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const tests = b.addTest(.{ .root_module = appModule(b, target, optimize, platform, version_mod) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const version_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/version.zig"),
        .target = b.graph.host,
    }) });
    test_step.dependOn(&b.addRunArtifact(version_tests).step);
    addGuards(b, test_step);
    addPortableCheck(b, version_mod, test_step);
    addE2e(b, target, optimize, platform, exe, test_step);
}

/// The program's root module (src/main.zig) for `target`, with what it
/// imports: the GNOME Shell extension, the version and the platform
/// option. libc is needed only for dlopen (libpipewire and friends);
/// everything else talks wire protocols directly.
fn appModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, platform: *std.Build.Module, version_mod: *std.Build.Module) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addGnomeExtension(b, m);
    m.addImport("version", version_mod);
    m.addImport("platform_options", platform);
    return m;
}

/// The end-to-end suites and their helpers. The GNOME suite drives
/// shotlet with a virtual keyboard and pointer in a private headless
/// GNOME session (tools/e2e.sh skips without one); the container suite
/// does the same on wlroots (sway, labwc) and KWin, each scenario in a
/// throwaway container (tools/container/run.sh skips without docker or
/// podman). The helpers are compiled and unit-tested with `test`, so they
/// cannot rot unnoticed.
fn addE2e(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, platform: *std.Build.Module, exe: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    const kit = e2eModule(b, target, optimize, platform);
    const common = b.createModule(.{
        .root_source_file = b.path("tools/drivers/common/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "shotlet", .module = kit }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "driver-common-test", .root_module = common })).step);
    const drive = addDriver(b, "shotlet-drive", "tools/e2e/drive.zig", kit, common, test_step);
    const droptarget = addDriver(b, "shotlet-droptarget", "tools/e2e/droptarget.zig", kit, common, test_step);
    const wldrive = addDriver(b, "shotlet-wldrive", "tools/container/wldrive.zig", kit, common, test_step);

    const run_e2e = addScript(b, "tools/e2e.sh");
    run_e2e.addArg("--bins");
    run_e2e.addArtifactArg(exe);
    run_e2e.addArtifactArg(drive);
    run_e2e.addArtifactArg(droptarget);
    run_e2e.addPassthruArgs();
    b.step("e2e", "Run the end-to-end suite (private headless GNOME session)").dependOn(&run_e2e.step);

    const run_ctr = addScript(b, "tools/container/run.sh");
    run_ctr.addArg("--bins");
    run_ctr.addArtifactArg(exe);
    run_ctr.addArtifactArg(wldrive);
    run_ctr.addArtifactArg(droptarget);
    run_ctr.addPassthruArgs();
    b.step("e2e-container", "Run the end-to-end suite on sway, labwc and KWin in containers").dependOn(&run_ctr.step);

    const helpers = b.step("e2e-driver", "Install the e2e helpers (zig-out/bin/shotlet-drive, shotlet-wldrive, shotlet-droptarget)");
    for ([_]*std.Build.Step.Compile{ drive, droptarget, wldrive }) |c| helpers.dependOn(&b.addInstallArtifact(c, .{}).step);
}

/// An e2e helper executable importing "shotlet" (src/e2e_module.zig) and
/// "driver_common" (tools/drivers/common), built and unit-tested by
/// `test`.
fn addDriver(b: *std.Build, name: []const u8, path: []const u8, kit: *std.Build.Module, common: *std.Build.Module, test_step: *std.Build.Step) *std.Build.Step.Compile {
    const c = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = kit.resolved_target,
            .optimize = kit.optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "shotlet", .module = kit },
                .{ .name = "driver_common", .module = common },
            },
        }),
    });
    test_step.dependOn(&c.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = b.fmt("{s}-test", .{name}), .root_module = c.root_module })).step);
    return c;
}

/// A repository script run as a build step, from the repository root
/// (it may change things outside the cache, so it always runs).
fn addScript(b: *std.Build, path: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{path});
    run.setName(std.fs.path.basename(path));
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// The "version" module (tools/version.zig's `string`): `-Dversion` for a
/// release, else `git describe`'s, else build.zig.zon's.
fn versionModule(b: *std.Build) *std.Build.Module {
    const zon = @import("build.zig.zon").version;
    const options = b.addOptions();
    options.addOption([]const u8, "zon", zon);
    options.addOption([]const u8, "release", releaseVersion(b, zon));
    // at make time, every build: the configure phase is cached across commits
    const git = b.addSystemCommand(&.{
        "sh", "-c", "git describe --tags --long --dirty --match 'v[0-9]*' 2>/dev/null || true",
    });
    git.setName("git describe");
    git.setCwd(b.path("."));
    git.has_side_effects = true;
    const m = b.createModule(.{ .root_source_file = b.path("tools/version.zig") });
    m.addOptions("build_options", options);
    m.addAnonymousImport("git_describe", .{ .root_source_file = git.captureStdOut(.{}) });
    return m;
}

/// `-Dversion`, checked against build.zig.zon's; "" when not given.
fn releaseVersion(b: *std.Build, zon: []const u8) []const u8 {
    const tag = b.option([]const u8, "version", "Release version (the tag, e.g. 0.1.7); default: from git describe") orelse return "";
    return version.release(tag, zon) catch |err| switch (err) {
        error.OlderThanZon => std.process.fatal("-Dversion={s} is older than build.zig.zon's {s}", .{ tag, zon }),
        else => std.process.fatal("-Dversion={s} is not a version like 0.1.7", .{tag}),
    };
}

/// The platform layer's build option: `stub` selects the compile-only
/// backend (src/platform/stub) instead of the target OS's.
fn platformOptions(b: *std.Build, stub: bool) *std.Build.Module {
    const o = b.addOptions();
    o.addOption(bool, "stub", stub);
    return o.createModule();
}

/// The module the e2e drivers import as "shotlet" (src/e2e_module.zig).
fn e2eModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, platform: *std.Build.Module) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/e2e_module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addImport("platform_options", platform);
    return m;
}

/// `zig build check-portable`: the whole program and its tests, built
/// against the stub backend for Windows and macOS (semantic analysis
/// only, nothing is emitted), proving everything outside
/// src/platform/linux is free of Linux.
fn addPortableCheck(b: *std.Build, version_mod: *std.Build.Module, test_step: *std.Build.Step) void {
    const step = b.step("check-portable", "Compile the portable core for Windows and macOS against the stub backend");
    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };
    for (targets) |q| {
        const target = b.resolveTargetQuery(q);
        inline for (.{ "exe", "test" }) |kind| {
            const m = appModule(b, target, .Debug, platformOptions(b, true), version_mod);
            const c = if (comptime std.mem.eql(u8, kind, "exe"))
                b.addExecutable(.{ .name = "shotlet-portable", .root_module = m })
            else
                b.addTest(.{ .name = "shotlet-portable-test", .root_module = m });
            // nothing depends on the binary: analysis only (-fno-emit-bin)
            step.dependOn(&c.step);
        }
    }
    test_step.dependOn(step);
}

/// `zig build man`: shotlet(1), which `shotlet man-page` writes from the
/// command table, in zig-out/share/man/man1.
fn addManPage(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const gen = b.addRunArtifact(exe);
    gen.addArg("man-page");
    const page = gen.captureStdOut(.{});
    const install = b.addInstallFileWithDir(page, .{ .custom = "share/man/man1" }, "shotlet.1");
    b.step("man", "Generate the man page (zig-out/share/man/man1/shotlet.1)").dependOn(&install.step);
}

/// The GNOME Shell extension ships inside the binary, for
/// `shotlet gnome-integration install`.
fn addGnomeExtension(b: *std.Build, m: *std.Build.Module) void {
    const dir = "gnome-extension/shotlet@midnattsol.github.io/";
    m.addAnonymousImport("gnome_ext_js", .{ .root_source_file = b.path(dir ++ "extension.js") });
    m.addAnonymousImport("gnome_ext_recorder_js", .{ .root_source_file = b.path(dir ++ "recorder.js") });
    m.addAnonymousImport("gnome_ext_windows_js", .{ .root_source_file = b.path(dir ++ "windows.js") });
    m.addAnonymousImport("gnome_ext_metadata", .{ .root_source_file = b.path(dir ++ "metadata.json") });
    // the capture modes' modules (imported by extension.js)
    for ([_][]const u8{ "modes", "windowpick", "scroll", "util" }) |name| {
        m.addAnonymousImport(b.fmt("gnome_ext_{s}_js", .{name}), .{ .root_source_file = b.path(b.fmt("{s}{s}.js", .{ dir, name })) });
    }
    m.addAnonymousImport("gnome_ext_schema", .{ .root_source_file = b.path(dir ++ "schemas/org.gnome.shell.extensions.shotlet.gschema.xml") });
    // compiled with glib-compile-schemas and committed: the extension
    // directory is copied as is (GNOME Shell does not compile schemas)
    m.addAnonymousImport("gnome_ext_schema_compiled", .{ .root_source_file = b.path(dir ++ "schemas/gschemas.compiled") });
}

/// The source guards, all run by `test` but `long-fns`: `check-size`
/// fails when a source file outgrows the line limit (files still over it
/// are allowlisted in tools/size-allowlist.txt and may only shrink);
/// `check-layers` when a file outside the backend reaches into it;
/// `check-tests` when a file's tests are not reached from the test root
/// (src/main.zig's `test {}`, through the folders' roots);
/// `long-fns` lists overlong functions. The limits and the files checked
/// are tools/sources.sh's.
fn addGuards(b: *std.Build, test_step: *std.Build.Step) void {
    const size = addScript(b, "tools/check-size.sh");
    b.step("check-size", b.fmt("Fail when a source file grows past {d} lines", .{sourcesLimit("size_limit")})).dependOn(&size.step);
    test_step.dependOn(&size.step);

    const layers = addScript(b, "tools/check-layers.sh");
    b.step("check-layers", "Fail when a file outside src/platform/linux imports it or names Wayland, D-Bus, keysyms, evdev or GTK accelerators").dependOn(&layers.step);
    test_step.dependOn(&layers.step);

    const tests = addScript(b, "tools/check-tests.sh");
    b.step("check-tests", "Fail when a source file has tests the test root does not reach, or a test {} block outside src/main.zig").dependOn(&tests.step);
    test_step.dependOn(&tests.step);

    const fns = addScript(b, "tools/long-fns.sh");
    fns.addPassthruArgs();
    b.step("long-fns", b.fmt("List functions longer than {d} lines (a report, never fails; -- N for another limit)", .{sourcesLimit("fn_limit")})).dependOn(&fns.step);
}

/// A limit set in tools/sources.sh (`NAME=N`), the one place for them.
fn sourcesLimit(comptime name: []const u8) u32 {
    var lines = std.mem.splitScalar(u8, @embedFile("tools/sources.sh"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, name ++ "=")) return std.fmt.parseInt(u32, line[name.len + 1 ..], 10) catch break;
    }
    @panic("tools/sources.sh: no " ++ name ++ "=N");
}
