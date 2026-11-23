# One area selection in the three pickers that choose an area over the
# frozen desktop (sourced by tools/e2e.sh's inner side, with its
# helpers): the editor (Print), the recording picker (shotlet record) and
# the scrolling capture's picker (Ctrl+Super+Print).
#   area-editor      every gesture in the editor: drag out, resize by a
#   area-record      corner, move, arrows (Shift: 10 px, Ctrl: resize), the
#   area-scroll      size label, Enter; Shift draws a square, Ctrl from the
#                    centre, a click takes the monitor, one Esc leaves;
#                    Enter with nothing selected takes the monitor under
#                    the pointer
#   area-shots       light: each picker idle, dragging, selected with its
#                    handles, a handle under the pointer, into
#                    $OUT/<mode>-<state>.png (the before/after pictures)
#   area-shots-dark  the same in the dark appearance
# The area is checked on screen (the desktop bright inside it, dimmed
# outside), and exactly in what each mode hands on: the editor's copy,
# the recording picker's "picked X,Y WxH", the scrolling capture's
# "region WxH at X,Y".

# the plain desktop under the pickers' dim
DIM_BG=193769
# the size label's pill (theme pill_bg over the dim)
PILL_BG=1c1e24

# area_open MODE N: the Nth picker of MODE (editor, record, scroll) up,
# the pointer away from where the area goes
area_open() {
    ext_gap
    drv move 0 120 120
    case $1 in
        editor) drv key print && shell_editor "$2" ;;
        record) run_shotlet "pick$2" record && shell_wait 10 "record: picker up" "$2" && sleep 1 ;;
        scroll) drv key ctrl+super+print && shell_wait 10 "scrolling capture: pick a region" "$2" && sleep 2 ;;
    esac
}

# lit_at|dim_at NAME X Y: in $OUT/NAME.png, the desktop bright (inside the
# area) or dimmed (outside it) at X Y
lit_at() { pixel_near "$OUT/$1.png" "$2" "$3" "$DESKTOP_BG" 8; }
dim_at() { pixel_near "$OUT/$1.png" "$2" "$3" "$DIM_BG" 8; }
_gone() { shot 0 gone && lit_at gone 300 200; }
# area_done MODE N AREA: the Nth result of MODE is AREA (X,Y,W,H); the
# recording is stopped, the scrolling capture let go
area_done() {
    local x y w h
    IFS=, read -r x y w h <<<"$3"
    case $1 in
        editor) clip_is "editor$2" "${w}x$h" 5 ;;
        record) shell_wait 10 "picked $x,$y ${w}x$h" 1 || return 1
            shell_wait 10 "record: recording" "$2" && "$BIN" record --stop >/dev/null 2>&1
            shell_wait 15 "recording: saved" "$2" ;;
        scroll) shell_wait 10 "region ${w}x$h at $x,$y" 1 || return 1
            keys esc; sleep 0.5; stop_scroll ;;
    esac
}
# the scrolling capture over the plain desktop ends (Esc on its control,
# else its process)
stop_scroll() { wait_until 5 _gone || pkill -f "$BIN.*scroll" ; sleep 1; }

# area_gestures MODE: each gesture in turn on one area, then Enter
area_gestures() {
    local m=$1
    area_open "$m" 1 || { fail "$m: the picker did not come up"; return; }
    shot 0 "$m-g0"
    check "$m: the desktop dims under the picker" dim_at "$m-g0" 300 200
    select_area 0 400 250 900 600
    sleep 0.4
    shot 0 "$m-g1"
    check "$m: a drag draws an area: bright inside" lit_at "$m-g1" 650 425
    check "  ... dimmed outside" dim_at "$m-g1" 300 200
    check "  ... white handles at its corners" pixel_near "$OUT/$m-g1.png" 400 250 ffffff 20
    check "  ... its size above it" find_on 0 "$PILL_BG" 10 40 390 200 700 250
    drag 0 900 600 0 950 625 0 1000 650
    sleep 0.4
    shot 0 "$m-g2"
    check "$m: a corner's handle resizes it" lit_at "$m-g2" 980 640
    drag 0 700 450 0 750 475 0 800 500
    sleep 0.4
    shot 0 "$m-g3"
    check "$m: a drag inside moves it" eval 'lit_at "$m-g3" 1080 680 && dim_at "$m-g3" 450 280'
    keys right shift+down ctrl+right
    sleep 0.3
    shot 0 "$m-g4"
    keys enter
    check "$m: arrows nudge it (1 px, Shift 10), Ctrl+arrow resizes; Enter takes it (501,310 601x400)" area_done "$m" 1 501,310,601,400
}

