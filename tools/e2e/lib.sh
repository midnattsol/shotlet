# Core helpers of tools/e2e.sh's inner side (sourced inside the private
# session, with ROOT, scenario, OUT, BIN, DRIVE, APP_ID and EXT_UUID
# set): the helpers both suites share (tools/e2e-common/lib.sh: results, waits, the input driver,
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
# require_pygtk: false, with a SKIP, without a Python with GTK 4 ($PYGTK:
# target.py and scrolltarget.py play the other apps)
require_pygtk() { require "${PYGTK:-python3-gi}"; }
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

# A problem shotlet reports (app/report.zig): one line on stderr, the same
# words on a card with the accent's "i" (a `shotlet toast` it starts,
# which logs there too). problem_reported NAME CMD TITLE BODY: shotlet
# CMD, run as NAME ($OUT/NAME.log), said "Title. Body." both ways
problem_reported() {
    check "  ... saying why on stderr" grep -qF "shotlet $2: $3. $4." "$OUT/$1.log"
    check "  ... and on the screen" wait_log 10 "toast: $3: $4" "$OUT/$1.log"
    sleep 1
    shot 0 "notice-$1"
    check "  ... a card with the accent's \"i\"" find_on 0 "$ACCENT" 24 16
}
card_gone() { wait_until 10 no_find_on 0 "$ACCENT" 24 10; } # card_gone: the problem card went by itself

# notify_watch: from now on the desktop notifications sent on the session
# bus (Notify calls) go to $OUT/notify.txt (dbus-monitor; false, with a
# SKIP, without it)
notify_watch() {
    require dbus-monitor || return
    : >"$OUT/notify.txt"
    dbus-monitor --session "type='method_call',interface='org.freedesktop.Notifications',member='Notify'" \
        >>"$OUT/notify.txt" 2>&1 &
    wait_until 3 test -s "$OUT/notify.txt" # (it says it is monitoring first)
    return 0
}
notified() { wait_log "$1" "string \"$2\"" "$OUT/notify.txt"; } # notified SECS TEXT: a notification's body or title was TEXT
