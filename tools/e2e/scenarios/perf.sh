# How fluid each surface is on two 4K-class monitors (sourced by
# tools/e2e.sh's inner side, with its helpers): 3456x2160 at 2 beside
# 3840x2160 at 1.5 (primary), everything on the 1.5 one.
#   perf-owner   each surface driven like a hand, then its loop line
#                (SHOTLET_LOOP_STATS: frame times and the longest time
#                away from the compositor) printed; a report, the checks
#                only that each surface came up
# The lines are "loop: TITLE: N frames p50 .. p95 .. max ..; longest away
# from the socket .. ms" in the compositor log ($OUT/loop.txt).

# perf_drag MON X0 Y0 X1 Y1 N: press, N motion steps, release
perf_drag() {
    local mon=$1 x0=$2 y0=$3 x1=$4 y1=$5 n=$6 i
    approach "$mon" "$x0" "$y0" && drv down || return 1
    for i in $(seq 1 "$n"); do
        drv move "$mon" $((x0 + (x1 - x0) * i / n)) $((y0 + (y1 - y0) * i / n)) || return 1
    done
    drv sleep 100 && drv up
}
# perf_wander MON N: the pointer across the monitor and back, N steps
perf_wander() {
    local mon=$1 n=$2 i
    for i in $(seq 1 "$n"); do drv move "$mon" $((200 + 3400 * i / n)) $((300 + 1500 * i / n)); done
    for i in $(seq 1 "$n"); do drv move "$mon" $((3600 - 3400 * i / n)) $((1800 - 1500 * i / n)); done
}
# perf_loops: the loop lines so far
perf_loops() { grep -o "loop): .*\|loop: .*" "$SHOTLET_E2E_SHELL_LOG" "$OUT"/*.log 2>/dev/null; }

# perf_card: the thumbnail of the newest capture, bottom-left of the
# primary (1.5) monitor: hovered, its menu, closed
perf_card() {
    local i
    for i in $(seq 1 30); do drv move 1 $((100 + i * 10)) $((1900 + i * 3)); done
    click 1 240 1988 right
    sleep 0.5
    for i in $(seq 1 30); do drv move 1 $((150 + i * 5)) $((1700 + i * 8)); done
    keys esc
    sleep 0.5
    click 1 92 1907
    sleep 1
}

scenario_perf_owner() {
    "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1.5! >"$OUT/layout.txt" || fail "monitor layout"
    modes_start Meta-0 Meta-1
    cfg_write thumbnail=after_copy_and_save after_fullscreen=copy
    free_print
    require_pygtk || return
    drv move 1 1900 1000
    start_page "$PAGE_H"
    perf_editor
    perf_card
    perf_record
    perf_scroll
    perf_loops | tee "$OUT/loop.txt" | sed 's/^/  /'
    check "each surface logged its frames" test "$(wc -l <"$OUT/loop.txt")" -ge 8
}

# the editor: an area, a rectangle in it, the pointer over everything,
# the magnifier (Ctrl held); copied: the thumbnail
perf_editor() {
    drv key print
    check "the editor comes up" shell_editor 1
    perf_drag 1 600 400 3000 1700 60
    keys r
    perf_drag 1 900 600 2400 1400 60
    perf_wander 1 60
    drv key ctrl down
    perf_wander 1 20
    drv key ctrl up
    keys enter
    check "the thumbnail comes up" wait_until 10 grep -q "quick access: \(showing\|added\)" "$SHOTLET_E2E_SHELL_LOG"
    sleep 1.5
}

# the recording picker, a recording with its control, the trim window
perf_record() {
    local id
    ext_gap
    run_shotlet pick record
    check "the recording picker comes up" shell_wait 10 "record: picker up" 1
    sleep 1
    perf_drag 1 600 400 3000 1700 60
    perf_wander 1 40
    keys esc
    sleep 1.5
    run_shotlet rec record --region "400,300,1200,700" --seconds 4 --no-countdown
    check "a recording with its control" wait_log 15 "record: recording" "$OUT/rec.log"
    perf_wander 1 40
    wait_exit 30
    sleep 1
    id=$(basename "$(dirname "$(ls -t "$XDG_STATE_HOME"/shotlet/history/*/video | head -1)")")
    run_shotlet trimwin trim "$XDG_STATE_HOME/shotlet/history" "$id"
    check "the trim window comes up" wait_log 10 "trim: " "$OUT/trimwin.log"
    sleep 1.5
    perf_wander 1 40
    click 1 1920 1080
    keys esc
    check "  ... and Esc closes it" wait_exit 5
}

# the scrolling capture's picker, the capture with its control, the
# tall image in the editor
perf_scroll() {
    ext_gap
    drv key ctrl+super+print
    check "the scrolling picker comes up" shell_wait 10 "scrolling capture: pick a region" 1
    sleep 2
    perf_drag 1 1023 309 3787 1692 60
    drv move 1 3000 2000
    perf_wander 1 20
    keys enter
    check "the scrolling capture ends" shell_wait 90 "scrolling capture ended" 1
    shell_wait 10 "startup: capture=" 2
    sleep 1.5
    perf_wander 1 40
    keys esc esc
    sleep 1.5
}
