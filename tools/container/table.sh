# The container suite's scenarios, one row each: the runner (run.sh) picks
# the runs from it, the session (inner.sh) its outputs and capture paths.
# Each NAME is a scenario_NAME function (dashes as underscores) in
# scenarios/*.sh. `tools/container/run.sh --list` prints it.
#
# compositors  where `all` runs it (- : only when asked for, COMP:NAME)
# monitors     the outputs, WxH[@SCALE][/TRANSFORM] each (E2E_MONITORS
#              overrides them)
# flags        gpu     needs a GPU render node (the portal's screencast,
#                      which xdg-desktop-portal-wlr serves from dmabufs);
#                      KWin always does (it offers screenshots and
#                      screencasts only when compositing with OpenGL)
#              portal  direct capture off: SHOTLET_NO_DIRECT=1 on wlroots;
#                      on KWin Shotlet is not installed, so it has no
#                      .desktop file and KWin refuses it
scenario_table() {
    cat <<'EOF_TABLE'
probe     | -               | 1600x900                         | -          | debugging: wayland-info, the outputs, a screenshot; runs $CTR_PROBE
capture   | sway labwc kwin | 1600x900                         | -          | direct capture, no dialog: the selection copied, the window in it
multimon  | sway labwc kwin | 1600x900 1280x720@2              | -          | two outputs (wlroots: scale 1 and 2): the editor on both, each copies its own pixels
rotated   | sway            | 1600x900/90 1280x720/flipped-180 | -          | turned and flipped outputs come out the way they show
portal    | sway labwc kwin | 1600x900                         | gpu portal | the ScreenCast portal when direct capture is off; the restore token skips the chooser after
record    | sway            | 1600x900                         | gpu portal | a GIF recording through the portal, then one with no chooser (restore token)
quick     | sway labwc kwin | 1600x900                         | -          | the thumbnail: a layer surface, the keyboard stays with the app, Copy, drag and drop
pin       | sway labwc kwin | 1600x900                         | -          | pins: 1:1 at their place, above the app, dragged, --at, the menu, Close All Pins
history   | sway labwc kwin | 1600x900                         | -          | Recent captures: lists, copies, closes, exits once another app copies
ocr       | sway            | 1600x900                         | -          | the history searched by text (Tesseract): every word, accents folded
modes     | sway kwin       | 1600x900                         | -          | shotlet fullscreen, window (KWin's picker), the mode strip, a click on a window, scroll
ocr-tools | sway            | 1600x900                         | -          | shotlet text, Copy text and Redact in the editor
EOF_TABLE
}

COMPOSITORS="sway labwc kwin"

# scenario_row NAME: its row in S_COMPS, S_MONS, S_FLAGS, S_DESC; false
# for no such scenario
scenario_row() {
    local n c m f d
    while IFS='|' read -r n c m f d; do
        [ "$(_trim "$n")" = "$1" ] || continue
        S_COMPS=$(_trim "$c") S_MONS=$(_trim "$m") S_FLAGS=$(_trim "$f") S_DESC=$(_trim "$d")
        return 0
    done < <(scenario_table)
    return 1
}
# scenario_flag FLAG: the row scenario_row read has it
scenario_flag() { case " $S_FLAGS " in *" $1 "*) return 0 ;; esac; return 1; }
# scenarios_on COMP: the scenarios `all` runs there, in table order
scenarios_on() {
    local n c rest
    while IFS='|' read -r n c rest; do
        case " $(_trim "$c") " in *" $1 "*) _trim "$n"; echo ;; esac
    done < <(scenario_table)
}
