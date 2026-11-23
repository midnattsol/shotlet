# Scrolling captures through the extension (sourced by tools/e2e.sh's
# inner side, with its helpers), of a long GTK page (start_page):
#   modes-scroll         Ctrl+Super+Print: scrolled and stitched to the
#                        right height, the marker once
#   modes-scroll-manual  scroll_auto=false: the person scrolls, Shotlet
#                        follows, a jump warns, Stop ends it
#   modes-scroll-stops   light: a page whose wheel does nothing pauses
#                        with "didn't move" (C continues to the end); one
#                        that jumps pauses with "couldn't match" (Continue,
#                        then scrolling back lines it up and keeps what was
#                        stitched); the height limit; Esc cancels a pause
#   modes-scroll-dark    the same in the dark appearance
# The stops film each state of the control into $OUT/hud-*.png (the card
# cropped out with ImageMagick when it is there).

# the control's bottom row (its buttons: Stop, Continue in ACCENT_FILL),
# the control right of a region at 300,300 600x400: away from the page
# in its preview
HUD_ROW="896 600 1200 660"
PAGE_H=3000

# scroll_pick N: Ctrl+Super+Print opens the Nth region picker, where
# 300,300 600x400 is picked
scroll_pick() {
    drv key ctrl+super+print
    shell_wait 10 "scrolling capture: pick a region" "$1" || return 1
    sleep 2 # (the picker takes the pointer a while after it logs)
    drag 0 300 300 0 600 500 0 900 700
    sleep 0.3
}
# the stitched picture's expected height: the region's, plus the rest of
# the page below what the viewport showed
stitched_h() { echo $((400 + PAGE_H - ${VP:-0})); }
# near_h H WANT: within 2 px
near_h() { test "${1:-0}" -ge $(($2 - 2)) -a "${1:-0}" -le $(($2 + 2)); }

scenario_modes_scroll() {
    modes_start Meta-0
    mode_cfg copy
    require_pygtk || return
    start_page "$PAGE_H"
    check "a long page is up (viewport ${VP:-?} px)" test -n "$VP"
    check "Ctrl+Super+Print opens the region picker" scroll_pick 1
    shot 0 region
    keys enter
    check "Enter starts scrolling the region" shell_wait 10 "scrolling capture of 600x400" 1
    check "  ... the page scrolls by itself" wait_log 10 "^scrolled [1-9]" "$OUT/page.log"
    sleep 1
    shot 0 scrolling
    check "  ... beside the control showing it grow" find_on 0 "$ACCENT_FILL" 24 100 $HUD_ROW
    check "it stops at the end of the page, and says so" shell_wait 60 "stopped: end_of_page (Reached the end of the page)" 1
    check "  ... and opens the tall image in the editor" shell_wait 10 "startup: capture=" 1
    check "  ... the virtual pointer gone with the session" shell_wait 5 "scrolling capture ended" 1
    sleep 1
    scroll_editor
}

