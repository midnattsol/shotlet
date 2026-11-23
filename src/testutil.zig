//! Helpers for unit tests, shared by every module: private temporary
//! directories (and a temporary $HOME), the process environment for
//! spawning programs, synthetic images, the system fonts tests use, and
//! a few expectations. Everything allocates with std.testing.allocator.
//!
//! A missing optional resource (a program, a font) skips the test with
//! error.SkipZigTest; it never passes silently. Helpers only one folder
//! needs live in that folder's testutil.zig (gfx/png, gfx/bidi).
//!
//! Test registration: src/main.zig's `test {}` is the one test root. See
//! the comment there.

const std = @import("std");
const testing = std.testing;
const api = @import("platform/api.zig");
const sys = api.sys;
const proc = api.proc;
const env = @import("app/env.zig");
const png = @import("gfx/png.zig");
const ttf = @import("gfx/ttf.zig");

// --- directories ---

/// A fresh private directory `<TMPDIR or /tmp>/<prefix>-<random>`,
/// removed with everything in it by deinit.
pub const TmpDir = struct {
    path: []u8,
    /// env.xdg before home() cleared it, restored by deinit
    saved_xdg: ?env.Xdg = null,

    pub fn init(prefix: []const u8) !TmpDir {
        return .{ .path = try sys.makeTempDir(testing.allocator, tmpBase(), prefix) };
    }

    /// A temporary $HOME: also clears env.xdg (no XDG_* overrides, so
    /// every path derives from the directory) until deinit.
    pub fn home() !TmpDir {
        var t = try init("shotlet-home");
        t.saved_xdg = useXdg(.{}).saved;
        return t;
    }

    pub fn deinit(t: *TmpDir) void {
        if (t.saved_xdg) |x| env.xdg = x;
        sys.removeTree(t.path);
        testing.allocator.free(t.path);
        t.* = undefined;
    }

    /// `<dir>/<rel>`, in `buf`.
    pub fn join(t: *const TmpDir, buf: []u8, rel: []const u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ t.path, rel });
    }

    /// `<dir>/<rel>`, NUL-terminated and owned (testing.allocator).
    pub fn joinZ(t: *const TmpDir, rel: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ t.path, rel }, 0);
    }

    /// Write `<dir>/<rel>`, creating its parent directories.
    pub fn write(t: *const TmpDir, rel: []const u8, data: []const u8) !void {
        var buf: [1024]u8 = undefined;
        const p = try t.join(&buf, rel);
        sys.mkdirAll(std.fs.path.dirname(p).?, 0o700);
        try sys.writeFile(p, data);
    }

    /// `<dir>/<rel>`'s contents (owned, testing.allocator).
    pub fn read(t: *const TmpDir, rel: []const u8) ![]u8 {
        var buf: [1024]u8 = undefined;
        return sys.readFileAlloc(testing.allocator, try t.join(&buf, rel), 16 * 1024 * 1024);
    }
};

/// $TMPDIR when it is an absolute path, else /tmp. Tests run without
/// main, so they read it themselves.
fn tmpBase() []const u8 {
    const v = std.c.getenv("TMPDIR") orelse return "/tmp";
    return env.absolute(std.mem.span(v)) orelse "/tmp";
}

/// env.xdg replaced for one test:
/// `const xdg = testutil.useXdg(.{ .config_home = dir }); defer xdg.restore();`
pub fn useXdg(x: env.Xdg) SavedXdg {
    const saved: SavedXdg = .{ .saved = env.xdg };
    env.xdg = x;
    return saved;
}

pub const SavedXdg = struct {
    saved: env.Xdg,

    pub fn restore(s: SavedXdg) void {
        env.xdg = s.saved;
    }
};

// --- programs ---

/// This process's environment, for spawning programs in tests.
pub fn envp() proc.Envp {
    return @ptrCast(std.c.environ);
}

/// The program `name` on $PATH, in `buf`; skips the test when it is not
/// installed.
pub fn program(buf: []u8, name: []const u8) ![:0]const u8 {
    return proc.which(buf, envp(), name) orelse error.SkipZigTest;
}

/// Whether `name` is on $PATH.
pub fn hasProgram(name: []const u8) bool {
    var buf: [256]u8 = undefined;
    return proc.which(&buf, envp(), name) != null;
}

// --- images ---

/// Fill `px` (rows of `w`) like a screenshot: flat areas, gradients and
/// noise, the same for the same `seed`.
pub fn screenLike(px: []u32, w: u32, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    for (px, 0..) |*p, i| {
        const x: u32 = @intCast(i % w);
        const y: u32 = @intCast(i / w);
        p.* = if ((x / 7 + y / 5) % 3 == 0)
            0xFF000000 | ((x * 8 & 0xFF) << 16) | ((y * 13 & 0xFF) << 8) | @as(u32, @intCast(i % 251))
        else if (r.intRangeAtMost(u8, 0, 9) == 0)
            0xFF000000 | @as(u32, r.int(u24))
        else
            0xFF202428;
    }
}

