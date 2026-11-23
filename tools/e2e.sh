#!/bin/bash
# End-to-end tests: real shotlet, real portals, real PipeWire, driven by a
# virtual keyboard and pointer, inside a private headless GNOME session
# (tools/e2e/session.sh). Nothing touches the desktop you are logged into.
#
# usage: tools/e2e.sh [--list] [--bins SHOTLET DRIVE DROPTARGET] [--] [SCENARIO...]
#        zig build e2e [-- SCENARIO...]
# The binaries default to zig-out/bin/shotlet, shotlet-drive and
# shotlet-droptarget (zig build e2e-driver). SCENARIO: a row of
# tools/e2e/table.sh (--list prints them); default all but the manual ones.
# Prints PASS/FAIL/SKIP per check (all of them also in results.txt) and a
# summary line; exits 1 when anything failed, 2 for an unknown scenario.
# Skips (exit 0) when gnome-shell, PipeWire or the portals are missing.
# Env: E2E_OUT=dir keeps logs and screenshots there (default: a temp dir,
#      removed when everything passed).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/e2e-common/table.sh"
. "$ROOT/tools/e2e/table.sh"
. "$ROOT/tools/e2e-common/summary.sh"
# the extension's UUID, and the app id xdg-desktop-portal stores consent
# under (no test hook: shotlet registers it through
# org.freedesktop.host.portal.Registry)
export EXT_UUID=shotlet@midnattsol.github.io APP_ID=io.github.midnattsol.Shotlet

# ---------------------------------------------------------------- inner side
# (tools/e2e/lib.sh, desktop.sh and dialogs.sh: the helpers;
# tools/e2e/scenarios/*.sh: one scenario_NAME function per scenario)

# the scenario's settings, before anything starts (its table flags)
prepare_scenario() {
    if scenario_flag nothumb; then cfg_write thumbnail=never; fi
    # the extension's floating windows, but captures through the portal
    # (the extension cannot start this shotlet: Capture() is refused)
    if scenario_flag portal; then ext_gsettings set shotlet-path "'/nonexistent/shotlet'"; fi
}

run_scenario() {
    local fn=scenario_${scenario//-/_}
    declare -F "$fn" >/dev/null || { fail "no function $fn"; return; }
    "$fn"
}

# the scenario's end, also when it stops early (exit)
end_scenario() {
    stop_shotlet
    pkill -P $$ 2>/dev/null
    cp "$HL_SHELL_LOG" "$OUT/shell.log" 2>/dev/null
}

if [ "${1:-}" = "--inner" ]; then
    scenario=$2
    BIN=$E2E_BIN DRIVE=$E2E_DRIVE OUT=$E2E_OUT/$scenario
    mkdir -p "$OUT"
    cd "$HOME"
    failed=0
    . "$ROOT/tools/e2e/lib.sh"
    . "$ROOT/tools/e2e/desktop.sh"
    . "$ROOT/tools/e2e/dialogs.sh"
    for f in "$ROOT"/tools/e2e/scenarios/*.sh; do . "$f"; done
    scenario_row "$scenario" || { fail "no such scenario"; exit 2; }
    trap end_scenario EXIT
    prepare_scenario
    run_scenario
    exit $failed
fi

# ---------------------------------------------------------------- outer side
# missing_tools: what the suite needs and this system lacks, space-led
missing_tools() {
    local t f missing=
    for t in gnome-shell dbus-run-session pipewire wireplumber gdbus wl-paste wl-copy; do
        command -v "$t" >/dev/null || missing="$missing $t"
    done
    for f in /usr/libexec/xdg-desktop-portal /usr/libexec/xdg-desktop-portal-gnome; do
        [ -x "$f" ] || missing="$missing ${f##*/}"
    done
    echo "$missing"
}

# a Python with GTK 4 bindings plays "another app" (python3-gi, gir1.2-gtk-4.0)
find_pygtk() {
    local p
    for p in /usr/bin/python3 python3; do
        "$p" -c 'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null && { echo "$p"; return; }
    done
}

