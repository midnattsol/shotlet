//! Font discovery. Asks fontconfig (dlopened, optional) for the user's
//! sans-serif / bold / monospace faces and for a face covering a given
//! codepoint; without fontconfig, scans the standard font directories and
//! picks well-known families by file name. Returned paths are owned by the
//! caller (free with the same allocator).

const std = @import("std");
const log = std.log.scoped(.fonts);
const sys = @import("sys.zig");
const env_mod = @import("../../app/env.zig");
const optlib = @import("../../optlib.zig");

const types = @import("../api/fonts.zig");
pub const Query = types.Query;
pub const Face = types.Face;

// --- fontconfig (optional, dlopen) ---

const FcPattern = opaque {};
const FcCharSet = opaque {};
const FcResultMatch: c_int = 0;
const FcMatchPattern: c_int = 0;

const FcApi = struct {
    FcInit: *const fn () callconv(.c) c_int,
    FcNameParse: *const fn ([*:0]const u8) callconv(.c) ?*FcPattern,
    FcConfigSubstitute: *const fn (?*anyopaque, *FcPattern, c_int) callconv(.c) c_int,
    FcDefaultSubstitute: *const fn (*FcPattern) callconv(.c) void,
    FcFontMatch: *const fn (?*anyopaque, *FcPattern, *c_int) callconv(.c) ?*FcPattern,
    FcPatternGetString: *const fn (*FcPattern, [*:0]const u8, c_int, *?[*:0]const u8) callconv(.c) c_int,
    FcPatternGetInteger: *const fn (*FcPattern, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
    FcPatternGetCharSet: *const fn (*FcPattern, [*:0]const u8, c_int, *?*FcCharSet) callconv(.c) c_int,
    FcPatternAddCharSet: *const fn (*FcPattern, [*:0]const u8, *FcCharSet) callconv(.c) c_int,
    FcPatternDestroy: *const fn (*FcPattern) callconv(.c) void,
    FcCharSetCreate: *const fn () callconv(.c) ?*FcCharSet,
    FcCharSetAddChar: *const fn (*FcCharSet, u32) callconv(.c) c_int,
    FcCharSetHasChar: *const fn (*FcCharSet, u32) callconv(.c) c_int,
    FcCharSetDestroy: *const fn (*FcCharSet) callconv(.c) void,
};

const Fc = struct {
    lib: optlib.Table(FcApi),

    fn open() ?Fc {
        var why: []const u8 = "";
        var t = optlib.bind(FcApi, "fontconfig", &.{"1"}, &why) catch return null;
        if (t.api.FcInit() == 0) {
            t.close();
            return null;
        }
        return .{ .lib = t };
    }

    /// Best match for a fontconfig pattern string; when `cp` is set, only a
    /// face whose charset really contains it.
    fn match(self: *Fc, gpa: std.mem.Allocator, pattern: [*:0]const u8, cp: ?u21) ?Face {
        const a = &self.lib.api;
        const pat = a.FcNameParse(pattern) orelse return null;
        defer a.FcPatternDestroy(pat);
        if (cp) |c| {
            const cs = a.FcCharSetCreate() orelse return null;
            defer a.FcCharSetDestroy(cs);
            _ = a.FcCharSetAddChar(cs, c);
            if (a.FcPatternAddCharSet(pat, "charset", cs) == 0) return null;
        }
        _ = a.FcConfigSubstitute(null, pat, FcMatchPattern);
        a.FcDefaultSubstitute(pat);
        var result: c_int = 0;
        const m = a.FcFontMatch(null, pat, &result) orelse return null;
        defer a.FcPatternDestroy(m);
        if (cp) |c| {
            var cs: ?*FcCharSet = null;
            if (a.FcPatternGetCharSet(m, "charset", 0, &cs) != FcResultMatch) return null;
            if (a.FcCharSetHasChar(cs.?, c) == 0) return null;
        }
        var file: ?[*:0]const u8 = null;
        if (a.FcPatternGetString(m, "file", 0, &file) != FcResultMatch) return null;
        var index: c_int = 0;
        _ = a.FcPatternGetInteger(m, "index", 0, &index);
        const path = gpa.dupe(u8, std.mem.span(file.?)) catch return null;
        // variable-font named instances encode the instance in the high bits
        return .{ .path = path, .index = @intCast(@as(u32, @bitCast(index)) & 0xFFFF) };
    }
};

// --- directory scan fallback ---

const sans_names = [_][]const u8{
    "Inter-Regular.ttf", "Inter-Regular.otf",          "NotoSans-Regular.ttf",
    "DejaVuSans.ttf",    "LiberationSans-Regular.ttf", "Cantarell-Regular.otf",
    "Ubuntu-R.ttf",      "Roboto-Regular.ttf",         "OpenSans-Regular.ttf",
    "Arimo-Regular.ttf", "SourceSans3-Regular.otf",    "FreeSans.ttf",
    "Lato-Regular.ttf",  "NotoSans[wght].ttf",         "Vera.ttf",
};
const bold_names = [_][]const u8{
    "Inter-Bold.ttf",      "Inter-Bold.otf",          "NotoSans-Bold.ttf",
    "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "Cantarell-Bold.otf",
    "Ubuntu-B.ttf",        "Roboto-Bold.ttf",         "OpenSans-Bold.ttf",
    "Arimo-Bold.ttf",      "SourceSans3-Bold.otf",    "FreeSansBold.ttf",
    "Lato-Bold.ttf",       "VeraBd.ttf",
};
const medium_names = [_][]const u8{
    "Inter-Medium.ttf", "Inter-Medium.otf",       "NotoSans-Medium.ttf",
    "Ubuntu-M.ttf",     "Roboto-Medium.ttf",      "OpenSans-Medium.ttf",
    "Arimo-Medium.ttf", "SourceSans3-Medium.otf", "Lato-Medium.ttf",
};
const semibold_names = [_][]const u8{
    "Inter-SemiBold.ttf",    "Inter-SemiBold.otf", "NotoSans-SemiBold.ttf",
    "OpenSans-SemiBold.ttf", "Arimo-SemiBold.ttf", "SourceSans3-Semibold.otf",
    "Lato-Semibold.ttf",
};
const mono_names = [_][]const u8{
    "DejaVuSansMono.ttf",        "NotoSansMono-Regular.ttf", "LiberationMono-Regular.ttf",
    "UbuntuMono-R.ttf",          "Hack-Regular.ttf",         "JetBrainsMono-Regular.ttf",
    "SourceCodePro-Regular.otf", "FiraMono-Regular.ttf",     "Cousine-Regular.ttf",
    "FreeMono.ttf",              "VeraMono.ttf",
};
/// Wide-coverage faces tried in order for codepoints the UI font lacks.
const fallback_names = [_][]const u8{
    "DejaVuSans.ttf",               "NotoSans-Regular.ttf",        "LiberationSans-Regular.ttf",
    "NotoSansCJK-Regular.ttc",      "NotoSansCJKsc-Regular.otf",   "NotoSansCJKjp-Regular.otf",
    "SourceHanSans-Regular.ttc",    "wqy-microhei.ttc",            "wqy-zenhei.ttc",
    "DroidSansFallbackFull.ttf",    "DroidSansFallback.ttf",       "VL-Gothic-Regular.ttf",
    "NotoSansSymbols2-Regular.ttf", "NotoSansSymbols-Regular.ttf", "NotoSansMath-Regular.ttf",
    "NotoSansArabic-Regular.ttf",   "NotoSansHebrew-Regular.ttf",  "NotoSansDevanagari-Regular.ttf",
    "NotoSansThai-Regular.ttf",     "FreeSerif.ttf",               "FreeSans.ttf",
    "Symbola.ttf",                  "unifont.otf",                 "unifont.ttf",
};

fn isFontFile(name: []const u8) bool {
    const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".TTF", ".OTF", ".TTC" };
    for (exts) |e| if (std.mem.endsWith(u8, name, e)) return true;
    return false;
}

