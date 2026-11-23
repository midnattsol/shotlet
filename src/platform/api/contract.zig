//! The platform contract, checked at compile time: a backend must have
//! every declaration the stub backend (src/platform/stub/backend.zig)
//! has, and every type there must have the same declarations and fields.
//! A function takes the same parameters and returns the same payload
//! (its error set may differ): the types the core shares with the
//! backend (api/, src/geom.zig, app/...) must be the very same type; the
//! backend's own types (stub: `platform.stub.*`) only by name, as above.
//! The stub is the contract written down: each declaration with the type
//! the core uses and no behaviour; `zig build check-portable` compiles the
//! core against it for Windows and macOS, so the core cannot use anything
//! the stub (and so the contract) leaves out.

const std = @import("std");
const stub = @import("../stub/backend.zig");

/// Fail the build unless `Backend` has everything the contract names.
pub fn check(comptime Backend: type) void {
    if (Backend == stub) return;
    @setEvalBranchQuota(200_000);
    checkType(stub, Backend, "backend");
}

fn checkType(comptime Want: type, comptime Have: type, comptime path: []const u8) void {
    if (@typeInfo(Want) == .@"struct") {
        inline for (std.meta.fieldNames(Want)) |f| if (!hasMember(Have, f))
            @compileError("platform contract: " ++ path ++ "." ++ f ++ " (a field) is missing from the backend");
    }
    if (!hasDecls(Want)) return;
    inline for (std.meta.declarations(Want)) |d| {
        if (!hasMember(Have, d))
            @compileError("platform contract: " ++ path ++ "." ++ d ++ " is missing from the backend");
        const w = @field(Want, d);
        // shared types (from api/) are the same type on both sides
        if (@TypeOf(w) == type and hasDecls(w) and w != @field(Have, d))
            checkType(w, @field(Have, d), path ++ "." ++ d);
        if (@typeInfo(@TypeOf(w)) == .@"fn")
            checkFn(@TypeOf(w), @TypeOf(@field(Have, d)), path ++ "." ++ d);
    }
}

fn checkFn(comptime Want: type, comptime Have: type, comptime path: []const u8) void {
    const want = @typeInfo(Want).@"fn";
    const have = switch (@typeInfo(Have)) {
        .@"fn" => |f| f,
        else => @compileError("platform contract: " ++ path ++ " is a function in the contract, not in the backend"),
    };
    if (want.param_types.len != have.param_types.len)
        @compileError("platform contract: " ++ path ++ " takes a different number of parameters in the backend");
    inline for (want.param_types, have.param_types, 0..) |w, h, i| {
        if (!sameType(w, h))
            @compileError(std.fmt.comptimePrint("platform contract: {s} parameter {d} is {s} in the backend, {s} in the contract", .{ path, i, typeName(h), typeName(w) }));
    }
    const wr = payload(want.return_type);
    const hr = payload(have.return_type);
    if (!sameType(wr, hr))
        @compileError("platform contract: " ++ path ++ " returns " ++ typeName(hr) ++ " in the backend, " ++ typeName(wr) ++ " in the contract");
}

/// What a function returns, without its error set.
fn payload(comptime T: ?type) ?type {
    const t = T orelse return null;
    return switch (@typeInfo(t)) {
        .error_union => |e| e.payload,
        else => t,
    };
}

fn typeName(comptime T: ?type) []const u8 {
    return if (T) |t| @typeName(t) else "generic";
}

/// The same type, or the backend's own type in the same place (each
/// backend has its own Session, Window...; checkType compares those).
fn sameType(comptime W: ?type, comptime H: ?type) bool {
    const w = W orelse return H == null;
    const h = H orelse return false;
    if (w == h) return true;
    return switch (@typeInfo(w)) {
        .pointer => |p| @typeInfo(h) == .pointer and @typeInfo(h).pointer.size == p.size and
            @typeInfo(h).pointer.attrs.@"const" == p.attrs.@"const" and sameType(p.child, @typeInfo(h).pointer.child),
        .optional => |o| @typeInfo(h) == .optional and sameType(o.child, @typeInfo(h).optional.child),
        .@"struct", .@"union", .@"enum", .@"opaque" => std.mem.startsWith(u8, @typeName(w), "platform.stub."),
        else => false,
    };
}

fn hasDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn hasMember(comptime T: type, comptime name: []const u8) bool {
    if (!hasDecls(T)) return false;
    if (@hasDecl(T, name)) return true;
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasField(T, name),
        else => false,
    };
}

test "the stub satisfies itself and a missing declaration is caught" {
    comptime check(stub);
    const Partial = struct {
        pub const sys = struct {};
    };
    try std.testing.expect(!hasMember(Partial.sys, "monoMs"));
    try std.testing.expect(hasMember(stub.sys, "monoMs"));
}

test "signatures: shared types must match, a backend's own types go by name" {
    const Rect = @import("../../geom.zig").Rect;
    try std.testing.expect(comptime sameType([]Rect, []Rect));
    try std.testing.expect(comptime !sameType([]Rect, []const Rect));
    try std.testing.expect(comptime !sameType(?Rect, ?struct { x: i32, y: i32, w: i32, h: i32 }));
    try std.testing.expect(comptime sameType(*stub.desktop.Session, *struct {}));
    try std.testing.expect(comptime payload(error{Unavailable}!bool) == bool);
}
