//! Optional native libraries (FFmpeg, Tesseract, libwebp, libturbojpeg),
//! opened at run time through api.libs so Shotlet keeps zero build
//! dependencies. One way for all of them: a symbol table `Api` (a struct
//! of C function pointers named as the symbols) bound from one library
//! with `bind`, loaded once from any thread with `Once` (or `Lib` for the
//! plain one-library case), and a reason in `missing()` when it is not
//! there.

const std = @import("std");
const libs = @import("platform/api.zig").libs;
const sync = @import("sync.zig");

/// A library and the symbols `Api` bound from it.
pub fn Table(comptime Api: type) type {
    return struct {
        lib: libs.Lib,
        api: Api,

        pub fn close(self: *@This()) void {
            self.lib.close();
        }
    };
}

pub const Error = error{ NotFound, MissingSymbol };

/// lib`base`.so.`v`, the first of `versions` that opens (an empty
/// version is the unversioned name), with every field of `Api` looked up
/// by name. On failure `why` says what is missing ("libtesseract not
/// found", "libavcodec lacks avcodec_open2").
pub fn bind(comptime Api: type, comptime base: []const u8, versions: []const []const u8, why: *[]const u8) Error!Table(Api) {
    var lib = libs.open(base, versions) orelse {
        why.* = "lib" ++ base ++ " not found";
        return error.NotFound;
    };
    var api: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        @field(api, name) = lib.lookup(T, name) orelse {
            lib.close();
            why.* = "lib" ++ base ++ " lacks " ++ name;
            return error.MissingSymbol;
        };
    }
    return .{ .lib = lib, .api = api };
}

/// `load` run once, by the first `get` from any thread; its result (or
/// its failure, with the reason it put in `why`) is kept for good.
pub fn Once(comptime T: type, comptime load: fn (why: *[]const u8) anyerror!T) type {
    return struct {
        const State = enum(u8) { unknown, ok, missing };
        var state: std.atomic.Value(State) = .init(.unknown);
        var mutex: sync.Mutex = .{};
        var value: T = undefined;
        var why: []const u8 = "";

        /// The loaded value, or null when it is missing.
        pub fn get() ?*const T {
            if (state.load(.acquire) == .unknown) {
                mutex.lock();
                defer mutex.unlock();
                if (state.load(.acquire) == .unknown) {
                    if (load(&why)) |v| {
                        value = v;
                        state.store(.ok, .release);
                    } else |err| {
                        if (why.len == 0) why = @errorName(err);
                        state.store(.missing, .release);
                    }
                }
            }
            return if (state.load(.acquire) == .ok) &value else null;
        }

        pub fn available() bool {
            return get() != null;
        }

        /// Why it is missing (loads it first); empty when it is there.
        pub fn missing() []const u8 {
            return if (get() == null) why else "";
        }
    };
}

/// One library and its symbols, bound once (see `Once` and `bind`).
pub fn Lib(comptime Api: type, comptime base: []const u8, comptime versions: []const []const u8) type {
    return Once(Table(Api), struct {
        fn load(why: *[]const u8) anyerror!Table(Api) {
            return bind(Api, base, versions, why);
        }
    }.load);
}

const Strlen = struct { strlen: *const fn ([*:0]const u8) callconv(.c) usize };

test "a library that is not installed is missing, with the reason" {
    var why: []const u8 = "";
    try std.testing.expectError(error.NotFound, bind(Strlen, "shotlet-no-such-library", &.{ "1", "" }, &why));
    try std.testing.expectEqualStrings("libshotlet-no-such-library not found", why);
    const L = Lib(Strlen, "shotlet-no-such-library", &.{""});
    try std.testing.expect(!L.available());
    try std.testing.expectEqualStrings("libshotlet-no-such-library not found", L.missing());
}

test "symbols bind by field name, and a missing one names itself" {
    var why: []const u8 = "";
    var t = bind(Strlen, "c", &.{"6"}, &why) catch return error.SkipZigTest;
    defer t.close();
    try std.testing.expectEqual(@as(usize, 3), t.api.strlen("abc"));
    const Bad = struct { shotlet_no_such_symbol: *const fn () callconv(.c) void };
    try std.testing.expectError(error.MissingSymbol, bind(Bad, "c", &.{"6"}, &why));
    try std.testing.expectEqualStrings("libc lacks shotlet_no_such_symbol", why);
}

test "Once loads a single time across threads and keeps a failure" {
    const S = struct {
        var calls: std.atomic.Value(u32) = .init(0);
        fn ok(_: *[]const u8) anyerror!u32 {
            _ = calls.fetchAdd(1, .monotonic);
            return 42;
        }
        fn bad(why: *[]const u8) anyerror!u32 {
            why.* = "turned off";
            return error.Off;
        }
        fn bare(_: *[]const u8) anyerror!u32 {
            return error.NoReason;
        }
        fn race() void {
            for (0..100) |_| std.debug.assert(Once(u32, ok).get().?.* == 42);
        }
    };
    var ts: [4]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, S.race, .{});
    for (ts) |t| t.join();
    try std.testing.expectEqual(@as(u32, 1), S.calls.load(.monotonic));
    try std.testing.expectEqualStrings("", Once(u32, S.ok).missing());
    try std.testing.expect(!Once(u32, S.bad).available());
    try std.testing.expectEqualStrings("turned off", Once(u32, S.bad).missing());
    try std.testing.expectEqualStrings("NoReason", Once(u32, S.bare).missing());
}
