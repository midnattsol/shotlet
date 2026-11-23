# Waiting: the one poll loop, and the log waits built on it.

# wait_until SECS COMMAND...: until COMMAND succeeds, trying it every
# 0.1 s, SECS*10 times (SECS: N or N.M). A slow COMMAND (a screen grab
# under load) stretches the wait rather than getting fewer tries.
wait_until() {
    local i=${1%%.*} f=0 n
    [ "$1" != "$i" ] && f=${1#*.}0
    n=$((${i:-0} * 10 + 10#${f:0:1}))
    shift
    while :; do
        "$@" && return 0
        n=$((n - 1))
        [ "$n" -le 0 ] && return 1
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
