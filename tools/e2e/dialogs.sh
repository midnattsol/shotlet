# Portal dialog helpers for tools/e2e.sh (sourced by its inner side).

# --- portal dialogs (xdg-desktop-portal-gnome), found by colour (ACCENT)
# TODO(wave 2): remove these two old names (scenarios use ACCENT, ACCENT_FILL)
accent=$ACCENT accent_fill=$ACCENT_FILL

# _button_on MON: an accent-coloured button (at least 40 px wide) on MON,
# not a selected monitor tile's frame (tall) nor a sliver of something
# else blue (an icon, a dialog fading in); its centre in BX, BY
_button_on() {
    local h
    find_on "$1" "$ACCENT" 24 40 || return 1
    read -r BX BY _ h <<<"$VAL"
    [ "$h" -ge 16 ] && [ "$h" -le 100 ]
}
# wait_button MON [SECONDS]: wait for that button on MON
wait_button() {
    BX=
    wait_until "${2:-10}" _button_on "$1" && return 0
    echo "  no dialog button on monitor $1" >&2
    return 1
}
# wait_chooser MON: the editor's Copy button wears a shade of the accent,
# so first let the editor close, then wait for the dialog's button
wait_chooser() {
    wait_until 5 no_find_on "$1" "$ACCENT" 24 40
    wait_button "$@"
}
# press_button MON: click the button until its dialog goes away
press_button() {
    local try
    for try in 1 2 3; do
        click "$1" "$BX" "$BY"
        sleep 1 # (the dialog fades out: look once it is gone)
        _button_on "$1" || return 0
    done
    return 1
}
# share_dialog MON [TILES [SCALE]]: on the ScreenCast picker, tick the
# monitor TILES (0 1: for multi-monitor pickers, where nothing is
# preselected and Share starts disabled), then press Share
share_dialog() {
    local mon=$1 tiles=${2:-} sc=${3:-1} t cx cy
    if [ -n "$tiles" ]; then
        # Share is disabled: the first accent blob is the "Remember"
        # checkbox; the tiles sit below it
        wait_find 10 "$mon" "$ACCENT" 24 10 || return 1
        sleep 0.5 # (the dialog may still be growing into place)
        find_on "$mon" "$ACCENT" 24 10 || return 1
        read -r cx cy _ <<<"$VAL"
        for t in $tiles; do
            case $t in
                0) click "$mon" $((cx - 42 * sc)) $((cy + 193 * sc)) ;;
                1) click "$mon" $((cx + 240 * sc)) $((cy + 173 * sc)) ;;
            esac || return 1
        done
    fi
    wait_button "$mon" || return 1
    sleep 0.5 # let the dialog finish mapping before clicking
    shot "$mon" dialog
    press_button "$mon"
}