# area_more MODE: Shift draws a square, Ctrl from the centre, a click
# takes the monitor, one Esc leaves; then Enter with nothing selected
# takes the monitor
area_more() {
    local m=$1
    area_open "$m" 2 || { fail "$m: the picker did not come up"; return; }
    approach 0 300 200 && drv key shift down && drv down && drv move 0 400 230 && drv move 0 500 260 &&
        drv sleep 150 && drv up && drv key shift up
    sleep 0.4
    shot 0 "$m-m1"
    check "$m: Shift draws a square" eval 'lit_at "$m-m1" 400 380 && dim_at "$m-m1" 600 300'
    # (Ctrl let go before the picture: the editor's magnifier goes with it)
    # (away from the square's bar: the editor's toolbar reaches 800,450)
    approach 0 1100 300 && drv key ctrl down && drv down && drv move 0 1200 350 && drv move 0 1300 400 &&
        drv sleep 150 && drv up && drv key ctrl up
    sleep 0.5
    shot 0 "$m-m1c"
    check "$m: Ctrl draws it from the centre" eval 'lit_at "$m-m1c" 920 220 && dim_at "$m-m1c" 880 220'
    click 0 1200 700
    sleep 0.4
    shot 0 "$m-m2"
    check "$m: a click takes the whole monitor" eval 'lit_at "$m-m2" 50 850 && lit_at "$m-m2" 1500 100'
    keys esc
    check "$m: one Esc leaves the picker" wait_until 5 _gone
    sleep 1
    area_open "$m" 3 || { fail "$m: the picker did not come up again"; return; }
    drv move 0 800 450
    sleep 0.3
    keys enter
    check "$m: Enter with nothing selected takes the monitor under the pointer" area_done "$m" 2 0,0,1600,900
}

area_scenario() {
    modes_start Meta-0
    mode_cfg copy
    free_print
    sleep 0.5
    area_gestures "$1"
    sleep 1
    area_more "$1"
}
scenario_area_editor() { area_scenario editor; }
scenario_area_record() { require ffprobe ffmpeg && area_scenario record; }
scenario_area_scroll() { area_scenario scroll; }

# area_shots MODE N SCHEME: the four states of the Nth picker of MODE
area_shots() {
    local m=$1-$3
    area_open "$1" "$2" || { fail "$1: the picker did not come up"; return; }
    sleep 0.5
    shot 0 "$m-idle"
    approach 0 400 250 && drv down && drv move 0 550 350 && drv move 0 700 450
    sleep 0.4
    shot 0 "$m-dragging"
    drv move 0 900 600 && drv sleep 150 && drv up
    drv move 0 1300 120
    sleep 0.5
    shot 0 "$m-selected"
    approach 0 900 425
    sleep 0.5
    shot 0 "$m-handle"
    keys esc
    sleep 0.3
    alive_editor_esc "$1"
}
# the editor (before: the first Esc only cleared the selection) is gone
alive_editor_esc() {
    [ "$1" = editor ] || return 0
    sleep 0.5
    keys esc
    sleep 0.5
}

area_shots_all() {
    modes_start Meta-0
    mode_cfg copy
    gsettings set org.gnome.desktop.interface color-scheme "$([ "$1" = dark ] && echo prefer-dark || echo default)"
    free_print
    sleep 0.5
    area_shots editor 1 "$1"
    area_shots record 1 "$1"
    area_shots scroll 1 "$1"
    check "the shots are taken ($1)" test -s "$OUT/scroll-$1-handle.png"
}
scenario_area_shots() { area_shots_all light; }
scenario_area_shots_dark() { area_shots_all dark; }
