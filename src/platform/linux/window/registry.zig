//! The Wayland connection and its globals: connecting, binding what the
//! registry announces, global removal and the seat's input devices.

const std = @import("std");
const wl = @import("../wayland.zig");
const keyboard = @import("../keyboard.zig");
const window = @import("../window.zig");
const output = @import("output.zig");
const Env = @import("../../../app/env.zig").Env;
const switches = @import("../../api/switches.zig");
const pointer = @import("pointer.zig");
const keys = @import("keys.zig");
const events = @import("events.zig");

const Window = window.Window;

/// Bound globals; 0 when the compositor does not offer one.
pub const Globals = struct {
    registry: u32 = 0,
    compositor: u32 = 0,
    compositor_version: u32 = 0,
    shm: u32 = 0,
    wm_base: u32 = 0,
    seat: u32 = 0,
    seat_version: u32 = 0,
    /// wl_seat capabilities last announced (pointer/keyboard bits)
    seat_caps: u32 = 0,
    ddm: u32 = 0, // wl_data_device_manager
    ddm_version: u32 = 0,
    viewporter: u32 = 0,
    fs_manager: u32 = 0, // wp_fractional_scale_manager_v1
    xdg_output_manager: u32 = 0,
    ti_manager: u32 = 0, // zwp_text_input_manager_v3
    rel_manager: u32 = 0, // zwp_relative_pointer_manager_v1
    layer_shell: u32 = 0, // zwlr_layer_shell_v1
    layer_shell_version: u32 = 0,
    cursor_shape: u32 = 0, // wp_cursor_shape_manager_v1
    /// zxdg_exporter_v2, else zxdg_exporter_v1 (window/foreign.zig)
    exporter: u32 = 0,
    /// whose window effects a closing window gets (window/vanish.zig)
    effects: Effects = .none,
};

/// Compositors known to animate windows that close, told apart by a
/// global only they offer; .none for the rest (wlroots' sway and labwc
/// animate nothing).
pub const Effects = enum {
    none,
    /// GNOME's mutter (gtk_shell1)
    mutter,
    /// KDE's KWin (org_kde_kwin_blur_manager)
    kwin,

    fn of(iface: []const u8) ?Effects {
        if (std.mem.eql(u8, iface, "gtk_shell1")) return .mutter;
        if (std.mem.eql(u8, iface, "org_kde_kwin_blur_manager")) return .kwin;
        return null;
    }
};

/// Connect to the session's display (Env.session).
pub fn init(alloc: std.mem.Allocator, env: Env) !Window {
    return connect(alloc, env.runtime_dir, env.session.display);
}

/// Connect to Wayland display `display` (a name in `runtime_dir`, or a
/// path).
pub fn connect(alloc: std.mem.Allocator, runtime_dir: []const u8, display: []const u8) !Window {
    var self = Window{
        .alloc = alloc,
        .conn = try wl.Connection.connect(alloc, runtime_dir, display),
    };
    errdefer self.conn.deinit();
    self.kb = keyboard.Keyboard.init();
    errdefer self.kb.deinit();

    self.globals.registry = try self.conn.getRegistry();
    // collect globals until the sync callback fires
    try roundtrip(&self);
    const g = &self.globals;
    if (g.compositor == 0 or g.shm == 0 or g.wm_base == 0)
        return error.MissingGlobals;
    // outputs announce their geometry after binding: one more roundtrip
    // so openOutputs() knows them up front
    if (try output.ensureAllXdg(&self)) try roundtrip(&self);
    return self;
}

/// Dispatch events until the compositor has handled everything sent so far.
pub fn roundtrip(w: *Window) !void {
    try w.conn.roundtrip(w, events.handleEvent);
}

/// The compositor offers zwlr_layer_shell_v1 (KDE, wlroots; not GNOME).
pub fn hasLayerShell(w: *const Window) bool {
    return w.globals.layer_shell != 0;
}

/// wl_registry events.
pub fn handleEvent(w: *Window, ev: wl.Event) !void {
    if (try wl.Global.of(w.globals.registry, ev)) |g| return handleGlobal(w, g);
    if (ev.opcode == wl.wl_registry.ev_global_remove) {
        var r = ev.reader();
        try handleGlobalRemove(w, try r.uint());
    }
}

