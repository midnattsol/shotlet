# The input driver ($DRIVE: tools/e2e/drive.zig on GNOME,
# tools/container/wldrive.zig elsewhere), run as a coprocess: one command
# per line, one "ok [VALUE]" or "err ..." answer. Its log: $OUT/drive.log.

DRV_PID= VAL=
drv_start() { # drv_start [ARGS...]: start it, wait for "ok ready"
    coproc DRV { "$DRIVE" "$@" 2>>"$OUT/drive.log"; }
    DRV_PID=$DRV_PID
    local ans
    read -r -t 20 ans <&"${DRV[0]}" || ans="err no answer"
    [ "$ans" = "ok ready" ] || { echo "driver: $ans" >&2; return 1; }
}
drv() { # drv CMD...: one driver command; its value lands in $VAL
    local ans
    echo "$*" >&"${DRV[1]}"
    read -r -t 30 ans <&"${DRV[0]}" || ans="err no answer"
    echo "> $* -> $ans" >>"$OUT/drive.log"
    case $ans in
        ok*) VAL=${ans#ok}; VAL=${VAL# }; return 0 ;;
        *) VAL=; echo "driver: $* -> $ans" >&2; return 1 ;;
    esac
}
drv_stop() { drv quit >/dev/null 2>&1; wait "$DRV_PID" 2>/dev/null; }

keys() { local k; for k in "$@"; do drv key "$k" || return 1; done; } # keys KEY...
click() { drv move "$1" "$2" "$3" && drv sleep 120 && drv click "${4:-left}"; } # click MON X Y [BUTTON]
shot() { drv shot "$1" "$OUT/$2.png" >/dev/null; } # shot MON NAME: $OUT/NAME.png
png_size() { drv png "$1" && echo "$VAL"; }       # png_size FILE: WxH

# --- finding colours on screen: MON RGB [TOL [MINW [X0 Y0 X1 Y1]]] (TOL
# per channel, default 24; MINW the blob's least width, default 1; the
# box limits where to look). find_on leaves "CX CY W H" in VAL.
find_on() { drv find "$@" 2>/dev/null; }
no_find_on() { ! drv find "$@" 2>/dev/null; }
wait_find() { wait_until "$1" find_on "${@:2}"; } # wait_find SECS MON RGB ...

near() { # near AARRGGBB RRGGBB [TOL]: within TOL (default 6) per channel
    local a=${1:2:6} b=$2 i d
    for i in 0 2 4; do
        d=$((16#${a:$i:2} - 16#${b:$i:2}))
        [ ${d#-} -le "${3:-6}" ] || { echo "  $a is not $b" >&2; return 1; }
    done
}
pixel_near() { drv pixel "$1" "$2" "$3" && near "$VAL" "$4" "${5:-6}"; } # pixel_near FILE X Y RGB [TOL]

# --- the pointer, moved like a hand
# approach MON X Y: arrive at X Y in three steps, pausing. Mutter only
# gives a window that just moved under a still pointer the pointer on the
# next motion, and KWin's fake input can leave a press at an earlier
# pointer position when the pointer jumps.
approach() {
    drv move "$1" $(($2 - 8)) "$3" && drv sleep 100 && drv move "$1" $(($2 - 4)) "$3" && drv sleep 100 &&
        drv move "$1" "$2" "$3" && drv sleep 150
}
drag() { # drag MON X0 Y0 MON X1 Y1 ...: press, visit each point, release
    local mon=$1
    drv move "$mon" "$2" "$3" && drv sleep 100 && drv down || return 1
    shift 3
    while [ $# -ge 3 ]; do drv move "$1" "$2" "$3" || return 1; shift 3; done
    drv sleep 100 && drv up
}
slow_drag() { # slow_drag MON X0 Y0 X1 Y1 ...: approach, press, a pause per point
    local mon=$1
    approach "$mon" "$2" "$3" && drv down || return 1
    shift 3
    while [ $# -ge 2 ]; do drv move "$mon" "$1" "$2" && drv sleep 200 || return 1; shift 2; done
    drv sleep 300 && drv up
}
select_area() { # select_area MON X0 Y0 X1 Y1: approach, then one quick drag
    approach "$1" "$2" "$3" && drv down &&
        drv move "$1" $((($2 + $4) / 2)) $((($3 + $5) / 2)) && drv move "$1" "$4" "$5" &&
        drv sleep 100 && drv up && drv sleep 200
}
