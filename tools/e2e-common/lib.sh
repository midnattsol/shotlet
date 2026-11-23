# The e2e helpers both suites share (tools/e2e: GNOME; tools/container:
# wlroots and KWin). Sourced by each suite's own lib.sh, which then adds
# its platform's helpers on top.
#
# The caller sets, before sourcing:
#   E2E_TAG         what results are tagged with (the scenario name, or
#                   "COMPOSITOR SCENARIO")
#   OUT             the scenario's directory for logs and pictures
#   BIN DRIVE       the shotlet under test and the input driver
#   E2E_DROPTARGET  the drop target app (start_app droptarget)
#   PYGTK, E2E_TARGET_PY  a Python with GTK 4, and target.py (start_app target)
#
# Modules: report (pass/fail/skip/check, eq, require), wait (wait_until,
# wait_log, any_log, no_log), drive (the input driver: drv, keys, click,
# drag, find_on...), shotlet (run_shotlet, wait_exit, card_point...), clip
# (clipboard), config (Shotlet's settings), apps (other apps), colors.
E2E_COMMON=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for _m in colors report wait drive shotlet clip config apps; do
    . "$E2E_COMMON/$_m.sh"
done
unset _m
