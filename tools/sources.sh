# The source tree's limits and the files the guards check, in one place.
# Sourced by tools/check-size.sh, tools/long-fns.sh and CI's formatting
# check; build.zig reads the limits for its step descriptions.
# Run from the repository root.

# no source file may grow past this many lines (tools/size-allowlist.txt
# lists the ones still over it)
size_limit=600
# functions should stay within this many lines (tools/long-fns.sh)
fn_limit=60

# where the Zig sources are: `zig fmt --check $zig_roots`
zig_roots="src tools build.zig"

# sources [zig|sh|py|js]...: the checked files of those kinds (default
# all), sorted
sources() {
    [ $# -gt 0 ] || set -- zig sh py js
    for kind in "$@"; do
        case $kind in
            zig) find $zig_roots -name '*.zig' ;;
            sh) find tools -name '*.sh'; echo install.sh; echo uninstall.sh ;;
            py) find tools -name '*.py' ;;
            js) find gnome-extension -name '*.js' ;;
            *) echo "sources: unknown kind $kind" >&2; return 2 ;;
        esac
    done | sort
}
