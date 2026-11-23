# Results: one line per check on stdout, "PASS|FAIL|SKIP $E2E_TAG: what"
# (the runners collect them in results.txt); `failed` is 1 after a FAIL.
# Notes for a person go to stderr, indented by two spaces.

failed=${failed:-0}
pass() { echo "PASS $E2E_TAG: $*"; }
fail() { echo "FAIL $E2E_TAG: $*"; failed=1; }
skip() { echo "SKIP $E2E_TAG: $*"; }
check() { # check DESCRIPTION COMMAND...
    local what=$1; shift
    if "$@"; then pass "$what"; else fail "$what"; fi
}
eq() { [ "$1" = "$2" ] || { echo "  expected '$2', got '$1'" >&2; return 1; }; }

# require TOOL...: false, with a SKIP, when one is missing. TOOL is a
# command name, a path to an executable, or lib:NAME for a shared library
# (as ldconfig lists it). `require x || return` in a scenario.
require() {
    local t
    for t in "$@"; do
        case $t in
            lib:*) ldconfig -p 2>/dev/null | grep -q -- "${t#lib:}" ;;
            */*) [ -x "$t" ] ;;
            *) [ -n "$t" ] && command -v "$t" >/dev/null ;;
        esac || { skip "needs ${t#lib:}, which is not installed"; return 1; }
    done
}