fn handleGlobal(w: *Window, g: wl.Global) !void {
    if (Effects.of(g.interface)) |e| w.globals.effects = e;
    if (try bindCore(w, g)) return;
    if (try bindExtension(w, g)) return;
    if (g.is("wl_output")) try output.add(w, g);
}

/// Core protocol globals; false when `g` is none of them.
fn bindCore(w: *Window, g: wl.Global) !bool {
    const gl = &w.globals;
    const c = &w.conn;
    const reg = gl.registry;
    if (g.is("wl_compositor")) {
        // v6 for wl_surface.preferred_buffer_scale
        const b = try c.bindGlobal(reg, g, 6);
        gl.compositor = b.id;
        gl.compositor_version = b.version;
    } else if (g.is("wl_shm")) {
        gl.shm = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("xdg_wm_base")) {
        // v2 for the tiled_* states (a tiled window draws no shadow)
        gl.wm_base = (try c.bindGlobal(reg, g, 2)).id;
    } else if (g.is("wl_seat")) {
        if (gl.seat != 0) return true;
        // v8 adds axis_value120 (exact wheel notches); keymaps are
        // already mapped MAP_PRIVATE as v7 requires
        const b = try c.bindGlobal(reg, g, 8);
        gl.seat = b.id;
        gl.seat_version = b.version;
    } else if (g.is("wl_data_device_manager")) {
        // v3: drag-and-drop actions (copy) for startDrag
        const b = try c.bindGlobal(reg, g, 3);
        gl.ddm = b.id;
        gl.ddm_version = b.version;
    } else return false;
    return true;
}

/// Optional protocol extensions; false when `g` is none of them. The
/// SHOTLET_NO_* switches hide some (testing the fallbacks).
fn bindExtension(w: *Window, g: wl.Global) !bool {
    const gl = &w.globals;
    const c = &w.conn;
    const reg = gl.registry;
    const sw = switches.get();
    if (g.is("zwlr_layer_shell_v1")) {
        if (sw.no_layer_shell) return true;
        const b = try c.bindGlobal(reg, g, 4);
        gl.layer_shell = b.id;
        gl.layer_shell_version = b.version;
    } else if (g.is("wp_viewporter")) {
        gl.viewporter = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("wp_fractional_scale_manager_v1")) {
        if (!sw.no_fractional) gl.fs_manager = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("wp_cursor_shape_manager_v1")) {
        if (!sw.no_cursor_shape) gl.cursor_shape = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("zxdg_output_manager_v1")) {
        gl.xdg_output_manager = (try c.bindGlobal(reg, g, 3)).id;
        _ = try output.ensureAllXdg(w);
    } else if (g.is("zwp_relative_pointer_manager_v1")) {
        gl.rel_manager = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("zxdg_exporter_v2")) {
        gl.exporter = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("zxdg_exporter_v1")) {
        // the same requests and events; v2 wins when both are offered
        if (gl.exporter == 0) gl.exporter = (try c.bindGlobal(reg, g, 1)).id;
    } else if (g.is("zwp_text_input_manager_v3")) {
        gl.ti_manager = (try c.bindGlobal(reg, g, 1)).id;
    } else return false;
    return true;
}

pub fn handleGlobalRemove(w: *Window, name: u32) !void {
    try output.remove(w, name);
}

/// wl_seat events: follow its capabilities.
pub fn handleSeat(w: *Window, opcode: u16, r: *wl.ArgReader) !void {
    if (opcode != wl.wl_seat.ev_capabilities) return;
    w.globals.seat_caps = try r.uint();
    try updateSeatDevices(w);
    try w.conn.flush();
}

/// Take the pointer and keyboard the seat actually has, and let go of
/// ones it lost. Asking for a device the seat does not announce is
/// legal but has crashed compositors (mutter's headless backend).
pub fn updateSeatDevices(w: *Window) !void {
    if (w.globals.seat == 0 or w.surfaces[0].wl_surface == 0) return;
    const caps = w.globals.seat_caps;
    try pointer.updateDevice(w, caps & wl.wl_seat.cap_pointer != 0);
    try keys.updateDevice(w, caps & wl.wl_seat.cap_keyboard != 0);
}
