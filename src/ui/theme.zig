//! The look of every Shotlet surface ("Glass": translucent material over a
//! blurred backdrop, macOS-like metrics), in a light and a dark variant,
//! following the system's colour scheme and accent colour.
//!
//! Stable API (the editor, the Settings window and the after-capture
//! windows all use it):
//!
//!   Theme                 every colour (0xAARRGGBB) of one appearance;
//!                         the metrics are the `pub const`s below, in
//!                         logical pixels (multiply by the surface scale)
//!   Theme.get(dark, accent)   build one; accent null = system blue
//!   Prefs                 what the system asks for: dark, accent,
//!                         animations (false = reduce motion); the
//!                         desktop seam's Appearance (api.desktop)
//!   of(prefs)             the Theme for those preferences
//!   readPrefs(session)    ask the desktop once (Linux: the Settings
//!                         portal); never fails: missing values keep
//!                         the defaults
//!   watch(session)        follow changes (api.desktop.pump folds them)
//!   load(gpa, env, timeout_ms)   read the desktop's appearance (one
//!                         default when it cannot be read: Prefs{}), set
//!                         motion.enabled from it, and return its Theme;
//!                         loadPrefs: the same, the Prefs themselves
//!   Opaque, Opaque.of(th) the panel colours made opaque, for surfaces
//!                         with no backdrop blur (floating client windows)
//!   Scrim, Theme.scrim(level)  the dark veils and pills over pictures
//!   Shadow, Shadow.reach, window_shadow   shadows (cards': Theme.card_shadow)
//!   card_room, window_room   the room a see-through window keeps for a
//!                         card's or a window frame's shadow
//!   withAlpha, fade, mix, over, luminance, contrast, legible
//!                         colour helpers (gfx/color.zig)

const std = @import("std");
const desktop = @import("../platform/api.zig").desktop;
const color = @import("../gfx/color.zig");
const motion_mod = @import("motion.zig");

// --- metrics (logical px) ---

/// floating toolbar: corner radius, inner padding, gap between controls
pub const bar_radius: f64 = 14;
pub const bar_pad: f64 = 6;
pub const bar_gap: f64 = 4;
/// square tool buttons and their corner radius
pub const button: f64 = 34;
pub const button_radius: f64 = 9;
/// icon box inside a button, and the icons' stroke (in 24-unit icon space)
pub const icon: f64 = 18;
pub const icon_stroke: f64 = 1.75;
/// separators between groups: 1 px wide, this tall, `sep_margin` each side
pub const sep_h: f64 = 20;
pub const sep_margin: f64 = 4;
/// popovers and menus
pub const popover_radius: f64 = 14;
pub const popover_pad: f64 = 14;
pub const menu_radius: f64 = 12;
pub const menu_pad: f64 = 6;
pub const menu_row: f64 = 30;
/// boxed-list cards (Settings), rows and switches
pub const card_radius: f64 = 12;
pub const row_h: f64 = 56;
pub const switch_w: f64 = 44;
pub const switch_h: f64 = 26;
/// backdrop blur under the material (CSS blur radius, roughly a sigma)
pub const backdrop_blur: f64 = 24;
/// keyboard focus ring: width and gap to the control
pub const focus_w: f64 = 2;
pub const focus_gap: f64 = 2;
/// type sizes
pub const font_label: f64 = 13;
pub const font_small: f64 = 12;
/// motion: durations of the ease-out transitions, ms
pub const motion_fast: i64 = 120;
pub const motion: i64 = 150;
pub const motion_slow: i64 = 180;
/// motion: a floating window or card fading in, and out (motion.Life)
pub const motion_enter: i64 = 150;
pub const motion_exit: i64 = 250;
/// what is left of a disabled control's ink
pub const disabled_alpha: f64 = 0.3;
/// tooltips wait this long under a still pointer
pub const tooltip_delay: i64 = 500;

