//! The quick access process's state: the stack of thumbnail cards, the
//! window they live in (layer surface or plain toplevel), and the socket
//! later captures hand their entries over. Actions, input and drawing
//! live in sibling files and are reachable as methods.

const std = @import("std");
const log = std.log.scoped(.quick_access);
const desktop = @import("../../platform/api.zig").desktop;
const config = @import("../config.zig");
const env_mod = @import("../env.zig");
const history = @import("../history.zig");
const keep = @import("../keep.zig");
const quick_ipc = @import("../quick_ipc.zig");
const ipc = @import("../ipc.zig");
const sys = @import("../../platform/api.zig").sys;
const png = @import("../../gfx/png.zig");
const window = @import("../../platform/api.zig").window;
const fui = @import("../../ui/floatui.zig");
const floatwin = @import("../../ui/floatwin.zig");
const motion = @import("../../ui/motion.zig");
const press = @import("../../ui/press.zig");
const scale = @import("../../ui/scale.zig");
const theme = @import("../../ui/theme.zig");
const Notice = @import("../../ui/notice.zig").Notice;
const layout = @import("layout.zig");
const actions = @import("actions.zig");
const input = @import("input.zig");
const card_draw = @import("card.zig");

const Env = env_mod.Env;
const Window = window.Window;
const Hit = layout.Hit;
const card_w = layout.card_w;
const pad = layout.pad;
const edge = layout.edge;
const max_cards = layout.max_cards;

pub const Card = struct {
    kept: keep.Kept,
    meta: history.Meta,
    editable: bool,
    thumb: png.Image,
    /// the picture fitted to the card at its current size
    pic: fui.FitCache = .{},
    /// fading in from its first frame, out once its time is up
    life: motion.Life = .{},
    deadline_ms: i64,
    menu: bool = false,
    /// how far its hover controls show (0..1)
    hov: motion.Tween = .{ .dur_ms = theme.motion_fast },
    /// "Copied", "Saved" over it for a moment
    notice: Notice = .{},

    fn deinit(self: *Card, gpa: std.mem.Allocator) void {
        self.meta.deinit(gpa);
        self.thumb.deinit(gpa);
        self.pic.deinit(gpa);
    }
};

