//! Reading the config file: key=value lines into a Config (keys.zig reads
//! each fixed key). Unknown keys and malformed values never fail; they
//! keep the default.

const std = @import("std");
const sys = @import("../../platform/api.zig").sys;
const binds = @import("../binds.zig");
const model = @import("model.zig");
const keys = @import("keys.zig");
const accel = @import("../accel.zig");
const Config = model.Config;
const Action = binds.Action;
const Bind = binds.Bind;

/// Apply every key=value line of the config file `path` to `cfg` (a
/// missing or unreadable file changes nothing).
pub fn readInto(gpa: std.mem.Allocator, path: []const u8, cfg: *Config) void {
    const data = sys.readFileAlloc(gpa, path, 64 * 1024) catch return;
    defer gpa.free(data);
    applyText(cfg, data);
}

/// Apply a config file's text.
pub fn applyText(cfg: *Config, data: []const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const kv = keys.parseLine(line) orelse continue;
        applyValue(cfg, kv.key, kv.value);
    }
}

/// Apply one key=value pair to `cfg` (unknown keys are ignored).
pub fn applyValue(cfg: *Config, key: []const u8, value: []const u8) void {
    if (model.Fixed.apply(cfg, key, value)) return;
    if (boundAction(key)) |i| cfg.binds[i] = parseBind(value);
}

/// The action whose key `key` sets ("shortcut_pen": pen).
fn boundAction(key: []const u8) ?usize {
    if (!std.mem.startsWith(u8, key, model.bind_prefix)) return null;
    const name = key[model.bind_prefix.len..];
    inline for (@typeInfo(Action).@"enum".field_names, 0..) |fld_name, i| {
        if (std.mem.eql(u8, name, fld_name)) return i;
    }
    return null;
}

/// "Ctrl+Shift+Z"; anything else ("none", malformed) is unbound.
pub fn parseBind(value: []const u8) Bind {
    const a = accel.parse(value) orelse return .{};
    return Bind.fromAccel(a) orelse .{};
}

test "bind parse and format roundtrip" {
    const b = parseBind("Ctrl+Shift+Z");
    try std.testing.expect(b.ctrl and b.shift and b.code == .z);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", binds.bindName(b, &buf));
    try std.testing.expectEqualStrings("unset", binds.bindName(.{}, &buf));
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", b.toAccel().?.format(&buf).?);
    const plain = parseBind("p");
    try std.testing.expect(!plain.ctrl and plain.code == .p);
    try std.testing.expect(parseBind("1").code == .digit_1);
    // malformed input, and what binds cannot hold, degrade to unbound
    try std.testing.expect(parseBind("Ctrl+Banana").code == .none);
    try std.testing.expect(parseBind("Alt+P").code == .none);
    try std.testing.expect(parseBind("none").code == .none);
    try std.testing.expect(parseBind("").code == .none);
}

test "the thumbnail setting" {
    var cfg: Config = .{};
    try std.testing.expect(cfg.showsThumbnail(true) and !cfg.showsThumbnail(false));
    applyValue(&cfg, "thumbnail", "after_copy_and_save");
    try std.testing.expect(cfg.showsThumbnail(false));
    applyValue(&cfg, "thumbnail", "sometimes");
    try std.testing.expectEqual(model.Thumbnail.after_copy_and_save, cfg.thumbnail);
    applyValue(&cfg, "thumbnail", "never");
    try std.testing.expect(!cfg.thumbnails() and !cfg.showsThumbnail(true));
}

test "the magnifier's settings" {
    var cfg = Config{};
    try std.testing.expectEqual(model.Loupe.hold, cfg.loupe);
    applyValue(&cfg, "loupe", "never");
    try std.testing.expectEqual(model.Loupe.never, cfg.loupe);
    applyValue(&cfg, "loupe", "sometimes");
    try std.testing.expectEqual(model.Loupe.never, cfg.loupe);
    applyValue(&cfg, "loupe_zoom", "11");
    try std.testing.expectEqual(@as(u8, 12), cfg.loupe_zoom);
    applyValue(&cfg, "loupe_zoom", "big");
    try std.testing.expectEqual(@as(u8, 12), cfg.loupe_zoom);
}
