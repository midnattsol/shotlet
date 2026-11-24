# Scrolling captures of a real terminal, Ghostty, on the owner's layout
# (3456x2160 at 2 beside 3840x2160 at 1.5, primary) (sourced by
# tools/e2e.sh's inner side). Skipped without ghostty.
#   modes-scroll-ghostty     on the 1.5 monitor: text scrolled from the
#                            top to the prompt (a blinking cursor), never
#                            a step past what lines up; two panes side by
#                            side, the region over both: the moving pane
#                            stitched, the still one left out; at the
#                            bottom of the scrollback with output arriving
#                            by itself (a spinner, a line now and then):
#                            it pauses with "The page didn't move"
#   modes-scroll-ghostty-2x  text and two panes on the 2.0 monitor
# A terminal line is a whole number of physical pixels at 2 (37 px at
# 12 pt) but not at 1.5 (27.7 px), where the rows' profiles line the
# frames up (app/scroll/nearmatch.zig). One wheel notch moves Ghostty 6
# lines (166 px at 1.5, 222 px at 2), a GTK page 123 logical px.

# lines of words of random length (no two alike), numbered; a magenta
# line (a truecolor background) after the 200th
GT_TEXT="awk -v N=400 'BEGIN{srand(7); for(i=1;i<=N;i++){s=sprintf(\"%5d\",i); n=int(rand()*14); for(k=0;k<n;k++){s=s \" \"; m=int(rand()*9)+1; for(j=0;j<m;j++) s=s sprintf(\"%c\",97+int(rand()*26))} print s; if(i==200) printf \"\\033[48;2;255;0;255m%100s\\033[0m\\n\", \"\"}}'"
# output arriving at the bottom: a spinner redrawn in place, a new line
# every 1.5 s (a TUI, a build log)
GT_LIVE="s='/-x+'; i=0; while :; do i=\$((i+1)); [ \$((i%15)) = 0 ] && printf '\\r\\033[2Koutput line %d\\n' \$i; printf '\\r\\033[2K%s working %s' \"\${s:i%4:1}\" \"\$(date +%N)\"; sleep 0.1; done"

# gt_panes CMD...: the command each pane Ghostty opens runs, in order
# ($OUT/pane.sh runs the next line of $OUT/panes, then a shell)
gt_panes() {
    printf '%s\n' "$@" >"$OUT/panes"
    : >"$OUT/pane.n"
    cat >"$OUT/pane.sh" <<EOF
#!/bin/bash
n=\$(wc -c <"$OUT/pane.n"); echo -n x >>"$OUT/pane.n"
export PS1='\$ '
eval "\$(sed -n "\$((n + 1))p" "$OUT/panes")"
exec bash --norc -i
EOF
    chmod +x "$OUT/pane.sh"
}

# gt_start MON: Ghostty maximized on monitor MON, a blinking cursor, its
# panes running gt_panes' commands (an unfocused one not dimmed, so the
# magenta stays magenta); Ctrl+Alt+T scrolls to the top,
# Ctrl+Alt+R splits right
gt_start() {
    drv move "$1" 1900 1000
    ghostty --config-default-files=false --gtk-single-instance=false \
        --font-family=monospace --font-size=12 --cursor-style-blink=true \
        --shell-integration=none --confirm-close-surface=false --maximize=true \
        --window-decoration=none --unfocused-split-opacity=1 --command="$OUT/pane.sh" \
        --keybind=ctrl+alt+t=scroll_to_top --keybind=ctrl+alt+r=new_split:right \
        >>"$OUT/ghostty.log" 2>&1 &
    GT_PID=$!
    sleep 4
}
gt_stop() { kill "$GT_PID" 2>/dev/null; wait "$GT_PID" 2>/dev/null; sleep 0.5; }