# the tall picture in the editor: full size, scrolled, copied
scroll_editor() {
    local before s tw th want
    shot 0 editor
    drv pixel "$OUT/editor.png" 520 450
    check "  ... at full size, not shrunk to fit (600 px wide)" test "${VAL:2:6}" != 101010
    drv pixel "$OUT/editor.png" 800 450; before=$VAL
    drv move 0 800 450
    drv wheel 8
    sleep 0.8
    shot 0 editor-scrolled
    drv pixel "$OUT/editor-scrolled.png" 800 450
    check "  ... where the wheel scrolls it" test "$VAL" != "$before"
    keys enter
    check "Enter copies the stitched image" wait_until 10 clip_png "$OUT/tall.png"
    s=$(png_size "$OUT/tall.png"); tw=${s%x*} th=${s#*x}
    want=$(stitched_h)
    check "  ... ${tw}x${th}: the region's width" eq "$tw" 600
    check "  ... and the page's height through the region (~$want)" near_h "$th" "$want"
    check "  ... the marker band exactly once" eq "$(drv runs "$OUT/tall.png" 5 ff00ff 8 && echo "$VAL")" 1
}

scenario_modes_scroll_manual() {
    modes_start Meta-0
    mode_cfg copy scroll_auto=false
    require_pygtk || return
    start_page "$PAGE_H" "$OUT/page.ctl"
    scroll_pick 1
    keys enter
    check "the region is captured while the person scrolls" shell_wait 10 "the person scrolls" 1
    sleep 1
    local i at bx by s mh
    for i in $(seq 1 10); do drv move 0 600 500; drv wheel 2; sleep 0.6; done
    check "  ... the page moved by hand" grep -q "^scrolled [1-9]" "$OUT/page.log"
    shot 0 manual-running
    # too far in one go: a warning, and scrolling back lines it up again
    at=$(grep "^scrolled" "$OUT/page.log" | tail -1 | cut -d' ' -f2)
    echo "goto 2500" >"$OUT/page.ctl"
    check "  ... a jump past what lines up warns: couldn't match" shell_wait 10 "warning: no_match (Couldn" 1
    shot 0 manual-warning
    echo "goto $((${at:-0} + 40))" >"$OUT/page.ctl"
    check "  ... scrolling back lines it up again" shell_wait 10 "lined up again" 1
    find_on 0 "$ACCENT_FILL" 24 100 $HUD_ROW && read -r bx by _ <<<"$VAL"
    check "Stop on the control ends it" eval 'click 0 "$bx" "$by" && shell_wait 15 "startup: capture=" 1'
    check "  ... logged as the person's stop" shell_wait 2 "stopped: user_stopped" 1
    sleep 1
    keys enter
    check "  ... and the editor copies what was scrolled" wait_until 10 clip_png "$OUT/manual.png"
    s=$(png_size "$OUT/manual.png"); mh=${s#*x}
    check "  ... taller than the region (${s})" test "${mh:-0}" -gt 800
    check "  ... with no part twice (the marker at most once)" test "$(drv runs "$OUT/manual.png" 5 ff00ff 8 && echo "$VAL")" -le 1
}

# --- why a scrolling capture stops (STOPS_SCHEME light or dark)
scenario_modes_scroll_stops() { scroll_stops light; }
scenario_modes_scroll_dark() { scroll_stops dark; }

scroll_stops() {
    STOPS_SCHEME=$1 PICKS=0 EDITORS=0 CTL=$OUT/page.ctl
    modes_start Meta-0
    gsettings set org.gnome.desktop.interface color-scheme "$([ "$1" = dark ] && echo prefer-dark || echo default)"
    mode_cfg copy
    require_pygtk || return
    : >"$CTL"
    start_page "$PAGE_H" "$CTL"
    check "a long page is up (viewport ${VP:-?} px, $1)" test -n "$VP"
    stops_didnt_move
    stops_no_match
    stops_limit
    stops_esc
}

hud_shot() { # hud_shot NAME: the screen, and the control cropped from it
    shot 0 "hud-$1-$STOPS_SCHEME"
    command -v convert >/dev/null &&
        convert "$OUT/hud-$1-$STOPS_SCHEME.png" -crop 304x396+896+280 +repage "$OUT/hud-$1-$STOPS_SCHEME-card.png" 2>/dev/null
    return 0
}
page_mode() { # page_mode MODE: the page back at the top, then misbehaving
    echo "goto 0" >"$CTL"
    sleep 0.4
    echo "$1" >"$CTL"
    sleep 0.3
}
stops_start() { # pick the region and start
    PICKS=$((PICKS + 1))
    scroll_pick $PICKS || { fail "the region picker ($PICKS)"; return 1; }
    keys enter
}
copy_result() { # copy_result NAME: the editor opened on it; Enter copies it
    EDITORS=$((EDITORS + 1))
    shell_wait 10 "startup: capture=" $EDITORS || return 1
    sleep 1
    keys enter
    wait_until 10 clip_png "$OUT/$1.png"
}
# continue_at: the Continue button (the accent, narrower than Stop); its
# centre in CX, CY
continue_at() {
    local cw
    find_on 0 "$ACCENT_FILL" 24 40 $HUD_ROW && read -r CX CY cw _ <<<"$VAL" && [ "$cw" -lt 120 ]
}
# stitched_ok NAME: the copy NAME.png has the whole page's height
stitched_ok() {
    local h
    h=$(png_size "$OUT/$1.png"); h=${h#*x}
    check "  ... ${h} px tall" near_h "$h" "$(stitched_h)"
}

# the wheel does nothing: paused, saying so; C carries on to the end
stops_didnt_move() {
    page_mode lock
    stops_start
    check "a page that does not move pauses the capture" shell_wait 20 "stopped: didnt_move (The page didn" 1
    sleep 0.5
    hud_shot paused-didnt-move
    check "  ... offering Continue beside Finish and Cancel" continue_at
    : >"$CTL"
    sleep 0.3
    keys c
    check "  ... C continues" shell_wait 5 "continuing after didnt_move" 1
    check "  ... to the end of the page" shell_wait 60 "stopped: end_of_page (Reached the end of the page)" 1
    sleep 0.2
    hud_shot done-end
    check "  ... and the editor has all of it (~$(stitched_h) px)" copy_result end
    stitched_ok end
    clip_set nothing
    ext_gap
}

# every notch jumps two views: nothing lines up; Continue, then scrolling
# back a little lines it up, keeping what was stitched
stops_no_match() {
    page_mode jump
    stops_start
    check "a page that jumps pauses: couldn't match" shell_wait 30 "stopped: no_match (Couldn" 1
    sleep 0.5
    hud_shot paused-no-match
    if continue_at; then
        check "  ... Continue on the control" eval 'click 0 "$CX" "$CY" && shell_wait 5 "continuing after no_match" 1'
    else
        fail "  ... Continue on the control"
    fi
    sleep 0.6
    hud_shot realign
    echo "goto 100" >"$CTL"
    check "  ... scrolling back lines it up again" shell_wait 10 "lined up again" 1
    check "  ... and it goes on to the end" shell_wait 60 "stopped: end_of_page" 2
    check "  ... the editor has the whole page (~$(stitched_h) px)" copy_result jumped
    stitched_ok jumped
    check "  ... the marker band exactly once" eq "$(drv runs "$OUT/jumped.png" 5 ff00ff 8 && echo "$VAL")" 1
    clip_set nothing
    ext_gap
}

# the height limit (scroll_max_height=1000)
stops_limit() {
    mode_cfg copy scroll_max_height=1000
    page_mode ""
    stops_start
    sleep 1.2
    hud_shot running
    check "the height limit stops it, saying so" shell_wait 30 "stopped: height_limit (Stopped at the 1" 1
    sleep 0.2
    hud_shot done-limit
    check "  ... and the editor has 1000 px" eval 'copy_result limit && eq "$(png_size "$OUT/limit.png")" 600x1000'
    clip_set nothing
    ext_gap
}

# Esc on a pause cancels: no editor
stops_esc() {
    mode_cfg copy
    page_mode lock
    stops_start
    shell_wait 20 "stopped: didnt_move" 2
    sleep 0.3
    keys esc
    check "Esc on a pause cancels" shell_wait 5 "scrolling capture: cancelled" 1
    sleep 2 # (nothing would log an editor that never opens)
    check "  ... with no editor" eq "$(shell_count "startup: capture=")" "$EDITORS"
}

# --- scrolling captures on HiDPI monitors, at their physical pixels:
#   modes-scroll-mixed  3456x2160 at 2 beside 3840x2160 at 1.5 (primary),
#                       the region on the 1.5 one (each scroll a half
#                       physical pixel off: matched by the rows' profiles,
#                       app/scroll/nearmatch.zig); then all of that
#                       monitor, the control over it
# The region starts at physical x 1024 of the 1.5 monitor: 682.67
# logical, an odd edge after rounding, half a pixel into the monitor;
# the region asked of the shell grows to whole pixels (even logical
# edges). scroll_hidpi also takes one monitor ("scroll_hidpi 0 1.5 1024
# 2764 Meta-0=1.5" on a 3840x2160 row, "scroll_hidpi 0 2 1024 2000
# Meta-0=2" on a 3456x2160 one) to tell the scale from the mix.
scenario_modes_scroll_mixed() {
    scroll_hidpi 1 1.5 1024 2764 Meta-0=2 Meta-1=1.5! || return
    scroll_cover 1
}

# whole_px SCALE V...: every V a whole number of physical pixels at SCALE
whole_px() {
    "$E2E_PYTHON" -c "import sys; s=float(sys.argv[1]); sys.exit(any(abs(int(v)*s-round(int(v)*s))>1e-3 for v in sys.argv[2:]))" "$@"
}

# loop_away TITLE: the longest the window titled TITLE last stayed away
# from the compositor, ms (its SHOTLET_LOOP_STATS line as it closed)
loop_away() {
    grep -o "loop: $1: .*longest away from the socket [0-9]* ms" "$SHOTLET_E2E_SHELL_LOG" | tail -1 |
        sed 's/.*socket \([0-9]*\) ms/\1/'
}
# answered TITLE MS: it never kept the compositor's pings waiting MS
# (GNOME asks to force quit after 5 s)
answered() { local a; a=$(loop_away "$1"); echo "  $1: longest away from the compositor ${a:-?} ms"; test "${a:-99999}" -lt "$2"; }

# scroll_hidpi MON SCALE X0 W LAYOUT...: the page on monitor MON (at
# SCALE), a region W x 1383 px at X0,309 on it, scrolled to the page's end
scroll_hidpi() {
    local mon=$1 sc=$2 x0=$3 rw=$4 s tw th want lw lh lx ly mx my
    "$ROOT/tools/e2e/monitors.sh" "${@:5}" >"$OUT/layout.txt" || fail "monitor layout"
    cat "$OUT/layout.txt"
    if [ $# -gt 5 ]; then modes_start Meta-0 Meta-1; else modes_start Meta-0; fi
    mode_cfg copy
    require_pygtk || return
    drv move "$mon" 1900 1000
    : >"$OUT/page.ctl"
    start_page "$PAGE_H" "$OUT/page.ctl"
    check "a long page is up (viewport ${VP:-?} px)" test -n "$VP"
    drv key ctrl+super+print
    check "Ctrl+Super+Print opens the region picker" shell_wait 10 "scrolling capture: pick a region" 1
    # (two 4K surfaces take a while to fill in a debug build; the pointer
    # reaches them once they are up)
    shell_wait 20 "area picker: up" 1
    sleep 1
    drag "$mon" "$x0" 309 "$mon" 2000 900 "$mon" $((x0 + rw)) 1692
    sleep 0.5
    shot "$mon" region
    keys enter
    check "Enter starts scrolling the region" shell_wait 10 "scrolling capture of" 1
    # what the shell was asked for, logical, and the monitor's origin
    read -r lw lh lx ly <<<"$(grep -o "scrolling capture of [0-9]*x[0-9]* at [0-9]*,[0-9]*" "$SHOTLET_E2E_SHELL_LOG" | tail -1 | tr -c '0-9\n' ' ')"
    read -r _ mx my _ <<<"$(sed -n "$((mon + 1))p" "$OUT/layout.txt")"
    check "  ... on whole physical pixels (${lw}x$lh at $lx,$ly on a monitor at $mx,$my)" whole_px "$sc" $((lx - mx)) $((ly - my)) "$lw" "$lh"
    check "  ... the page scrolls by itself" wait_log 30 "^scrolled [1-9]" "$OUT/page.log"
    check "it stops at the end of the page" shell_wait 90 "stopped: end_of_page (Reached the end of the page)" 1
    grep -E "scrolling capture|scrolling_capture" "$SHOTLET_E2E_SHELL_LOG" | sed 's/^/  log: /'
    check "  ... and opens the tall image in the editor" shell_wait 10 "startup: capture=" 1
    check "  ... the picker kept answering the compositor" answered Shotlet 1500
    check "  ... and so did the control, frames coming meanwhile" answered "shotlet:scroll" 1000
    sleep 1.5
    keys enter
    check "Enter copies the stitched image" wait_until 10 clip_png "$OUT/tall.png"
    s=$(png_size "$OUT/tall.png"); tw=${s%x*} th=${s#*x}
    want=$("$E2E_PYTHON" -c "print(round((${lh:-0} + $PAGE_H - ${VP:-0}) * $sc))")
    rw=$("$E2E_PYTHON" -c "print(round(${lw:-0} * $sc))")
    check "  ... ${tw}x${th}: the region's width ($rw)" near_h "$tw" "$rw"
    check "  ... and the page's height through the region (~$want)" near_h "$th" "$want"
    check "  ... the marker band exactly once" eq "$(drv runs "$OUT/tall.png" 5 ff00ff 8 && echo "$VAL")" 1
}

# scroll_cover MON: a second capture of all of monitor MON (a click),
# where the control has no room beside the region and sits over it:
# left out of the frames, it does not stop the matching
scroll_cover() {
    local s th
    echo "goto 0" >"$OUT/page.ctl"
    sleep 0.5
    clip_set nothing
    ext_gap
    drv key ctrl+super+print
    check "a second picker" shell_wait 10 "scrolling capture: pick a region" 2
    shell_wait 20 "area picker: up" 2
    sleep 1
    click "$1" 1900 1000
    sleep 0.5
    keys enter
    check "all of the monitor scrolls to the end of the page, the control over it" shell_wait 90 "stopped: end_of_page" 2
    check "  ... and opens in the editor" shell_wait 10 "startup: capture=" 2
    sleep 1.5
    keys enter
    # (a 3840x4600 PNG: a while to encode in a debug build)
    check "  ... which copies it" wait_until 30 clip_png "$OUT/cover.png"
    s=$(png_size "$OUT/cover.png"); th=${s#*x}
    check "  ... taller than the monitor (${s})" test "${th:-0}" -gt 3000
    check "  ... the marker band exactly once" eq "$(drv runs "$OUT/cover.png" 5 ff00ff 8 && echo "$VAL")" 1
}
