# Waiting: the one poll loop, and the log waits built on it.

_now_ms() { local t=${EPOCHREALTIME/[.,]/}; echo $((t / 1000)); }
_secs_ms() { # SECS (N or N.M) in milliseconds
    local i=${1%%.*} f=000
    [ "$1" != "$i" ] && f=${1#*.}000
    echo $((${i:-0} * 1000 + 10#${f:0:3}))
}
# wait_until SECS COMMAND...: until COMMAND succeeds, checking every 0.1 s
# for SECS seconds (N or N.M); false when it never did
wait_until() {
    local end
    end=$(($(_now_ms) + $(_secs_ms "$1")))
    shift
    while :; do
        "$@" && return 0
        [ "$(_now_ms)" -ge "$end" ] && return 1
        sleep 0.1
    done
}

# _log_has PATTERN [FILE]: an extended regex in FILE, or else in any log
# of this scenario ($OUT/*.log but the driver's)
_log_has() {
    if [ -n "${2:-}" ]; then
        grep -qE -- "$1" "$2" 2>/dev/null
        return
    fi
    local f
    for f in "$OUT"/*.log; do
        [ "${f##*/}" = drive.log ] && continue
        grep -qE -- "$1" "$f" 2>/dev/null && return 0
    done
    return 1
}
wait_log() { wait_until "$1" _log_has "$2" "${3:-$SHOT_LOG}"; } # wait_log SECS PATTERN [FILE]
any_log() { wait_until "$1" _log_has "$2"; }                    # any_log SECS PATTERN
no_log() { ! _log_has "$1" "${2:-}"; }                          # no_log PATTERN [FILE]
