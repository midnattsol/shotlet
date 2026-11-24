//! Our clipboard selection: claiming it with text or an image (PNG,
//! possibly encoded in the background), serving reads, and letting go.
//!
//! GNOME (mutter) takes the selection only from the client that has the
//! keyboard focus when the request arrives, and cancels the offer
//! otherwise, without another word. What a window believes about its
//! focus can be stale (the focus left while it was busy exporting, the
//! leave still unread), and any client that maps a surface for a moment
//! takes the focus (wl-copy and wl-paste do on GNOME). So every claim is
//! confirmed with a roundtrip; an offer cancelled while the focus was
//! elsewhere is made again once the focus is back
//! (Window.waitKeyboardFocus, the same wait as after a save dialog).

const std = @import("std");
const log = std.log.scoped(.window);
const sys = @import("../sys.zig");
const wl = @import("../wayland.zig");
const png = @import("../../../gfx/png.zig");
const window = @import("../window.zig");
const events = @import("events.zig");

const Window = window.Window;

/// How long a claim waits for the keyboard focus to come back after the
/// compositor refused it for want of focus.
const refocus_ms = 1500;

/// Raw pixels on the clipboard, PNG-encoded on a worker thread.
const ClipboardImage = struct {
    alloc: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    png_data: []u8 = &.{},
    encode_failed: bool = false,
    thread: ?std.Thread = null,

    fn create(gpa: std.mem.Allocator, pixels: []u32, width: u32, height: u32) !*ClipboardImage {
        const self = try gpa.create(ClipboardImage);
        self.* = .{ .alloc = gpa, .pixels = pixels, .width = width, .height = height };
        errdefer gpa.destroy(self);
        self.thread = try std.Thread.spawn(.{}, encodeWorker, .{self});
        return self;
    }

    fn deinit(self: *ClipboardImage) void {
        self.alloc.free(self.pixels);
        self.release();
    }

    /// Stop and free everything but the pixels (the caller's again).
    fn release(self: *ClipboardImage) void {
        if (self.thread) |thread| thread.join();
        self.alloc.free(self.png_data);
        const gpa = self.alloc;
        gpa.destroy(self);
    }

    fn waitPng(self: *ClipboardImage) ![]const u8 {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.encode_failed) return error.ClipboardEncodeFailed;
        return self.png_data;
    }

    fn encodeWorker(self: *ClipboardImage) void {
        self.png_data = png.encode(self.alloc, self.pixels, self.width, self.height) catch {
            self.encode_failed = true;
            return;
        };
    }
};

/// The selection we own. Its payloads are Window.clipboard_text and
/// Window.clipboard_png, or `image` while it encodes.
pub const Clipboard = struct {
    /// wl_data_source of our selection; 0 when we own none
    source: u32 = 0,
    image: ?*ClipboardImage = null,
    /// the types offered, to offer them again (static strings)
    mime_buf: [4][]const u8 = undefined,
    mime_len: usize = 0,
    /// set while a claim is confirmed: the compositor cancelled it, and
    /// whether the focus was elsewhere then
    confirming: bool = false,
    refused: bool = false,
    refused_unfocused: bool = false,

    fn mimes(self: *const Clipboard) []const []const u8 {
        return self.mime_buf[0..self.mime_len];
    }
};

/// What a selection offers (owned once claimed; either may be empty).
const Payload = struct {
    text: []u8 = &.{},
    png: []u8 = &.{},
    image: ?*ClipboardImage = null,
};

pub fn hasClipboard(w: *const Window) bool {
    return w.clipboard.source != 0;
}

/// The PNG we offer on the clipboard (encoding it first if needed);
/// null when we offer none or text.
pub fn clipboardPng(w: *Window) ?[]const u8 {
    if (w.clipboard.source == 0) return null;
    if (w.clipboard.image) |image| return image.waitPng() catch null;
    if (w.clipboard_png.len > 0) return w.clipboard_png;
    return null;
}

/// Claim the clipboard selection with an already-encoded image/png data
/// source. Takes ownership of data on success.
pub fn setClipboardPng(w: *Window, data: []u8) !void {
    try claim(w, &.{"image/png"}, .{ .png = data });
}

/// Claim the clipboard selection immediately, then encode the raw image in
/// the background. Takes ownership of pixels on success.
pub fn setClipboardImage(w: *Window, pixels: []u32, width: u32, height: u32) !void {
    const image = try ClipboardImage.create(w.alloc, pixels, width, height);
    claim(w, &.{"image/png"}, .{ .image = image }) catch |err| {
        image.release();
        return err;
    };
}

