# The editor's mode strip and window clicks (sourced by tools/e2e.sh's
# inner side, with its helpers), the Shotlet extension taking the
# captures:
#   modes-strip  Print: the strip at the bottom centre, Area chosen; a
#                window lit under the pointer, a click selects exactly it,
#                a drag still draws an area; the strip's letters (O text,
#                G area, D screen, Q record) and its Window button; the
#                More menu without capture modes; light and dark
# The chosen mode and the toolbar's Copy wear ACCENT_FILL, a lit window's
# outline ACCENT.

scenario_modes_strip() {
    modes_start Meta-0
    mode_cfg copy
    require_pygtk || return
    TARGET_SIZE=640x480 start_app target || { fail "target window"; exit 1; }
    free_print
    wait_until 2.5 _print_ours
    sleep 0.5
    strip_window_click
    strip_drag
    strip_keys
    strip_menu
    strip_dark
}
# the extension holds Print (each try gives it Print again, and waits)
_print_ours() { shell1_prop Shortcuts | grep -q Print && return 0; free_print; return 1; }

# strip_open N: Print, until the Nth editor is up, the pointer on the
# desktop (no window lit)
strip_open() {
    ext_gap
    drv move 0 200 120
    drv key print
    shell_editor "$1"
}
# the strip's chosen button (the accent fill low on the screen): x y w h
strip_chosen() { find_on 0 "$ACCENT_FILL" 24 20 400 780 1200 900; }

strip_window_click() {
    local sx sy dim ww=0 wh=0
    strip_open 1
    check "Print opens the editor knowing where the windows were" shell_wait 5 "windows: [1-9][0-9]* where the capture was taken" 1
    shot 0 strip
    check "  ... the mode strip at the bottom centre, Area chosen" eval 'strip_chosen && read -r sx sy _ <<<"$VAL" && test "$sy" -gt 780 -a "$sx" -lt 800'
    drv pixel "$OUT/strip.png" 800 450; dim=${VAL:-}
    drv move 0 790 440
    sleep 0.4
    shot 0 hover
    check "the window under the pointer lights up (accent outline)" find_on 0 "$ACCENT" 30 300
    drv pixel "$OUT/hover.png" 800 450
    check "  ... bright, the rest dimmed" test "$VAL" != "$dim"
    click 0 800 450
    check "a click selects exactly that window" shell_wait 5 "window clicked: " 1
    sleep 0.5
    shot 0 clicked
    check "  ... the strip gone for the toolbar" eval '! strip_chosen'
    keys enter
    read -r ww wh <<<"$(grep -o "window clicked: [0-9]*x[0-9]*" "$SHOTLET_E2E_SHELL_LOG" | tail -1 | grep -o "[0-9]*x[0-9]*" | tr x ' ')"
    check "  ... and Enter copies it (${ww}x${wh}, the window's frame)" eval 'clip_is win "${ww}x${wh}" 5 && test "${ww:-0}" -ge 640 -a "${ww:-0}" -le 700'
    clip_set nothing
}

strip_drag() {
    strip_open 2
    drag 0 700 400 0 800 470 0 900 550
    keys enter
    check "a drag over a window still selects a free area (200x150)" clip_is drag 200x150 5
    clip_set nothing
}

strip_keys() {
    local ax=0 ay=0
    strip_open 3
    keys o
    check "O switches to text capture, in place" shell_wait 3 "capture mode: text" 1
    keys g
    check "G back to area" shell_wait 3 "capture mode: area" 1
    keys d
    check "D captures the monitor under the pointer, as after_fullscreen says" clip_is screen 1600x900 10
    clip_set nothing
    strip_open 4
    keys q
    check "Q hands this capture to the recording picker" shell_wait 10 "record: picker up" 1
    sleep 0.6
    shot 0 record-picker
    keys esc
    check "  ... which Esc cancels" shell_wait 5 "record: cancelled in the picker" 1
    strip_open 5
    strip_chosen && read -r ax ay _ <<<"$VAL"
    click 0 $((ax + 38)) "$ay"
    check "the strip's Window starts the window picker" shell_wait 10 "picking one of" 1
    keys esc
}

strip_menu() {
    local cx=0 cy=0 cw=0
    strip_open 6
    drag 0 400 200 0 800 350 0 1200 500
    sleep 0.6
    # More is left of Copy (the accent fill at the toolbar's right end)
    find_on 0 "$ACCENT_FILL" 24 20 800 500 1600 900 && read -r cx cy cw _ <<<"$VAL"
    click 0 $((cx - cw / 2 - 23)) "$cy"
    sleep 0.5
    shot 0 menu
    check "the More menu opens, without the capture modes" test -s "$OUT/menu.png"
    keys esc esc esc
}

strip_dark() {
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    sleep 0.5
    strip_open 7
    shot 0 strip-dark
    drv move 0 790 440
    sleep 0.4
    shot 0 hover-dark
    check "dark: the strip and the lit window too" eval 'strip_chosen && find_on 0 "$ACCENT" 30 300'
    keys esc
    gsettings set org.gnome.desktop.interface color-scheme default
}
