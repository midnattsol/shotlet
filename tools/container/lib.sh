# Helpers of the container scenarios (sourced by scenarios.sh once the
# session is up): the shared ones (tools/e2e-common/lib.sh: results,
# waits, the input driver, the shotlet under test, clipboard, settings,
# other apps, colours) and, here, the container's: the outputs, a test
# capture, the thumbnail, and the portal's dialogs.

BIN=${SHOTLET_BIN:-$BINDIR/shotlet} DRIVE=$BINDIR/shotlet-wldrive E2E_DROPTARGET=$BINDIR/shotlet-droptarget
. "$COMMON/lib.sh"

# monitor 0's logical size in MW, MH
mon_size() {
    drv monitors
    local g=${VAL%% *}
    g=${g#*:}; g=${g#*,}; g=${g#*,}; g=${g%@*}
    MW=${g%x*} MH=${g#*x}
}

# a capture of a test picture (red in a grey frame), copied with Enter;
# the copy lands in $OUT/NAME.png, its size in CAP_SIZE
red_capture() { # red_capture NAME
    [ -f "$OUT/red.png" ] || drv mkpng "$OUT/red.png" 1600 900 "$RED" || return 1
    run_shotlet "$1" shot --from "$OUT/red.png" --sel 200,100,800,500
    wait_editor 10 || return 1
    keys enter
    any_log 10 "quick access: (showing|added)" || return 1
    wait_until 3 clip_png "$OUT/$1.png" && CAP_SIZE=$(png_size "$OUT/$1.png")
}
# the newest thumbnail card (card_point) shows the red capture
card_red() { find_on 0 "$RED" 40 20 0 $((MH - 220)) 320 "$MH"; }

# xdg-desktop-portal-kde's screen chooser: tick the first screen, Share.
# Found by its ticked "Allow restoring on future sessions" box (Breeze's
# light accent); the rest sits at fixed offsets from it.
DIALOGS=0
# (or shotlet gave up); the whole box, not a sliver of it fading in
_kde_dialog_up() {
    local h
    alive || return 0
    find_on 0 "$BREEZE_TICK" 10 8 || return 1
    read -r _ _ _ h <<<"$VAL"
    [ "$h" -ge 8 ]
}
# Its tiles: with one output "New Virtual Output", "Rectangular Region",
# Virtual-0; with two "Full Workspace" comes first and the screens move.
kde_share_dialog() { # kde_share_dialog [TILES]: tick screens 0 (default), 1
    local x y t
    wait_until 15 _kde_dialog_up && alive || return 1
    read -r x y _ <<<"$VAL"
    sleep 0.5 # (it is shown a moment before it takes clicks)
    shot 0 "dialog-$DIALOGS"
    DIALOGS=$((DIALOGS + 1))
    for t in ${1:-0}; do
        case $NMON:$t in
            1:0) click 0 $((x + 240)) $((y - 211)) ;;
            2:0) click 0 $((x + 488)) $((y - 211)) ;;
            2:1) click 0 $((x + 230)) $((y - 77)) ;;
        esac || return 1
        sleep 0.4 # (the tile's tick follows the click a moment later)
    done
    shot 0 "dialog-$DIALOGS-ticked"
    click 0 $((x + 396)) $((y + 47))
}

# direct capture asked nobody: no portal chooser ran, no KDE dialog was
# answered, the portal was never used
no_consent() {
    check "  ... and nobody was asked (no chooser, no dialog, no portal)" \
        eval 'test ! -s "$HOME/chooser.log" -a "$DIALOGS" = 0 && no_log "capture path: portal"'
}

# a real capture through the portal: a 400x300 selection, copied. On KWin
# the portal's dialog is answered unless it is NODIALOG (a restore token
# should make it silent)
portal_capture() { # portal_capture NAME [nodialog | TILES]
    run_shotlet "$1"
    if [ "$COMP" = kwin ] && [ "${2:-}" != nodialog ]; then kde_share_dialog "${2:-}" || return 1; fi
    wait_editor 20 || return 1
    drag 0 200 200 0 400 350 0 600 500 && drv sleep 200 && keys enter
}
# chooser_calls: how often xdg-desktop-portal-wlr's chooser ran (chooser.sh)
chooser_calls() { wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0; }