pub const Quick = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: config.Config,
    win: Window,
    bus: ?desktop.Bus = null,
    cards: std.ArrayList(Card) = .empty,
    /// the hand-off socket (quick_ipc.zig)
    server: ipc.Server = .{},
    layer: bool = false,
    /// GNOME without the extension: say how to keep it above
    hint: bool = false,
    hint_text: []const u8 = "Keep it above other windows:",
    hint_link: []const u8 = "Enable GNOME integration",
    opened: bool = false,
    size: [2]u32 = .{ 0, 0 },
    hover: ?Hit = null,
    /// the left button held on a control (a click is its release there)
    press: press.Press(Hit) = .{},
    /// keyboard focus: card index and control
    focus: ?Hit = null,
    dirty: bool = true,
    /// the card being dragged out, and the drag
    dragging: ?usize = null,
    drag: fui.DragOut = .{},
    /// the desktop's appearance (quick.setup loads it)
    th: theme.Theme = theme.of(.{}),
    /// told once the first frame is committed (see quick.run)
    ready_fd: sys.fd_t = -1,

    pub const act = actions.act;
    pub const notice = actions.notice;
    pub const activate = actions.activate;
    pub const startDrag = actions.startDrag;
    pub const checkDrag = actions.checkDrag;
    pub const onEvent = input.onEvent;
    pub const tick = input.tick;
    pub const nextWakeMs = input.nextWakeMs;
    pub const render = card_draw.render;

    /// Physical px per logical px.
    pub fn factor(self: *const Quick) f64 {
        return scale.of(self.win.scale120);
    }

    pub fn bus_(self: *Quick) ?*desktop.Bus {
        if (self.bus == null) self.bus = desktop.connect(self.gpa, self.env) catch return null;
        return &self.bus.?;
    }

    /// The first frame is committed: let the editor go.
    pub fn signalReady(self: *Quick) void {
        if (self.ready_fd < 0) return;
        sys.writeAll(self.ready_fd, "1") catch {};
        sys.close(self.ready_fd);
        self.ready_fd = -1;
    }

    pub fn deinit(self: *Quick) void {
        self.signalReady();
        for (self.cards.items) |*c| c.deinit(self.gpa);
        self.cards.deinit(self.gpa);
        self.stopListening();
        self.win.deinit();
        if (self.bus) |*b| b.deinit();
    }

    // --- the hand-off socket ---

    /// False when another stack listens (a stale socket is taken over).
    pub fn listen(self: *Quick) bool {
        self.server = quick_ipc.listen(self.env) catch |err| {
            if (err != error.AddressInUse) log.warn("no hand-off socket: {t}", .{err});
            return false;
        };
        return true;
    }

    pub fn stopListening(self: *Quick) void {
        self.server.close();
    }

    /// Show the entries newcomers hand over, answering "ok" to each.
    pub fn acceptClients(self: *Quick) void {
        var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        while (self.server.next(&buf)) |req| {
            const a = quick_ipc.parseAdd(req.line) orelse {
                req.close();
                continue;
            };
            self.add(a.root, a.id) catch |err| {
                log.warn("cannot show {s}: {t}", .{ a.id, err });
                req.close();
                continue;
            };
            log.info("added {s}", .{a.id});
            req.reply("ok");
        }
    }

    // --- the cards ---

    /// Put the entry's card at the bottom of the stack (replacing an
    /// older card of the same capture).
    pub fn add(self: *Quick, root: []const u8, id: []const u8) !void {
        var kept: keep.Kept = .{ .id = history.Id.fromSlice(id) orelse return error.BadId };
        if (root.len > kept.root_buf.len) return error.PathTooLong;
        @memcpy(kept.root_buf[0..root.len], root);
        kept.root_len = root.len;
        var meta = try history.readMeta(self.gpa, root, id);
        errdefer meta.deinit(self.gpa);
        var pbuf: [1200]u8 = undefined;
        const thumb_data = try history.readFile(self.gpa, root, id, .thumb);
        defer self.gpa.free(thumb_data);
        var thumb = try png.decode(self.gpa, thumb_data);
        errdefer thumb.deinit(self.gpa);
        const editable = (sys.fileSize(try history.entryPath(&pbuf, root, id, "doc")) catch null) != null;
        // the same capture again (edited): replace it
        self.dropCardOf(id);
        const now = sys.monoMs();
        try self.cards.insert(self.gpa, 0, .{
            .kept = kept,
            .meta = meta,
            .editable = editable,
            .thumb = thumb,
            .deadline_ms = now + @as(i64, self.cfg.quick_access_seconds) * 1000,
        });
        while (self.cards.items.len > max_cards) {
            var c = self.cards.pop().?;
            c.deinit(self.gpa);
        }
        self.focus = null;
        self.dirty = true;
        try self.fitWindow();
    }

    fn dropCardOf(self: *Quick, id: []const u8) void {
        for (self.cards.items, 0..) |*c, i| {
            if (std.mem.eql(u8, c.kept.id.slice(), id)) {
                var old = self.cards.orderedRemove(i);
                old.deinit(self.gpa);
                break;
            }
        }
    }

    pub fn remove(self: *Quick, i: usize) void {
        var c = self.cards.orderedRemove(i);
        c.deinit(self.gpa);
        self.hover = null;
        self.press.cancel();
        if (self.focus) |fo| {
            if (fo.card >= self.cards.items.len) self.focus = null;
        }
        self.dirty = true;
        if (self.cards.items.len > 0) self.fitWindow() catch {};
    }

    // --- the window ---

    /// Open the window on the first card; resize it to the stack later.
    fn fitWindow(self: *Quick) !void {
        const sz = layout.windowSize(self.cards.items.len, self.hint);
        if (!self.opened) {
            try self.openWindow(sz);
        } else if (sz[0] != self.size[0] or sz[1] != self.size[1]) {
            if (self.layer) {
                try self.win.setLayerPlacement(0, sz[0], sz[1], .{ 0, 0, edge, edge });
            } else {
                try self.win.resizeTo(0, sz[0], sz[1]);
            }
        }
        self.size = sz;
        try self.updateInputRegion();
    }

    fn openWindow(self: *Quick, sz: [2]u32) !void {
        // keyboard only while the pointer is over it (see the
        // .pointer_motion event): typing stays in the person's app
        self.layer = try floatwin.open(&self.win, .{
            .size = sz,
            .anchor = .{ .bottom = true, .left = true },
            .margin = .{ 0, 0, edge, edge },
        });
        self.opened = true;
    }

    /// Only the cards (and the hint) take input, not their shadows.
    fn updateInputRegion(self: *Quick) !void {
        var rects: [max_cards + 1]window.Rect = undefined;
        const h: i32 = @intCast(self.size[1]);
        const n = self.cards.items.len;
        for (0..n) |i| {
            const r = layout.cardRect(i, h);
            rects[i] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        }
        var k = n;
        if (self.hint) {
            rects[k] = .{ .x = pad, .y = pad, .w = card_w, .h = layout.hint_h - layout.gap };
            k += 1;
        }
        try self.win.setInputRegion(0, rects[0..k]);
    }

    fn menus(self: *const Quick, buf: []bool) []bool {
        const n = @min(buf.len, self.cards.items.len);
        for (self.cards.items[0..n], 0..) |c, i| buf[i] = c.menu;
        return buf[0..n];
    }

    /// What is under a point in buffer coordinates.
    pub fn hitAt(self: *const Quick, bx: f64, by: f64) ?Hit {
        if (bx < 0 or by < 0) return null;
        var mb: [max_cards]bool = undefined;
        return layout.hitTest(scale.toLogical(bx, self.factor()), scale.toLogical(by, self.factor()), @intCast(self.size[1]), self.cards.items.len, self.menus(&mb), self.hint);
    }

    /// The card actions and shortcuts apply to: focused, hovered, newest.
    pub fn current(self: *const Quick) ?usize {
        if (self.cards.items.len == 0) return null;
        if (self.focus) |fo| return fo.card;
        if (self.hover) |h| if (h.control != .hint) return h.card;
        return 0;
    }
};