/// Put UTF-8 text on the clipboard. Takes ownership of `data` on
/// success.
pub fn setClipboardText(w: *Window, data: []u8) !void {
    try claim(w, &.{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" }, .{ .text = data });
}

/// Offer `text` and `data` (owned on success; either may be empty) under
/// `mimes` (at most four, static strings): video/* and image/gif are
/// served `data`, the rest `text` when there is text.
pub fn setClipboardFile(w: *Window, mimes: []const []const u8, text: []u8, data: []u8) !void {
    try claim(w, mimes, .{ .text = text, .png = data });
}

/// Offer a new selection of `mimes` with payload `p`, dropping the
/// previous one; confirmed (see the top). On an error `p` is the
/// caller's again.
fn claim(w: *Window, mimes: []const []const u8, p: Payload) !void {
    const g = &w.globals;
    if (g.ddm == 0 or w.data_device.id == 0) return error.NoDataDevice;
    if (mimes.len > w.clipboard.mime_buf.len) return error.TooManyTypes;
    dropSource(w);
    w.clipboard_text = p.text;
    w.clipboard_png = p.png;
    w.clipboard.image = p.image;
    @memcpy(w.clipboard.mime_buf[0..mimes.len], mimes);
    w.clipboard.mime_len = mimes.len;
    errdefer giveBack(w);
    try offer(w);
    try confirm(w);
}

/// A new wl_data_source of the remembered types, set as the selection
/// with the latest input serial (replacing a cancelled one of ours).
fn offer(w: *Window) !void {
    const c = &w.conn;
    const source = c.newId();
    try c.request(w.globals.ddm, wl.wl_data_device_manager.create_data_source, &.{.{ .new_id = source }});
    for (w.clipboard.mimes()) |m| try c.request(source, wl.wl_data_source.offer, &.{.{ .string = m }});
    try c.request(w.data_device.id, wl.wl_data_device.set_selection, &.{ .{ .object = source }, .{ .uint = w.input_serial } });
    if (w.clipboard.source != 0) try c.request(w.clipboard.source, wl.wl_data_source.destroy, &.{});
    w.clipboard.source = source;
    try c.flush();
}

/// Whether the compositor kept the offer: a roundtrip; refused for want
/// of focus, offered again once the focus is back (error.NoKeyboardFocus
/// when it does not come back in time). Cancelled while focused: another
/// client took the clipboard meanwhile, which stands.
fn confirm(w: *Window) !void {
    const cb = &w.clipboard;
    const deadline = sys.monoMs() + refocus_ms;
    cb.confirming = true;
    defer cb.confirming = false;
    while (true) {
        cb.refused = false;
        try w.conn.roundtrip(w, events.handleEvent);
        if (!cb.refused) return;
        if (!cb.refused_unfocused) {
            dropSource(w);
            return;
        }
        log.debug("clipboard: refused without the keyboard focus; offering again once it is back", .{});
        const left = deadline - sys.monoMs();
        if (left <= 0 or !try events.waitKeyboardFocus(w, @intCast(left))) {
            log.info("clipboard: no keyboard focus to take the clipboard with", .{});
            return error.NoKeyboardFocus;
        }
        try offer(w);
    }
}

/// A claim failed: forget its payloads without freeing them (the
/// caller's again) and let the offer go.
fn giveBack(w: *Window) void {
    w.clipboard_text = &.{};
    w.clipboard_png = &.{};
    w.clipboard.image = null;
    dropSource(w);
}

/// Serve clipboard reads until another client replaces the selection.
/// Blocks; safe to call after closeWindow().
pub fn serveClipboard(w: *Window) !void {
    while (w.clipboard.source != 0) {
        const ev = try w.conn.readEvent();
        try events.handleEvent(w, ev);
        w.queue.clearRetainingCapacity();
    }
}

/// wl_data_source events of our selection.
pub fn handleSource(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    switch (opcode) {
        wl.wl_data_source.ev_send => {
            const mime = try r.string();
            if (w.conn.takeFd()) |fd| {
                defer sys.close(fd);
                const data = payloadFor(w, mime) orelse return;
                sys.writeAllBlocking(fd, data) catch |err| switch (err) {
                    error.BrokenPipe, error.ConnectionReset => {},
                    else => log.warn("clipboard send failed: {t}", .{err}),
                };
            }
        },
        wl.wl_data_source.ev_cancelled => {
            const cb = &w.clipboard;
            // (a claim being confirmed decides what follows: confirm)
            if (cb.confirming) {
                cb.refused = true;
                cb.refused_unfocused = !w.kb_focus;
            } else dropSource(w);
        },
        else => {},
    }
}

/// What to send for `mime`: video/* and image/gif get the file in
/// clipboard_png, the rest the text (its uri) when there is text, else
/// the image; null when encoding the image failed.
fn payloadFor(w: *Window, mime: []const u8) ?[]const u8 {
    const media = std.mem.startsWith(u8, mime, "video/") or std.mem.startsWith(u8, mime, "image/gif");
    if (w.clipboard_text.len > 0 and !media) return w.clipboard_text;
    if (w.clipboard.image) |image| return image.waitPng() catch |err| {
        log.warn("clipboard encode failed: {t}", .{err});
        return null;
    };
    return w.clipboard_png;
}

/// Give up the selection and free its payloads.
pub fn dropSource(w: *Window) void {
    if (w.clipboard.source != 0) {
        w.conn.request(w.clipboard.source, wl.wl_data_source.destroy, &.{}) catch {};
        w.clipboard.source = 0;
    }
    if (w.clipboard_text.len > 0) {
        w.alloc.free(w.clipboard_text);
        w.clipboard_text = &.{};
    }
    if (w.clipboard_png.len > 0) {
        w.alloc.free(w.clipboard_png);
        w.clipboard_png = &.{};
    }
    if (w.clipboard.image) |image| {
        image.deinit();
        w.clipboard.image = null;
    }
    w.conn.flush() catch {};
}