pub const default_accent: u32 = 0xFF0A84FF;
/// WCAG AA for text: what white text on a fill, and coloured text on a
/// window, must reach
pub const aa_text: f64 = 4.5;
/// the red fill of destructive buttons (white text on it reads: 5.4:1),
/// and pressed-looking on hover
pub const destructive_fill: u32 = 0xFFD70015;
/// the capture outside the selection is darkened by this (40%), or by
/// `capture_dim_dark` (55%) when the capture itself is dark
/// (ui/dim.zig)
pub const capture_dim: u32 = 0x66000000;
pub const capture_dim_dark: u32 = 0x8C000000;
pub const destructive_fill_hover: u32 = 0xFFB80012;

pub const Shadow = struct {
    color: u32,
    /// CSS-style blur radius and vertical offset, logical px
    blur: f64,
    dy: f64,

    /// How far it reaches past the surface casting it, on its farthest
    /// side (logical px): ui/material.zig draws it over
    /// shadowFootprint, the blur all round plus the offset below.
    pub fn reach(sh: Shadow) f64 {
        return sh.blur + @abs(sh.dy);
    }
};

/// The room a see-through window keeps around what casts a shadow in it
/// (logical px, outside its input region): a card's shadow's reach
/// (quick access, toasts) and a window frame's (frame.zig). Their sizes
/// are the same in both appearances.
pub const card_room = room(dark_base.card_shadow);
pub const window_room = room(window_shadow);

/// The shadow of ordinary windows' drawn frame (Settings, Trim;
/// ui/frame.zig), the same in both appearances: smaller than a card's,
/// so the room the frame keeps around the window stays small.
pub const window_shadow: Shadow = .{ .color = 0x48000000, .blur = 14, .dy = 5 };

fn room(comptime sh: Shadow) comptime_int {
    return @intFromFloat(@ceil(sh.reach()));
}

