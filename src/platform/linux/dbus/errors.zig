//! Error replies: one reading of D-Bus error names for every caller.
//! A name is classified by its last part, the one after ".Error." (or
//! after the last dot), so `org.freedesktop.DBus.Error.AccessDenied`,
//! `org.freedesktop.portal.Error.NotAllowed` and
//! `dev.shotlet.Shell1.Error.Busy` are all read the same way whoever
//! sent them.

const std = @import("std");

pub const ErrorKind = enum {
    /// AccessDenied, NotAllowed, NoAuthorized, PermissionDenied
    denied,
    /// Busy, Locked: the service is there but will not do it now
    busy,
    /// NotFound
    not_found,
    /// UnknownMethod, UnknownInterface, UnknownObject, UnknownProperty:
    /// the service is there without that call (too old, or another one)
    unknown_method,
    /// ServiceUnknown, NameHasNoOwner: nobody owns the name
    service_unknown,
    other,
};

/// What a call's error reply becomes (see Connection.call).
pub const CallError = error{ Denied, Busy, NotFound, UnknownMethod, ServiceUnknown, DBusError };

/// The kind of the error reply named `error_name`.
pub fn classify(error_name: []const u8) ErrorKind {
    const marker = ".Error.";
    const last = if (std.mem.lastIndexOf(u8, error_name, marker)) |i|
        error_name[i + marker.len ..]
    else if (std.mem.lastIndexOfScalar(u8, error_name, '.')) |i|
        error_name[i + 1 ..]
    else
        error_name;
    const table = [_]struct { []const u8, ErrorKind }{
        .{ "AccessDenied", .denied },
        .{ "NotAllowed", .denied },
        .{ "NoAuthorized", .denied },
        .{ "PermissionDenied", .denied },
        .{ "Busy", .busy },
        .{ "Locked", .busy },
        .{ "NotFound", .not_found },
        .{ "UnknownMethod", .unknown_method },
        .{ "UnknownInterface", .unknown_method },
        .{ "UnknownObject", .unknown_method },
        .{ "UnknownProperty", .unknown_method },
        .{ "ServiceUnknown", .service_unknown },
        .{ "NameHasNoOwner", .service_unknown },
    };
    for (table) |e| if (std.mem.eql(u8, last, e[0])) return e[1];
    return .other;
}

/// The CallError for an error reply of this kind.
pub fn toError(kind: ErrorKind) CallError {
    return switch (kind) {
        .denied => error.Denied,
        .busy => error.Busy,
        .not_found => error.NotFound,
        .unknown_method => error.UnknownMethod,
        .service_unknown => error.ServiceUnknown,
        .other => error.DBusError,
    };
}

test "error names are classified by their last part" {
    const t = std.testing;
    try t.expectEqual(ErrorKind.denied, classify("org.freedesktop.DBus.Error.AccessDenied"));
    try t.expectEqual(ErrorKind.denied, classify("org.freedesktop.portal.Error.NotAllowed"));
    try t.expectEqual(ErrorKind.denied, classify("org.kde.KWin.ScreenShot2.Error.NoAuthorized"));
    try t.expectEqual(ErrorKind.busy, classify("dev.shotlet.Shell1.Error.Busy"));
    try t.expectEqual(ErrorKind.busy, classify("dev.shotlet.Shell1.Error.Locked"));
    try t.expectEqual(ErrorKind.not_found, classify("org.freedesktop.portal.Error.NotFound"));
    try t.expectEqual(ErrorKind.unknown_method, classify("org.freedesktop.DBus.Error.UnknownMethod"));
    try t.expectEqual(ErrorKind.unknown_method, classify("org.freedesktop.DBus.Error.UnknownObject"));
    try t.expectEqual(ErrorKind.service_unknown, classify("org.freedesktop.DBus.Error.ServiceUnknown"));
    try t.expectEqual(ErrorKind.service_unknown, classify("org.freedesktop.DBus.Error.NameHasNoOwner"));
    // without ".Error." the last dotted part counts
    try t.expectEqual(ErrorKind.busy, classify("com.example.Busy"));
    try t.expectEqual(ErrorKind.other, classify("org.freedesktop.portal.Error.Failed"));
    try t.expectEqual(ErrorKind.other, classify(""));
    // only a whole last part matches
    try t.expectEqual(ErrorKind.other, classify("org.example.Error.NotBusy"));
    try t.expectEqual(ErrorKind.other, classify("org.example.Error.Busy.More"));
}
