# Scenarios for tools/container/inner.sh (sourced once the session is up:
# WAYLAND_DISPLAY and the bus point at it; COMP, SCEN, OUT, NMON and the
# scenario's row of table.sh are set). The helpers are in lib.sh; each
# scenario is a scenario_NAME function (dashes as underscores) in
# scenarios/*.sh.

. "$CTR/lib.sh"
for f in "$CTR"/scenarios/*.sh; do . "$f"; done

run_scenario() {
    local fn=scenario_${1//-/_}
    declare -F "$fn" >/dev/null || { fail "no function $fn"; return; }
    if [ "$1" = probe ] && [ -n "${SHOTLET_E2E_PROBE0:-}" ]; then eval "$SHOTLET_E2E_PROBE0"; fi
    drv_start || { fail "input driver"; return; }
    mon_size
    "$fn"
    stop_kept
    drv_stop
}