pub const Theme = struct {
    dark: bool,
    accent: u32,
    /// accent when hovered / pressed
    accent_hover: u32,
    /// text and icons on the accent
    on_accent: u32 = 0xFFFFFFFF,
    /// the accent as a fill under `on_accent` (darkened until white text
    /// reads on it), and when hovered
    accent_fill: u32,
    accent_fill_hover: u32,
    /// the accent as text on the window background (links)
    accent_text: u32,

    // --- floating material (toolbar, popovers, menus, tooltips) ---
    fg: u32,
    muted: u32,
    /// the translucent material, drawn over the blurred backdrop
    material: u32,
    /// the material as an opaque colour (gap rings, segmented thumbs)
    material_solid: u32,
    /// 0.5 px border of the material, and separators
    hairline: u32,
    hover: u32,
    pressed: u32,
    /// slider tracks and segmented-control troughs
    track: u32,
    /// the selected segment of a segmented control
    seg_on: u32,
    bar_shadow: Shadow,
    popover_shadow: Shadow,
    /// the magnifier's lens: tighter than a bar's, it sits by the pointer
    loupe_shadow: Shadow,
    /// floating cards (thumbnails, toasts, the recorder's control, pins'
    /// menus): opaque, so the shadow may show all round
    card_shadow: Shadow,

    // --- the capture overlay ---
    /// the selection's two-tone edge: a light line inside a dark one, so
    /// it shows on any capture
    sel_edge: u32 = 0xE6FFFFFF,
    sel_edge_outer: u32 = 0x8C000000,
    handle: u32 = 0xFFFFFFFF,
    handle_shadow: u32 = 0x66000000,
    /// the size label and other pills drawn on the screenshot: nearly
    /// opaque, so the capture never shows through their text, with a
    /// hairline that keeps their edge on dark captures
    pill_bg: u32 = 0xEB1C1C1E,
    pill_line: u32 = 0x1FFFFFFF,
    pill_fg: u32 = 0xFFF5F5F7,
    /// secondary text on a pill (a tooltip's shortcut)
    pill_muted: u32 = 0xB3EBEBF5,

    // --- controls over a picture (thumbnails, pins): the same in both
    // appearances, they sit on the capture, not on the theme ---
    /// the dark veils and pills, by `Scrim` level (Theme.scrim)
    scrim_soft: u32 = 0x40000000,
    scrim_veil: u32 = 0x6B000000,
    scrim_pill: u32 = 0xB8000000,
    scrim_strong: u32 = 0xCC000000,
    scrim_notice: u32 = 0xE6000000,
    /// round buttons: dark discs, so their white icons read on any
    /// capture (7:1 over white under the veil; 9.9:1 hovered)
    round_btn: u32 = 0x66000000,
    round_btn_hover: u32 = 0x8C000000,
    /// ink of the controls over a picture, and dimmed (unavailable)
    on_scrim: u32 = 0xFFFFFFFF,
    on_scrim_dim: u32 = 0x80FFFFFF,
    /// light pill buttons over a picture (Copy, Save as)
    light_pill: u32 = 0xEBFFFFFF,
    light_pill_hover: u32 = 0xFFFFFFFF,
    light_pill_fg: u32 = 0xFF1D1D1F,
    /// the edge ring of a colour swatch, so white and black swatches show
    swatch_ring: u32 = 0x59808080,

    // --- windows (Settings, history): GNOME-like boxed lists ---
    window_bg: u32,
    header_bg: u32,
    card: u32,
    line: u32,
    chip: u32,
    switch_off: u32,
    text: u32,
    text_muted: u32,
    view_sel: u32,
    /// panels of the after-capture windows, and their input fields
    panel: u32,
    field: u32,
    destructive: u32,

    pub fn get(dark: bool, accent_opt: ?u32) Theme {
        const accent = (accent_opt orelse default_accent) | 0xFF000000;
        var t = if (dark) dark_base else light_base;
        t.accent = accent;
        t.accent_hover = mix(accent, if (dark) 0xFFFFFFFF else 0xFF000000, 0.12);
        t.accent_fill = accentFill(accent);
        t.accent_fill_hover = mix(t.accent_fill, 0xFF000000, 0.12);
        t.accent_text = legible(accent, t.window_bg, aa_text);
        return t;
    }

    /// The veil or pill colour of `level`.
    pub fn scrim(t: Theme, level: Scrim) u32 {
        return switch (level) {
            .soft => t.scrim_soft,
            .veil => t.scrim_veil,
            .pill => t.scrim_pill,
            .strong => t.scrim_strong,
            .notice => t.scrim_notice,
        };
    }
};

/// How dark a veil or pill over a picture is: `soft` and `veil` darken
/// the whole picture under controls; `pill` and `strong` carry status
/// text; `notice` carries a message that must read at once.
pub const Scrim = enum { soft, veil, pill, strong, notice };

/// The panel colours of a theme made opaque, for windows a client
/// cannot blur behind (thumbnails' toasts, the history panel, the
/// scrolling-capture HUD): the Glass panel over the window background,
/// and each tint over that.
pub const Opaque = struct {
    panel: u32,
    fg: u32,
    muted: u32,
    /// input fields and wells
    field: u32,
    /// the hairline edge and separators
    line: u32,
    hover: u32,
    /// secondary buttons
    secondary: u32,
    accent: u32,
    accent_fill: u32,
    accent_fill_hover: u32,
    on_accent: u32,
    destructive: u32,

    pub fn of(t: Theme) Opaque {
        const panel = color.over(t.window_bg, t.panel);
        return .{
            .panel = panel,
            .fg = t.fg,
            .muted = color.over(panel, t.muted),
            .field = color.over(panel, t.field),
            .line = color.over(panel, t.hairline),
            .hover = color.over(panel, t.hover),
            .secondary = color.over(panel, t.pressed),
            .accent = t.accent,
            .accent_fill = t.accent_fill,
            .accent_fill_hover = t.accent_fill_hover,
            .on_accent = t.on_accent,
            .destructive = t.destructive,
        };
    }
};

