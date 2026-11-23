# The capture modes (sourced by tools/e2e.sh's inner side, with its
# helpers). Every one runs with the Shotlet extension, which binds a
# shortcut per mode and starts the shotlet under test (modes_start).
#   modes-screen  Ctrl+Print (the monitor under the pointer), Ctrl+Shift+
#                 Print (all screens), Shift+Super+Print (the previous
#                 area); after_fullscreen copy, thumbnail, editor, save
#   modes-timer   `shotlet timer 3`: the shell's countdown, not captured
#   modes-window  Super+Print, click a window: exactly the window, its
#                 corners transparent; with the shadow around it
#   modes-keys    `shotlet gnome-integration shortcut MODE KEY`, and
#                 Settings
# (modes-strip: strip.sh; modes-scroll*: scroll.sh)

scenario_modes_screen() {
    modes_start Meta-0 Meta-1
    mode_cfg copy
    screen_monitors
    screen_previous
    screen_after
}

# a monitor, or all of them, copied with no editor
screen_monitors() {
    touch "$OUT/marker"
    # the pointer on the second monitor (1280x720, right of the first)
    drv move 1 640 360
    sleep 0.3
    drv key ctrl+print
    check "Ctrl+Print captures the monitor under the pointer" wait_until 10 clip_png "$OUT/screen.png"
    check "  ... all of it, and only it (1280x720)" eq "$(png_size "$OUT/screen.png")" 1280x720
    check "  ... the desktop's pixels" pixel_near "$OUT/screen.png" 640 400 "$DESKTOP_BG"
    check "  ... with no editor" no_log "startup: capture=" "$SHOTLET_E2E_SHELL_LOG"
    check "  ... and no consent dialog" no_dialog
    check "  ... the capture files gone" capture_dir_empty
    new_pngs | grep -v "/shotlet/history/" >"$OUT/new-pngs.txt"
    check "  ... and no PNG written but the history's" test ! -s "$OUT/new-pngs.txt"
    clip_set nothing
    drv move 0 800 450
    sleep 0.3
    drv key ctrl+print
    check "on the first monitor: that one (1600x900)" clip_is screen0 1600x900 10
    clip_set nothing
    ext_gap
    drv key ctrl+shift+print
    check "Ctrl+Shift+Print captures every monitor (2880x900)" clip_is all 2880x900 10
    clip_set nothing
    ext_gap
    # `shotlet fullscreen` from a terminal asks the extension too
    run_shotlet cli fullscreen
    check "shotlet fullscreen hands the capture to the extension" wait_exit 5
    check "  ... which copies the monitor" clip_is cli 1600x900 10
    clip_set nothing
    ext_gap
}

# the previous area: none yet, then the last selection copied
screen_previous() {
    free_print
    drv key print
    shell_editor 1
    drag 0 300 200 0 500 300 0 700 450
    keys enter
    check "an area copied in the editor (400x250)" clip_is area 400x250 5
    check "  ... is remembered for this monitor layout" test -s "$XDG_STATE_HOME/shotlet/last-area"
    clip_set nothing
    ext_gap
    drv key shift+super+print
    check "Shift+Super+Print opens the editor on it" shell_editor 2
    shot 0 previous
    keys enter
    check "  ... where Enter copies the same area" clip_is previous 400x250 5
    clip_set nothing
    ext_gap
}

_saved_png() { SAVED=$(ls "$HOME"/Pictures/shotlet-*.png 2>/dev/null | head -1); [ -n "$SAVED" ]; }
_saved_in_history() { grep -lq "saved=$HOME/Pictures/shotlet-" "$XDG_STATE_HOME"/shotlet/history/*/meta 2>/dev/null; }
# what a screen capture does next: the editor, the thumbnail, a file
screen_after() {
    mode_cfg editor
    drv key ctrl+print
    check "after_fullscreen=editor opens the editor" shell_editor 3
    keys enter
    check "  ... with the monitor selected" clip_is ed 1600x900 5
    ext_gap
    mode_cfg thumbnail
    drv key ctrl+print
    check "after_fullscreen=thumbnail shows the floating thumbnail" shell_wait 10 "quick access: showing" 1
    check "  ... and keeps the capture in the history" eval 'ls "$XDG_STATE_HOME"/shotlet/history/*/image.png >/dev/null 2>&1'
    check "  ... and copies it, like an area copied in the editor" clip_is thumb 1600x900 10
    clip_set nothing
    ext_gap
    # saved, like Save in the editor
    mode_cfg save
    drv key ctrl+print
    check "after_fullscreen=save writes the monitor to ~/Pictures" eval 'wait_until 10 _saved_png && eq "$(png_size "$SAVED")" 1600x900'
    check "  ... remembering where in the history" wait_until 5 _saved_in_history
}

scenario_modes_timer() {
    modes_start Meta-0
    mode_cfg copy
    local t0 t1
    t0=$(date +%s%N)
    run_shotlet timer timer 3
    check "shotlet timer 3 hands it to the extension" wait_exit 5
    sleep 1
    shot 0 countdown
    check "  ... which counts down on screen" eval 'drv pixel "$OUT/countdown.png" 770 420 && ! near "$VAL" "$DESKTOP_BG" 2>/dev/null'
    check "  ... and then opens the editor" shell_wait 10 "startup: capture=" 1
    t1=$(date +%s%N)
    check "  ... after about 3 s ($(((t1 - t0) / 1000000)) ms)" test $(((t1 - t0) / 1000000)) -ge 3000
    sleep 0.8
    drag 0 700 350 0 900 550
    keys enter
    check "the countdown is not in the capture" eval 'wait_until 5 clip_png "$OUT/timer.png" && pixel_near "$OUT/timer.png" 100 100 "$DESKTOP_BG"'
}

