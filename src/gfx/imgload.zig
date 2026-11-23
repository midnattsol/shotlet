//! Open an image file of any kind Shotlet reads: PNG and baseline JPEG
//! with its own decoders, progressive JPEG and WebP through libturbojpeg
//! and libwebp when installed. The format comes from the content, not the
//! name.

const std = @import("std");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
const libs = @import("codec_libs.zig");
const sys = @import("../platform/api.zig").sys;

pub const max_file = 256 * 1024 * 1024;

pub const Format = enum { png, jpeg, webp, unknown };

pub fn sniff(data: []const u8) Format {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (jpeg.isJpeg(data)) return .jpeg;
    if (libs.isWebp(data)) return .webp;
    return .unknown;
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !png.Image {
    return switch (sniff(data)) {
        .png => png.decode(gpa, data),
        .jpeg => jpeg.decode(gpa, data) catch |err| switch (err) {
            // progressive, CMYK...: libjpeg-turbo knows them
            error.Unsupported => libs.decodeJpegLib(gpa, data),
            else => err,
        },
        .webp => libs.decodeWebp(gpa, data),
        .unknown => error.UnknownImageFormat,
    };
}

pub fn loadFile(gpa: std.mem.Allocator, path: []const u8) !png.Image {
    const data = try sys.readFileAlloc(gpa, path, max_file);
    defer gpa.free(data);
    return decode(gpa, data);
}

test "formats by content" {
    try std.testing.expectEqual(Format.png, sniff("\x89PNG\r\n\x1a\n...."));
    try std.testing.expectEqual(Format.jpeg, sniff("\xFF\xD8\xFF\xE0"));
    try std.testing.expectEqual(Format.webp, sniff("RIFF\x00\x00\x00\x00WEBPVP8L"));
    try std.testing.expectEqual(Format.unknown, sniff("GIF89a"));
    try std.testing.expectError(error.UnknownImageFormat, decode(std.testing.allocator, "hello"));
    var img = try decode(std.testing.allocator, @embedFile("testdata/rgb444.jpg"));
    img.deinit(std.testing.allocator);
}