/// The two appearances before the accent is applied (Theme.get sets
/// every accent field from the system's accent).
const dark_base: Theme = .{
    .dark = true,
    .accent = default_accent,
    .accent_hover = default_accent,
    .accent_fill = default_accent,
    .accent_fill_hover = default_accent,
    .accent_text = default_accent,
    .fg = 0xFFF5F5F7,
    .muted = 0xBFEBEBF5,
    .material = 0xCC242426,
    .material_solid = 0xFF2C2C2E,
    .hairline = 0x1FFFFFFF,
    .hover = 0x14FFFFFF,
    .pressed = 0x24FFFFFF,
    .track = 0x1FFFFFFF,
    .seg_on = 0xFF636366,
    .bar_shadow = .{ .color = 0x47000000, .blur = 40, .dy = 12 },
    .popover_shadow = .{ .color = 0x52000000, .blur = 50, .dy = 18 },
    .loupe_shadow = .{ .color = 0x59000000, .blur = 22, .dy = 8 },
    .card_shadow = .{ .color = 0x52000000, .blur = 24, .dy = 8 },
    .window_bg = 0xFF242424,
    .header_bg = 0xFF2E2E32,
    .card = 0xFF363636,
    .line = 0x14FFFFFF,
    .chip = 0x1AFFFFFF,
    .switch_off = 0x2EFFFFFF,
    .text = 0xFFFFFFFF,
    .text_muted = 0x99FFFFFF,
    .view_sel = 0x1AFFFFFF,
    .panel = 0xCC242426,
    .field = 0x14FFFFFF,
    .destructive = 0xFFFF453A,
};

const light_base: Theme = .{
    .dark = false,
    .accent = default_accent,
    .accent_hover = default_accent,
    .accent_fill = default_accent,
    .accent_fill_hover = default_accent,
    .accent_text = default_accent,
    .fg = 0xFF1D1D1F,
    .muted = 0xCC3C3C43,
    .material = 0xCCF6F6F8,
    .material_solid = 0xFFF2F2F7,
    .hairline = 0x1A000000,
    .hover = 0x0D000000,
    .pressed = 0x1A000000,
    .track = 0x14000000,
    .seg_on = 0xFFFFFFFF,
    .bar_shadow = .{ .color = 0x38000000, .blur = 40, .dy = 12 },
    .popover_shadow = .{ .color = 0x42000000, .blur = 50, .dy = 18 },
    .loupe_shadow = .{ .color = 0x47000000, .blur = 22, .dy = 8 },
    .card_shadow = .{ .color = 0x42000000, .blur = 24, .dy = 8 },
    .window_bg = 0xFFFAFAFB,
    .header_bg = 0xFFFFFFFF,
    .card = 0xFFFFFFFF,
    .line = 0x14000006,
    .chip = 0x12000006,
    .switch_off = 0x26000006,
    .text = 0xCC000006,
    .text_muted = 0x99000006,
    .view_sel = 0x12000006,
    .panel = 0xDBFAFAFC,
    .field = 0x0D000000,
    .destructive = 0xFFFF3B30,
};

/// What the desktop asks for.
pub const Prefs = desktop.Appearance;

/// The Theme for the desktop's preferences.
pub fn of(p: Prefs) Theme {
    return Theme.get(p.dark, p.accent);
}

/// Ask the desktop for its appearance, waiting at most `timeout_ms`.
pub fn readPrefs(bus: *desktop.Bus, timeout_ms: i64) Prefs {
    return desktop.readAppearance(bus, timeout_ms);
}

/// The desktop's appearance, asked over a session of its own (waiting at
/// most `timeout_ms`); `Prefs{}` when the desktop cannot be reached. Sets
/// motion.enabled from it, so every process honours reduced motion.
/// `env` is the app's Env (app/env.zig), as desktop.connect takes it.
pub fn loadPrefs(gpa: std.mem.Allocator, env: anytype, timeout_ms: i64) Prefs {
    const p: Prefs = blk: {
        var bus = desktop.connect(gpa, env) catch break :blk .{};
        defer bus.deinit();
        break :blk readPrefs(&bus, timeout_ms);
    };
    motion_mod.enabled = p.animations;
    return p;
}