# the window under the pointer in the shell's picker: 0a84ff
scenario_modes_window() {
    modes_start Meta-0
    mode_cfg copy window_shadow=false
    require_pygtk || return
    TARGET_SIZE=640x480 start_app target || { fail "target window"; exit 1; }
    sleep 1
    drv key super+print
    check "Super+Print starts the window picker" shell_wait 10 "picking one of" 1
    drv move 0 790 440
    sleep 0.5
    shot 0 picker
    check "  ... the window under the pointer lights up" find_on 0 0a84ff 40 200
    click 0 800 450
    check "a click captures that window" wait_until 10 clip_png "$OUT/window.png"
    local ww wh
    read -r ww wh <<<"$(grep -o "captured a [0-9]*x[0-9]* window" "$SHOTLET_E2E_SHELL_LOG" | tail -1 | grep -o "[0-9]*x[0-9]*" | tr x ' ')"
    check "  ... exactly the window (${ww}x${wh})" eq "$(png_size "$OUT/window.png")" "${ww}x${wh}"
    check "  ... the size it asked for, give or take its frame" test "${ww:-0}" -ge 640 -a "${ww:-0}" -le 700
    drv pixel "$OUT/window.png" 0 0
    check "  ... its rounded corner see-through" test $((16#${VAL:0:2})) -lt 64
    drv pixel "$OUT/window.png" $((ww / 2)) $((wh / 2))
    check "  ... and its inside opaque" test "${VAL:0:2}" = ff
    check "  ... with no editor and no dialog" eval 'no_log "startup: capture=" "$SHOTLET_E2E_SHELL_LOG" && no_dialog'
    check "  ... and no PNG left behind" capture_dir_empty
    clip_set nothing
    ext_gap
    window_shadow "$ww" "$wh"
}

# window_shadow W H: the same window (W x H) with its shadow; Esc
window_shadow() {
    mode_cfg copy window_shadow=true
    drv key super+print
    shell_wait 10 "picking one of" 2
    click 0 800 450
    check "with the shadow: the window on a larger transparent canvas" wait_until 10 clip_png "$OUT/shadow.png"
    local s sw sh
    s=$(png_size "$OUT/shadow.png"); sw=${s%x*} sh=${s#*x}
    check "  ... (${sw}x${sh}, 56 px more each way)" eq "$sw $sh" "$(($1 + 56)) $(($2 + 56))"
    drv pixel "$OUT/shadow.png" 0 0
    check "  ... transparent at its corner" test "${VAL:0:2}" = 00
    drv pixel "$OUT/shadow.png" $((sw / 2)) $((sh - 20))
    check "  ... a soft shadow below the window" eval 'a=$((16#${VAL:0:2})); test $a -gt 0 -a $a -lt 255'
    ext_gap
    drv key super+print
    shell_wait 10 "picking one of" 3
    keys esc
    sleep 1 # (nothing would log a capture that never happens)
    check "Esc in the picker cancels" eq "$(shell_count "captured a ")" 2
}

scenario_modes_keys() {
    modes_start Meta-0
    mode_cfg copy
    keys_cli
    keys_settings
    # a mode key that GNOME's screenshot tool holds stays unbound
    ext_gsettings set fullscreen-shortcut "['<Shift>Print']"
    sleep 0.5
    "$BIN" gnome-integration shortcut >"$OUT/status.log" 2>&1
    check "a key GNOME's screenshot tool holds stays unbound (and says so)" grep -q "fullscreen.*GNOME" "$OUT/status.log"
}

keys_cli() {
    "$BIN" gnome-integration shortcut window '<Ctrl><Alt>w' >"$OUT/set.log" 2>&1
    check "gnome-integration shortcut window KEY sets that mode's key" eq "$(ext_gsettings get window-shortcut)" "['<Ctrl><Alt>w']"
    sleep 0.5 # (the extension rebinds it)
    drv key ctrl+alt+w
    check "  ... which starts the window picker" shell_wait 10 "picking one of" 1
    keys esc
    "$BIN" gnome-integration shortcut screens none >>"$OUT/set.log" 2>&1
    check "  ... none unbinds it" eq "$(ext_gsettings get screens-shortcut)" "@as []"
    ext_gap
    drv key ctrl+shift+print
    sleep 2 # (nothing would log a capture that never happens)
    check "  ... and its old key does nothing" no_log "capture mode: 2880" "$SHOTLET_E2E_SHELL_LOG"
}

# Settings: the after-capture choice, and recording a mode's key
keys_settings() {
    SHOTLET_SETTINGS_FOCUS=15 run_shotlet settings settings
    wait_log 10 "keyboard focus"
    sleep 1.2 # the window fades in and is raised by the extension
    keys space
    check "Settings cycles what a screen capture does" wait_log 3 "^after_fullscreen=save" "$(cfg_path)"
    keys esc
    wait_exit 5
    SHOTLET_SETTINGS_VIEW=shortcuts SHOTLET_SETTINGS_FOCUS=1 run_shotlet settings-keys settings
    wait_log 10 "keyboard focus"
    sleep 0.5
    keys enter
    sleep 0.3
    keys ctrl+shift+f
    sleep 1
    check "Settings records a capture mode's shortcut" eq "$(ext_gsettings get fullscreen-shortcut)" "['<Ctrl><Shift>f']"
    keys esc
    wait_exit 5
}