/// Recursively collect font file paths under `dir` (bounded depth/count).
fn scanDir(gpa: std.mem.Allocator, out: *std.ArrayList([]u8), dir: []const u8, depth: u8) void {
    if (depth > 8 or out.items.len > 50_000) return;
    const Scan = struct {
        alloc: std.mem.Allocator,
        out: *std.ArrayList([]u8),
        dir: []const u8,
        depth: u8,

        fn visit(self: *const @This(), name: []const u8, kind: sys.EntryKind) void {
            if (name.len == 0 or name[0] == '.') return;
            const font = isFontFile(name);
            // a link or an entry of unknown kind may be a directory
            const descend = kind == .dir or ((kind == .symlink or kind == .other) and !font);
            if (!descend and !font) return;
            const child = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.dir, name }) catch return;
            if (descend) {
                defer self.alloc.free(child);
                scanDir(self.alloc, self.out, child, self.depth + 1);
            } else self.out.append(self.alloc, child) catch self.alloc.free(child);
        }
    };
    const scan: Scan = .{ .alloc = gpa, .out = out, .dir = dir, .depth = depth };
    sys.eachEntry(dir, &scan, Scan.visit) catch {};
}

pub const Db = struct {
    alloc: std.mem.Allocator,
    fc: ?Fc = null,
    fc_tried: bool = false,
    files: ?std.ArrayList([]u8) = null,

    pub fn init(gpa: std.mem.Allocator) Db {
        return .{ .alloc = gpa };
    }

    pub fn deinit(self: *Db) void {
        if (self.fc) |*f| f.lib.close();
        if (self.files) |*l| {
            for (l.items) |p| self.alloc.free(p);
            l.deinit(self.alloc);
        }
        self.* = undefined;
    }

    fn fontconfig(self: *Db) ?*Fc {
        if (!self.fc_tried) {
            self.fc_tried = true;
            self.fc = Fc.open();
            if (self.fc == null) log.info("fontconfig unavailable; scanning font directories", .{});
        }
        return if (self.fc) |*f| f else null;
    }

    /// All font files under the standard directories (scanned once).
    pub fn fontFiles(self: *Db) []const []u8 {
        if (self.files == null) {
            var list: std.ArrayList([]u8) = .empty;
            const roots = [_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" };
            for (roots) |r| scanDir(self.alloc, &list, r, 0);
            // the user's own: $XDG_DATA_HOME/fonts (~/.local/share/fonts), ~/.fonts
            if (env_mod.xdg.home) |home| {
                var buf: env_mod.PathBuf = undefined;
                if (env_mod.dataHome(&buf, home)) |data| {
                    if (std.fmt.allocPrint(self.alloc, "{s}/fonts", .{data})) |p| {
                        scanDir(self.alloc, &list, p, 0);
                        self.alloc.free(p);
                    } else |_| {}
                } else |_| {}
                if (std.fmt.allocPrint(self.alloc, "{s}/.fonts", .{home})) |p| {
                    scanDir(self.alloc, &list, p, 0);
                    self.alloc.free(p);
                } else |_| {}
            }
            self.files = list;
        }
        return self.files.?.items;
    }

    /// Path of the first scanned file whose base name equals `name`.
    fn findFile(self: *Db, name: []const u8) ?[]const u8 {
        for (self.fontFiles()) |p| {
            if (std.mem.eql(u8, std.fs.path.basename(p), name)) return p;
        }
        return null;
    }

    /// The UI faces, best first; fontconfig falls back to the user's
    /// sans-serif when none is installed. (Not Cantarell: distributions
    /// ship it as a CFF2 variable font, which the loader cannot read, and
    /// failing over from it costs a third of a second at startup.)
    const ui_families = "Inter,SF Pro Text,SF Pro Display,Adwaita Sans,Noto Sans,sans-serif";

    /// The preferred UI face for `q` (fontconfig), else the first
    /// well-known family found on disk.
    pub fn match(self: *Db, q: Query) ?Face {
        if (self.fontconfig()) |fc| {
            const pat: [*:0]const u8 = switch (q) {
                .sans => ui_families,
                .sans_medium => ui_families ++ ":medium",
                .sans_semibold => ui_families ++ ":semibold",
                .sans_bold => ui_families ++ ":bold",
                .mono => "monospace",
            };
            if (fc.match(self.alloc, pat, null)) |f| return f;
        }
        return self.scanMatch(q, 0);
    }

    /// The `skip`-th well-known face for `q` found on disk (so a caller
    /// whose first pick fails to load can ask for the next one).
    pub fn scanMatch(self: *Db, q: Query, skip: usize) ?Face {
        const names: []const []const u8 = switch (q) {
            .sans => &sans_names,
            .sans_medium => &medium_names,
            .sans_semibold => &semibold_names,
            .sans_bold => &bold_names,
            .mono => &mono_names,
        };
        var seen: usize = 0;
        for (names) |n| {
            const p = self.findFile(n) orelse continue;
            if (seen == skip) return .{ .path = self.alloc.dupe(u8, p) catch return null };
            seen += 1;
        }
        return null;
    }

    /// A face that covers `cp`, according to fontconfig. Null when
    /// fontconfig is unavailable or nothing covers it.
    pub fn forCodepoint(self: *Db, cp: u21) ?Face {
        const fc = self.fontconfig() orelse return null;
        return fc.match(self.alloc, "sans-serif", cp);
    }

    pub fn hasFontconfig(self: *Db) bool {
        return self.fontconfig() != null;
    }

    /// The `i`-th wide-coverage fallback face found on disk, or null when
    /// the list is exhausted.
    pub fn fallback(self: *Db, i: usize) ?Face {
        var seen: usize = 0;
        for (fallback_names) |n| {
            const p = self.findFile(n) orelse continue;
            if (seen == i) return .{ .path = self.alloc.dupe(u8, p) catch return null };
            seen += 1;
        }
        return null;
    }
};

test "font discovery finds something or nothing, without crashing" {
    const gpa = std.testing.allocator;
    var db = Db.init(gpa);
    defer db.deinit();
    inline for (@typeInfo(Query).@"enum".field_names) |name| {
        const q = @field(Query, name);
        if (db.match(q)) |f| {
            defer f.deinit(gpa);
            try std.testing.expect(f.path.len > 0);
        }
        if (db.scanMatch(q, 0)) |f| f.deinit(gpa);
    }
    if (db.forCodepoint(0x6F22)) |f| f.deinit(gpa);
    var i: usize = 0;
    while (db.fallback(i)) |f| : (i += 1) f.deinit(gpa);
}