/// The Theme for the desktop's appearance (see loadPrefs).
pub fn load(gpa: std.mem.Allocator, env: anytype, timeout_ms: i64) Theme {
    return of(loadPrefs(gpa, env, timeout_ms));
}

/// Follow appearance changes (desktop.pump folds them into a Prefs).
pub fn watch(bus: *desktop.Bus) !void {
    return desktop.watchAppearance(bus);
}

pub const withAlpha = color.withAlpha;
pub const fade = color.fade;
pub const mix = color.mix;
pub const over = color.over;
pub const luminance = color.luminance;
pub const contrast = color.contrast;
pub const legible = color.legible;

/// The accent as a fill white text reads on (AA).
pub fn accentFill(accent: u32) u32 {
    return legible(accent, 0xFFFFFFFF, aa_text);
}

test "theme variants differ where they should" {
    const d = Theme.get(true, null);
    const l = Theme.get(false, 0xFF3584E4);
    try std.testing.expect(d.dark and !l.dark);
    try std.testing.expectEqual(default_accent, d.accent);
    try std.testing.expectEqual(@as(u32, 0xFF3584E4), l.accent);
    try std.testing.expect(d.fg != l.fg);
    try std.testing.expectEqual(@as(u32, 0x80FF0000), withAlpha(0xFFFF0000, 0x80));
    try std.testing.expectEqual(@as(u32, 0xFF808080), mix(0xFF000000, 0xFFFFFFFF, 0.5));
}

test "fills and text reach AA contrast, any accent" {
    for ([_]?u32{ null, 0xFF3584E4, 0xFFF6D32D, 0xFF2EC27E, 0xFFE01B24, 0xFF000000 }) |a| {
        for ([_]bool{ false, true }) |dark| {
            const t = Theme.get(dark, a);
            try std.testing.expect(contrast(t.on_accent, t.accent_fill) >= aa_text);
            try std.testing.expect(contrast(t.on_accent, t.accent_fill_hover) >= aa_text);
            try std.testing.expect(contrast(t.accent_text, t.window_bg) >= aa_text);
            try std.testing.expect(contrast(over(t.window_bg, t.text_muted), t.window_bg) >= aa_text);
        }
    }
    try std.testing.expect(contrast(0xFFFFFFFF, destructive_fill) >= aa_text);
    try std.testing.expect(contrast(0xFFFFFFFF, destructive_fill_hover) >= aa_text);
    // a colour that already reads is kept
    try std.testing.expectEqual(@as(u32, 0xFF1D1D1F), legible(0xFF1D1D1F, 0xFFFFFFFF, aa_text));
}

test "the opaque panel is the panel over the window, tints over that" {
    for ([_]bool{ false, true }) |dark| {
        const t = Theme.get(dark, null);
        const o = Opaque.of(t);
        try std.testing.expectEqual(@as(u32, 0xFF), o.panel >> 24);
        try std.testing.expectEqual(@as(u32, 0xFF), o.muted >> 24);
        try std.testing.expectEqual(@as(u32, 0xFF), o.line >> 24);
        try std.testing.expect(o.line != o.panel);
        try std.testing.expect(contrast(o.muted, o.panel) >= aa_text);
        try std.testing.expectEqual(t.accent_fill, o.accent_fill);
    }
}

test "the rooms hold the shadows in either appearance" {
    for ([_]bool{ false, true }) |dark| {
        const t = Theme.get(dark, null);
        try std.testing.expect(t.card_shadow.reach() <= card_room);
    }
    try std.testing.expectEqual(32, card_room);
    try std.testing.expectEqual(19, window_room);
}

test "scrim levels darken in order" {
    const t = Theme.get(true, null);
    var last: u32 = 0;
    inline for (@typeInfo(Scrim).@"enum".field_names) |n| {
        const a = t.scrim(@field(Scrim, n)) >> 24;
        try std.testing.expect(a > last);
        last = a;
    }
}
