# The capture modes in the container suite (sourced by scenarios.sh, with
# lib.sh's helpers):
#   modes  `shotlet fullscreen` and `shotlet screens` copy without the
#          editor, through direct capture; `shotlet window` is KWin's
#          window picker (ScreenShot2.CaptureInteractive, authorized by
#          the installed desktop entry), and on wlroots an area selection
#          with a note that windows are not offered. Then the editor's
#          mode strip, and a click on a window selecting it on KWin (on
#          wlroots, the monitor). The area's gestures (area_steps) in the
#          editor, the recording picker and the scrolling capture's. Last,
#          `shotlet scroll`: the region picker (direct capture), and with
#          SHOTLET_NO_DIRECT=1 the notice that it cannot run here, exit 1.

scenario_modes() {
    cfg_write thumbnail=never after_fullscreen=copy window_shadow=false
    check "a window to capture is up" start_app droptarget
    modes_fullscreen
    modes_window
    modes_area
    modes_gestures
    modes_scroll
}

modes_fullscreen() {
    run_shotlet fullscreen fullscreen
    check "shotlet fullscreen captures directly, with no editor" wait_log 15 "capture copied to the clipboard"
    check "  ... the whole screen on the clipboard (${MW}x${MH})" clip_is full "${MW}x${MH}"
    check "  ... showing the window on screen" pixel_near "$OUT/full.png" $((MW / 2)) $((MH / 2)) "$APP_BG"
    stop_shotlet
}

modes_window() {
    run_shotlet window window
    if [ "$COMP" = kwin ]; then
        sleep 2 # (KWin's picker takes the pointer a while after the call; nothing tells when)
        click 0 $((MW / 2)) $((MH / 2))
        check "shotlet window: KWin's picker, a click captures the window" wait_log 15 "capture copied to the clipboard"
        check "  ... by KWin's ScreenShot2" grep -q "window capture: KWin gave" "$SHOT_LOG"
        check "  ... the window's own pixels" eval 'clip_png "$OUT/window.png" && pixel_near "$OUT/window.png" 100 100 "$APP_BG"'
    else
        check "shotlet window: no windows to pick on $COMP, an area instead" wait_editor 15
        check "  ... saying so" grep -q "window capture: not offered here" "$SHOT_LOG"
        keys esc
    fi
    stop_shotlet
}

# the chosen mode in the strip at the bottom: the accent's darker fill
# (Shotlet's default blue, or Breeze's on KDE, read from the portal)
_strip_shown() {
    find_on 0 "$STRIP_FILL" 24 20 0 $((MH - 140)) "$MW" "$MH" ||
        find_on 0 "$BREEZE_FILL" 24 20 0 $((MH - 140)) "$MW" "$MH"
}
# area capture: the mode strip, and a click on a window selects it where
# the compositor says where windows are (KWin, through a one-off script)
modes_area() {
    local wsize
    run_shotlet area area
    check "shotlet: the editor for an area" wait_editor 15
    shot 0 strip
    check "  ... with the mode strip at the bottom (Area chosen)" wait_until 3 _strip_shown
    click 0 $((MW / 2)) $((MH / 2))
    if [ "$COMP" = kwin ]; then
        check "  ... KWin said where the windows were" grep -qE "windows: [1-9][0-9]* where the capture was taken" "$SHOT_LOG"
        check "  ... a click selects the window under it" wait_log 5 "window clicked: "
        keys enter
        wsize=$(grep -o "window clicked: [0-9]*x[0-9]*" "$SHOT_LOG" | tail -1 | grep -o "[0-9]*x[0-9]*")
        check "  ... and Enter copies exactly it (${wsize:-?})" clip_is winclick "$wsize" 5
    else
        check "  ... no windows to click on $COMP: a click takes the monitor" wait_log 5 "monitor clicked: ${MW}x${MH} at 0,0"
        check "  ... not a window" no_log "window clicked: "
        keys esc
    fi
    stop_shotlet
}

# area_steps: one area through every gesture (ui/areasel.zig, the same in
# each picker): drawn out, a corner dragged, moved from inside, nudged by
# the arrows (Shift: 10 px, Ctrl: resize from the bottom-right corner;
# Ctrl, not Alt, which labwc keeps for MoveToEdge); Enter takes exactly
# 501,310 601x400
area_steps() {
    slow_drag 0 400 250 650 425 900 600
    slow_drag 0 900 600 1000 650
    slow_drag 0 700 450 800 500
    keys right shift+down ctrl+right
    sleep 0.3
    keys enter
}

# the gestures in the editor, the recording picker (the area it hands on,
# not the recording) and the scrolling capture's picker
modes_gestures() {
    run_shotlet gestures area
    check "the editor's area" wait_editor 15
    area_steps
    check "  ... dragged, resized, moved, nudged: Enter copies exactly 601x400" clip_is gestures 601x400 5
    stop_shotlet
    run_shotlet rec-pick record --gif --seconds 1 --no-countdown --no-control
    check "the recording picker" wait_log 15 "picker up"
    sleep 1 # (the picker takes the keyboard a moment after it logs)
    area_steps
    check "  ... the same gestures: Enter records 501,310 601x400" wait_log 5 "picked 501,310 601x400"
    stop_shotlet
    run_shotlet scroll-pick scroll
    check "the scrolling capture's picker" wait_log 15 "scrolling capture: pick a region"
    sleep 1
    area_steps
    check "  ... the same gestures: Enter scrolls 601x400 at 501,310" wait_log 5 "region 601x400 at 501,310"
    stop_shotlet
}

# a scrolling capture: direct capture here, so the region picker; with
# direct capture turned off nothing captures while the person scrolls:
# it says so before any picker, and exits 1
modes_scroll() {
    run_shotlet scroll scroll
    check "shotlet scroll: the region picker (direct capture)" wait_log 15 "scrolling capture: pick a region"
    sleep 1 # (the picker takes the keyboard a moment after it logs)
    keys esc
    check "  ... Esc cancels it" wait_exit 10
    SHOTLET_NO_DIRECT=1 run_shotlet scroll-off scroll
    check "without direct capture, shotlet scroll exits 1" eval 'wait_exit 10 && eq "$RC" 1'
    check "  ... saying why on stderr" grep -qF "shotlet scroll: Scrolling capture isn’t available here. This desktop doesn’t let Shotlet capture while you scroll." "$SHOT_LOG"
    check "  ... and on the screen" wait_log 10 "toast: Scrolling capture isn.t available here"
    check "  ... no region picker" no_log "pick a region" "$SHOT_LOG"
}
