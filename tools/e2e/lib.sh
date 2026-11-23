# Core helpers of tools/e2e.sh's inner side (sourced inside the private
# session, with ROOT, scenario, OUT, BIN and DRIVE set): the helpers both
# suites share (tools/e2e-common/lib.sh: results, waits, the input driver,
# the shotlet under test, clipboard, settings, other apps, colours), the
# session's building blocks (start_gnome_shell, ...) and, here, GNOME's:
# the driver out of the overview, thumbnails shown, D-Bus, the portal
# permission store.

E2E_TAG=$scenario
. "$ROOT/tools/e2e-common/lib.sh"
. "$ROOT/tools/e2e-common/session.sh"
# monitor 0 of the thumbnail scenarios (card_point)
MW=1600 MH=900

# drv_ready MON...: the driver on those monitors, out of the overview the
# session starts in; the scenario ends when it cannot start
drv_ready() {
    drv_start "$@" || { fail "driver"; exit 1; }
    drv key esc
}
shown_count() { cat "$OUT"/*.log 2>/dev/null | grep -cE "quick access: (showing|added)"; }
_shown_more() { [ "$(shown_count)" -gt "$1" ]; }
# new_card N: wait until more than N thumbnails were shown in all (then
# a second for the card to slide in: nothing logs its end)
new_card() { wait_until 10 _shown_more "$1" && sleep 1; }
gdbus_owner() {
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -q true
}
sni() { # sni METHOD ARGS...: call the daemon's StatusNotifierItem
    local m=$1; shift
    gdbus call --session --dest io.github.midnattsol.Shotlet --object-path /StatusNotifierItem \
        --method "org.kde.StatusNotifierItem.$m" "$@" >/dev/null
}
# the identity xdg-desktop-portal stores consent under (no test hook:
# shotlet registers it through org.freedesktop.host.portal.Registry)
APP_ID=io.github.midnattsol.Shotlet
perm() { # perm METHOD ARGS...: call the portal permission store
    local m=$1; shift
    gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
        --object-path /org/freedesktop/impl/portal/PermissionStore \
        --method "org.freedesktop.impl.portal.PermissionStore.$m" "$@" 2>/dev/null
}
# perm_apps TABLE: every app id with an entry in TABLE, one per line
perm_apps() {
    local id
    for id in $(perm List "$1" | grep -o "'[^']*'" | tr -d "'"); do
        perm Lookup "$1" "$id" | tee -a "$OUT/permissions.txt" | grep -o "'[^']*': \[" | sed "s/': \[//; s/^'//"
    done | sort -u
}

# --- old names the GNOME scenario files still use
# TODO(wave 2): remove (scenarios move to find_on/no_find_on, no_log, wait_log)
no_find_exact() { no_find_on "$@"; }
no_find() { no_find_on "$1" "$2" 24 10; } # (a fixed tolerance and width)
not_grep() { ! grep -q -- "$1" "$2" 2>/dev/null; } # (basic regex: no_log takes extended)
wait_file_line() { wait_log "$1" "$2" "$3"; }
