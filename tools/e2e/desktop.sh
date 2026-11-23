# Desktop helpers of tools/e2e.sh's inner side (sourced after lib.sh):
# the GNOME integration, the desktop, other apps and the thumbnail.

# --- the GNOME integration's captures: the shell starts shotlet, whose
# output lands in the compositor log
shell_count() { grep -c "$1" "$SHOTLET_E2E_SHELL_LOG" 2>/dev/null; }
_shell_count_ge() { [ "$(shell_count "$1")" -ge "$2" ]; }
shell_wait() { wait_until "$1" _shell_count_ge "$2" "$3"; } # shell_wait SECS PATTERN COUNT: until PATTERN shows COUNT times
# shell_editor N [SECS]: the Nth editor the shell started is up (as
# wait_editor: then a pause until it takes input, which nothing logs)
shell_editor() { shell_wait "${2:-10}" "startup: capture=" "$1" && sleep 0.8; }
# ext_gap: the extension takes at most one capture a second
ext_gap() { sleep 1.1; }
ext_gsettings() { # ext_gsettings get|set KEY [VALUE]: the extension's settings
    gsettings --schemadir "$XDG_DATA_HOME/gnome-shell/extensions/$EXT_UUID/schemas" \
        "$1" org.gnome.shell.extensions.shotlet "${@:2}"
}
shell1_prop() {
    gdbus call --session --dest dev.shotlet.Shell1 --object-path /dev/shotlet/Shell1 \
        --method org.freedesktop.DBus.Properties.Get dev.shotlet.Shell1 "$1" 2>/dev/null
}
_mode_keys_bound() { shell1_prop ModeShortcuts | grep -q "fullscreen="; }
# modes_start MON...: the driver, the extension pointed at this shotlet
# on a plain desktop, the pointer in the middle of monitor 0
modes_start() {
    drv_ready "$@"
    drv move 0 800 450
    ext_gsettings set shotlet-path "'$BIN'"
    plain_desktop
    # the extension is up (its keys bound) once it owns its bus name
    wait_until 10 _mode_keys_bound
    sleep 0.5 # (and the shell grabs the keys a moment later)
}
# mode_cfg AFTER [KEY=VALUE...]: Shotlet's settings for the capture modes
mode_cfg() { cfg_write thumbnail=never "after_fullscreen=$1" "${@:2}"; }
# every file written since $OUT/marker under HOME, the runtime dir,
# /dev/shm and right in /tmp (other tools' trees below /tmp are not
# ours) that is a PNG: the capture must never be one of them
new_pngs() {
    { find "$HOME" "$XDG_RUNTIME_DIR" /dev/shm -xdev -newer "$OUT/marker" -type f -user "$(id -u)" 2>/dev/null
      find /tmp -maxdepth 1 -newer "$OUT/marker" -type f -user "$(id -u)" 2>/dev/null; } |
        while read -r f; do is_png "$f" && echo "$f"; done
}
no_dialog() { # the portal's consent dialogs never came up
    eq "$(perm_apps screencast)$(perm_apps screenshot)" "" &&
        ! grep -qiE "screencast|screenshot portal" "$SHOTLET_E2E_SHELL_LOG" "$OUT"/*.log 2>/dev/null
}
capture_dir_empty() { [ -z "$(ls -A "$XDG_RUNTIME_DIR/shotlet" 2>/dev/null)" ]; }
# a plain blue desktop: known content to find in the capture
plain_desktop() {
    gsettings set org.gnome.desktop.background picture-uri ''
    gsettings set org.gnome.desktop.background picture-uri-dark ''
    gsettings set org.gnome.desktop.background picture-options none
    gsettings set org.gnome.desktop.background color-shading-type solid
    gsettings set org.gnome.desktop.background primary-color "#$DESKTOP_BG"
}
# the extension's key: GNOME's screenshot UI holds Print by default, so
# the extension leaves it alone; tests give Print to the extension
free_print() {
    gsettings set org.gnome.shell.keybindings show-screenshot-ui "[]"
    sleep 0.5 # (the shell rebinds its keys a moment later)
}

# start_page HEIGHT [CTL]: tools/e2e/scrolltarget.py, a GTK page HEIGHT
# px long (CTL: a file it takes commands from), its log $OUT/page.log;
# its viewport's height in VP once it is up
start_page() {
    : >"$OUT/page.log"
    "$PYGTK" "$ROOT/tools/e2e/scrolltarget.py" "$@" >>"$OUT/page.log" 2>>"$OUT/page.err" &
    VP=
    wait_log 10 "^viewport" "$OUT/page.log" || return 1
    sleep 1 # (mapped and focused a moment after it logs its size)
    VP=$(grep "^viewport" "$OUT/page.log" | tail -1 | cut -d' ' -f2)
}

# drag the newest card out by hand, up and over to the middle of monitor 0
drag_card_out() {
    read -r x y <<<"$(card_point 120 75)"
    slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
}
# a real capture (through the portal) with a red filled rectangle drawn
# in it, copied with Enter
red_capture() { # red_capture NAME [first]
    run_shotlet "$1"
    if [ "${2:-}" = first ]; then share_dialog 0 || return 1; fi
    wait_editor 10 || return 1
    drag 0 400 200 0 700 400 0 900 500
    keys r f
    drag 0 500 300 0 650 380 0 800 420
    sleep 0.3
    keys enter
}