# the extension ships its settings schema compiled: it must match the XML
check_schema() {
    command -v glib-compile-schemas >/dev/null || return 0
    local sdir=$ROOT/gnome-extension/$EXT_UUID/schemas tmp
    tmp=$(mktemp -d)
    cp "$sdir"/*.gschema.xml "$tmp/" && glib-compile-schemas --strict "$tmp" &&
        if cmp -s "$tmp/gschemas.compiled" "$sdir/gschemas.compiled"; then
            echo "PASS schema: gschemas.compiled matches the XML" | tee -a "$E2E_OUT/results.txt"
        else
            echo "FAIL schema: gschemas.compiled is stale (glib-compile-schemas $sdir)" | tee -a "$E2E_OUT/results.txt"
            total_fail=1
        fi
    rm -rf "$tmp"
}

# run_session SCENARIO: the scenario in a fresh session (its own HOME,
# portal state, monitors, keyboard layout, input method and extensions,
# from its row of table.sh); returns its exit status
run_session() {
    scenario_row "$1"
    local ext=
    scenario_flag ext && ext=$ROOT/gnome-extension/$EXT_UUID
    HL_MONITORS=$S_MONS HL_LAYOUT=$(scenario_value layout) HL_IBUS=$(scenario_value ibus) \
        HL_APPS=$E2E_OUT/$APP_ID.desktop HL_EXTENSIONS=$ext timeout 300 \
        "$ROOT/tools/e2e/session.sh" "$ROOT/tools/e2e.sh" --inner "$1" \
        2> >(grep -v -e '^dbus-daemon\[' >>"$E2E_OUT/stderr.log") |
        result_lines "$E2E_OUT/results.txt" "$E2E_OUT/stderr.log"
    return "${PIPESTATUS[0]}"
}

BIN=$ROOT/zig-out/bin/shotlet DRIVE=$ROOT/zig-out/bin/shotlet-drive
DROPTARGET=$ROOT/zig-out/bin/shotlet-droptarget
want=()
while [ $# -gt 0 ]; do
    case $1 in
        --list) list_scenarios; exit 0 ;;
        --bins) BIN=$2 DRIVE=$3 DROPTARGET=$4; shift 4 ;;
        --) shift; want+=("$@"); break ;;
        *) want+=("$1"); shift ;;
    esac
done
[ ${#want[@]} -eq 0 ] && read -r -d '' -a want < <(default_scenarios)
for s in "${want[@]}"; do
    scenario_row "$s" || { echo "e2e.sh: unknown scenario $s (--list)" >&2; exit 2; }
done

missing=$(missing_tools)
if [ -n "$missing" ]; then
    echo "SKIP e2e: missing$missing"
    exit 0
fi
for f in "$BIN" "$DRIVE" "$DROPTARGET"; do
    [ -x "$f" ] || { echo "e2e.sh: $f not built (zig build e2e-driver)" >&2; exit 2; }
done
BIN=$(realpath "$BIN") DRIVE=$(realpath "$DRIVE") DROPTARGET=$(realpath "$DROPTARGET")
PYGTK=$(find_pygtk)
export PYGTK

keep=${E2E_OUT:+1}
E2E_OUT=${E2E_OUT:-$(mktemp -d -t shotlet-e2e-out.XXXXXX)}
mkdir -p "$E2E_OUT"
E2E_OUT=$(realpath "$E2E_OUT")
rm -f "$E2E_OUT/results.txt"
export E2E_BIN=$BIN E2E_DRIVE=$DRIVE E2E_DROPTARGET=$DROPTARGET E2E_OUT
# GNOME maps windows (and portal callers) to apps through installed
# .desktop files whose Exec exists: every session gets Shotlet's, as
# install.sh installs it
sed "s|^Exec=shotlet|Exec=$BIN|" "$ROOT/$APP_ID.desktop" >"$E2E_OUT/$APP_ID.desktop"

total_fail=0
check_schema
for s in "${want[@]}"; do
    run_session "$s"
    rc=$?
    if [ "$rc" = 77 ]; then
        echo "SKIP $s: no headless session (see $E2E_OUT/stderr.log)" | tee -a "$E2E_OUT/results.txt"
    elif [ "$rc" != 0 ]; then
        total_fail=1
        grep -q "^FAIL $s:" "$E2E_OUT/results.txt" || echo "FAIL $s: exit status $rc" | tee -a "$E2E_OUT/results.txt"
    fi
done

echo
print_summary e2e "$E2E_OUT/results.txt"
if [ "$total_fail" != 0 ] || [ -n "$keep" ]; then
    echo "logs and screenshots: $E2E_OUT"
else
    rm -rf "$E2E_OUT"
fi
exit $total_fail
