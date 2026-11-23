# A scrolling capture where none can run, a scenario of tools/e2e.sh
# (sourced by its inner side, with its helpers): GNOME without the
# extension has no way to capture while the person scrolls. `shotlet
# scroll` (what the mode strip's J and the tray start too) says why on
# stderr and in a notice on the screen, and exits 1: no region picker,
# nothing captured. Not installed, then installed for the next login,
# then a new login: the picker comes up.
#   scroll-unavailable

scenario_scroll_unavailable() {
    drv_ready Meta-0
    drv move 0 800 450
    plain_desktop
    scroll_refused missing "Install it with shotlet gnome-integration install"
    "$BIN" gnome-integration install </dev/null >"$OUT/install.log" 2>&1
    check "installed for the next login" grep -q "It loads at your next login" "$OUT/install.log"
    scroll_refused login "It loads at your next login: log out and back in"
    drv_stop
    check "a new login (the private shell restarted)" restart_shell
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet active scroll
    check "with the extension running, shotlet scroll opens the region picker" shell_wait 15 "scrolling capture: pick a region" 1
    keys esc
}

# scroll_refused NAME BODY: `shotlet scroll` exits 1 saying BODY
scroll_refused() {
    local title="Scrolling capture needs the GNOME integration"
    run_shotlet "$1" scroll
    check "shotlet scroll ($1) exits 1" eval 'wait_exit 10 && eq "$RC" 1'
    problem_reported "$1" scroll "$title" "$2"
    check "  ... no region picker" no_log "pick a region" "$OUT/$1.log"
    check "  ... nothing captured" no_log "capture path:" "$OUT/$1.log"
    check "  ... no consent dialog" no_dialog
    check "  ... and goes by itself" card_gone
}
