# The shotlet under test ($BIN): one at a time in SHOT_PID, its output in
# SHOT_LOG ($OUT/NAME.log); the editor's last frames go to $OUT/NAME-*.png
# when it exits (SHOTLET_EDITOR_DUMP).

SHOT_PID= SHOT_LOG= RC=
run_shotlet() { # run_shotlet NAME ARGS...: start it in the background
    local name=$1; shift
    SHOT_LOG=$OUT/$name.log
    SHOTLET_EDITOR_DUMP=$OUT/$name "$BIN" "$@" >"$SHOT_LOG" 2>&1 &
    SHOT_PID=$!
}
alive() { kill -0 "$SHOT_PID" 2>/dev/null; }
wait_exit() { # wait_exit SECS: true once it exited; its status in RC (else empty)
    RC=
    wait_until "$1" eval '! alive' || return 1
    wait "$SHOT_PID"
    RC=$?
}
# wait_editor [SECS]: the editor is up. It logs its startup with the first
# frame; every surface takes keyboard and pointer input a moment later,
# which nothing logs: hence the pause.
wait_editor() { wait_log "${1:-10}" "startup: capture=" && sleep 0.8; }
stop_shotlet() { alive && kill "$SHOT_PID" 2>/dev/null; wait "$SHOT_PID" 2>/dev/null; }

# the thumbnail stack's newest card: bottom-left of monitor 0 (MH high),
# 8 px from the edges plus the 32 px of shadow room the quick window
# keeps (theme.card_room), 240x150
card_point() { # card_point DX DY: DX right of, DY up from its bottom-left
    echo "$((40 + $1)) $((MH - 40 - $2))"
}

# stop_kept [WHAT]: end this session's lasting shotlet processes (WHAT: an
# extended regex, default quick|history|pin). Only ours, found by their
# runtime dir: other sessions of the same user may run beside this one.
stop_kept() {
    local pid
    for pid in $(pgrep -f "shotlet (${1:-quick|history|pin})"); do
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" &&
            kill "$pid" 2>/dev/null
    done
}