/// Fill `px` with opaque pixels that all differ (up to 2^24 of them), so
/// a pixel that moved shows.
pub fn distinct(px: []u32) void {
    for (px, 0..) |*p, i| p.* = 0xFF000000 | @as(u32, @intCast(i & 0xFFFFFF));
}

/// Fill `px` (rows of `w`) with a 1 px black and white checkerboard,
/// white at the origin.
pub fn checker(px: []u32, w: u32) void {
    for (px, 0..) |*p, i| p.* = if (((i % w) + (i / w)) % 2 == 0) 0xFFFFFFFF else 0xFF000000;
}

/// A w x h image of one colour (owned, testing.allocator).
pub fn solidImage(w: u32, h: u32, argb: u32) !png.Image {
    const px = try testing.allocator.alloc(u32, @as(usize, w) * h);
    @memset(px, argb);
    return .{ .width = w, .height = h, .pixels = px };
}

// --- system fonts ---

/// The system fonts tests use (Debian/Ubuntu paths; tests skip the ones
/// that are not installed).
pub const fonts = struct {
    pub const dejavu_sans = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
    pub const nimbus_sans = "/usr/share/fonts/opentype/urw-base35/NimbusSans-Regular.otf";
    pub const standard_symbols = "/usr/share/fonts/opentype/urw-base35/StandardSymbolsPS.otf";
    pub const dingbats = "/usr/share/fonts/opentype/urw-base35/D050000L.otf";
    /// a collection (.ttc), CFF outlines
    pub const noto_cjk = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
    pub const noto_arabic = "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf";
    pub const noto_hebrew = "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf";
    pub const noto_nastaliq = "/usr/share/fonts/truetype/noto/NotoNastaliqUrdu-Regular.ttf";
    pub const noto_syriac = "/usr/share/fonts/truetype/noto/NotoSansSyriac-Regular.ttf";
    pub const noto_coptic = "/usr/share/fonts/truetype/noto/NotoSansCoptic-Regular.ttf";
    pub const noto_lycian = "/usr/share/fonts/truetype/noto/NotoSansLycian-Regular.ttf";
};

/// Face 0 of the system font at `path`; skips the test when it is not
/// installed (a font that is there but does not load fails it).
pub fn systemFont(path: []const u8) !ttf.Font {
    return systemFace(path, 0);
}

/// Face `index` of a system font (a .ttc); skips like systemFont.
pub fn systemFace(path: []const u8, index: u32) !ttf.Font {
    if (!installed(path)) return error.SkipZigTest;
    return ttf.Font.loadFace(testing.allocator, path, index);
}

/// The system font at `path`, or null when it is not installed (for
/// tests that try several).
pub fn optionalFont(path: []const u8) !?ttf.Font {
    if (!installed(path)) return null;
    return try ttf.Font.load(testing.allocator, path);
}

/// A system file's bytes (owned, up to `max`), or null when it is not
/// there: fuzz seeds and samples the test can do without.
pub fn optionalFile(path: []const u8, max: usize) !?[]u8 {
    if (!installed(path)) return null;
    return try sys.readFileAlloc(testing.allocator, path, max);
}

fn installed(path: []const u8) bool {
    _ = sys.fileSize(path) catch return false;
    return true;
}

// --- expectations ---

/// `haystack` contains `needle` (printed when it does not).
pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("missing: \"{s}\"\nin: \"{s}\"\n", .{ needle, haystack });
    return error.TestExpectedContains;
}

/// `haystack` does not contain `needle`.
pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return;
    std.debug.print("unexpected: \"{s}\"\nin: \"{s}\"\n", .{ needle, haystack });
    return error.TestUnexpectedContains;
}

test "a temporary directory holds files and goes away" {
    var t = try TmpDir.init("shotlet-testutil");
    const path = try testing.allocator.dupe(u8, t.path);
    defer testing.allocator.free(path);
    try t.write("a/b/c.txt", "hi");
    const data = try t.read("a/b/c.txt");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hi", data);
    try testing.expect(std.mem.startsWith(u8, path, tmpBase()));
    t.deinit();
    try testing.expectError(error.NotFound, sys.fileSize(path));
}

test "a temporary home clears the XDG overrides until deinit" {
    const outer = useXdg(.{ .config_home = "/elsewhere" });
    defer outer.restore();
    var h = try TmpDir.home();
    try testing.expectEqual(@as(?[]const u8, null), env.xdg.config_home);
    h.deinit();
    try testing.expectEqualStrings("/elsewhere", env.xdg.config_home.?);
}

test "images and expectations" {
    var px: [4]u32 = undefined;
    checker(&px, 2);
    try testing.expectEqualSlices(u32, &.{ 0xFFFFFFFF, 0xFF000000, 0xFF000000, 0xFFFFFFFF }, &px);
    distinct(&px);
    try testing.expect(px[0] != px[1] and px[2] != px[3]);
    var img = try solidImage(3, 2, 0xFF112233);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), img.pixels.len);
    try expectContains("shotlet record", "record");
    try expectNotContains("shotlet record", "pin");
}
