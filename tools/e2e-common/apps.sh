# Other apps beside Shotlet, each reporting what it gets (focus, typing,
# clicks, drops) one line at a time on its log:
#   droptarget  tools/e2e/droptarget.zig ($E2E_DROPTARGET), $OUT/drop.log
#   target      tools/e2e/target.py, GTK 4 ($PYGTK), $OUT/target.log;
#               SHOTLET_E2E_TARGET_DEBUG=1 logs its Wayland traffic
# Their pids: DROP_PID, TGT_PID.

DROP_PID= TGT_PID= APP_LOG=
start_app() { # start_app droptarget|target [ARGS...]: until it is up
    local app=$1; shift
    case $app in
    droptarget)
        APP_LOG=$OUT/drop.log
        : >"$APP_LOG"
        "$E2E_DROPTARGET" "$@" >>"$APP_LOG" 2>>"$OUT/drop.err" &
        DROP_PID=$!
        # the compositor maps and focuses it a moment after it is ready
        wait_log 10 "^ready" "$APP_LOG" && sleep 0.8
        ;;
    target)
        APP_LOG=$OUT/target.log
        : >"$APP_LOG"
        env ${SHOTLET_E2E_TARGET_DEBUG:+WAYLAND_DEBUG=client} "$PYGTK" "${E2E_TARGET_PY:-$ROOT/tools/e2e/target.py}" "$@" \
            >>"$APP_LOG" 2>>"$OUT/target.err" &
        TGT_PID=$!
        wait_log 10 "^active True" "$APP_LOG"
        ;;
    *) echo "start_app: unknown app $app" >&2; return 2 ;;
    esac
}
app_log() { case $1 in droptarget) echo "$OUT/drop.log" ;; target) echo "$OUT/target.log" ;; esac; }
# app_said SECS PATTERN [droptarget|target]: the app (default: the one
# started last) logged PATTERN within SECS
app_said() { wait_log "$1" "$2" "$(if [ -n "${3:-}" ]; then app_log "$3"; else echo "$APP_LOG"; fi)"; }