# gt_capture MON X0 Y0 X1 Y1: a scrolling capture of that region
# (physical pixels of monitor MON); GT_N counts them
gt_capture() {
    GT_N=$((GT_N + 1))
    clip_set nothing
    drv key ctrl+super+print
    shell_wait 10 "scrolling capture: pick a region" "$GT_N" || { fail "the region picker ($GT_N)"; return 1; }
    shell_wait 20 "area picker: up" "$GT_N"
    sleep 1
    drag "$1" "$2" "$3" "$1" 2000 900 "$1" "$4" "$5"
    sleep 0.5
    keys enter
    shell_wait 10 "scrolling capture of" "$GT_N"
}
# gt_copied NAME: the next editor opened on the stitched image; Enter
# copies it to $OUT/NAME.png; its size in GT_W, GT_H
gt_copied() {
    GT_ED=$((GT_ED + 1))
    shell_wait 10 "startup: capture=" "$GT_ED" || return 1
    sleep 1.5
    keys enter
    wait_until 30 clip_png "$OUT/$1.png" || return 1
    local s
    s=$(png_size "$OUT/$1.png"); GT_W=${s%x*} GT_H=${s#*x}
}
gt_marker_once() { eq "$(drv runs "$OUT/$1.png" 5 ff00ff 8 && echo "$VAL")" 1; }
gt_layout() {
    "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1.5! >"$OUT/layout.txt" || fail "monitor layout"
    modes_start Meta-0 Meta-1
    mode_cfg copy
    GT_N=0 GT_ED=0
    require ghostty
}

# gt_text MON SCALE MIN_H: text from the top of the scrollback down to the
# prompt, its cursor blinking in the region at the end
gt_text() {
    local mon=$1 sc=$2 min_h=$3 far
    gt_panes "$GT_TEXT"
    gt_start "$mon"
    keys ctrl+alt+t
    sleep 1
    gt_capture "$mon" 40 300 2400 2150
    check "Ghostty at $sc: the text scrolls to the end, the cursor blinking" shell_wait 120 "stopped: end_of_page" "$GT_N"
    far=$(shell_count "moved too far")
    check "  ... never a step past what lines up (moved too far: ${far:-0})" eq "${far:-0}" 0
    check "  ... the editor copies it" gt_copied "text-$sc"
    # 400 lines and the marker, less what lay above and below the region
    check "  ... ${GT_W}x${GT_H}: the region's width, the lines under it (over $min_h)" \
        eval 'near_h "$GT_W" 2360 && test "$GT_H" -gt "$min_h"'
    check "  ... the magenta line exactly once" gt_marker_once "text-$sc"
    gt_stop
    ext_gap
}

# gt_panes_both MON SCALE X1 MIN_W: two panes; the region over both, the
# wheel over the left one, which scrolls; the right one stays put
gt_panes_both() {
    local mon=$1 sc=$2 x1=$3 min_w=$4
    gt_panes "$GT_TEXT" "seq 1 60"
    gt_start "$mon"
    keys ctrl+alt+r
    sleep 2
    click "$mon" 100 1000
    sleep 0.5
    keys ctrl+alt+t
    sleep 1
    shot "$mon" "panes-$sc"
    gt_capture "$mon" 40 300 "$x1" 1800
    check "two panes at $sc, the region over both: it scrolls to the end" shell_wait 120 "stopped: end_of_page" "$GT_N"
    check "  ... the editor copies it" gt_copied "panes-$sc"
    # the left pane is half the monitor, less the region's 40 px
    check "  ... ${GT_W} px wide: the scrolling pane up to the divider (over $min_w; the region: $((x1 - 40)))" \
        eval 'test "$GT_W" -gt "$min_w" -a "$GT_W" -lt $((x1 - 40 - 300))'
    check "  ... the magenta line exactly once" gt_marker_once "panes-$sc"
    gt_stop
    ext_gap
}

# gt_live_bottom MON: the bottom of the scrollback, output arriving by
# itself: the wheel moves nothing, and the control says so (it ended
# "at the end of the page" with the output stitched, as if it worked)
gt_live_bottom() {
    local mon=$1
    gt_panes "$GT_TEXT; $GT_LIVE"
    gt_start "$mon"
    gt_capture "$mon" 40 300 2400 2150
    check "at the bottom, output arriving: it pauses, the page didn't move" shell_wait 90 "stopped: didnt_move (The page didn" 1
    check "  ... not at the end of the page" eq "$(shell_count "stopped: end_of_page")" "$GT_ED"
    sleep 0.5
    shot "$mon" live-paused
    keys esc
    check "  ... Esc cancels" shell_wait 5 "scrolling capture: cancelled" 1
    gt_stop
}

scenario_modes_scroll_ghostty() {
    gt_layout || return
    gt_text 1 1.5 9800
    gt_panes_both 1 1.5 3000 1700
    gt_live_bottom 1
}

scenario_modes_scroll_ghostty_2x() {
    gt_layout || return
    gt_text 0 2 13000
    gt_panes_both 0 2 2600 1500
}
