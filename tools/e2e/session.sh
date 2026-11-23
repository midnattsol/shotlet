#!/bin/bash
# usage: tools/e2e/session.sh CMD [ARGS...]
# Runs CMD inside a private, invisible GNOME session: its own HOME,
# XDG_RUNTIME_DIR, session bus (dbus-run-session), PipeWire + WirePlumber,
# and a headless gnome-shell with virtual monitors. Portals
# (xdg-desktop-portal + -gnome) are D-Bus activated on the private bus.
# Nothing here can reach the caller's desktop: WAYLAND_DISPLAY, DISPLAY and
# the session bus address are replaced before anything starts.
# Env: SHOTLET_E2E_MONITORS="1600x900 1280x720"  virtual monitors
#      SHOTLET_E2E_LAYOUT=es              XKB layout (gsettings input-sources)
#      SHOTLET_E2E_IBUS=hangul            IBus engine as the input source
#      SHOTLET_E2E_APPS="x.desktop"       desktop files to install
#      SHOTLET_E2E_EXTENSIONS="dir..."    GNOME Shell extensions to install
#                                         and enable before the shell starts
#      SHOTLET_E2E_KEEP=1                 keep the temp HOME (prints it)
#      SHOTLET_E2E_WLDEBUG=1              gnome-shell's WAYLAND_DEBUG
# Any command, e.g. one shotlet run:
#   SHOTLET_E2E_MONITORS="1600x900 1280x720" tools/e2e/session.sh zig-out/bin/shotlet shot --from IMG.png
# Inside CMD: WAYLAND_DISPLAY, DBUS_SESSION_BUS_ADDRESS, HOME,
# XDG_RUNTIME_DIR point at the private session; SHOTLET_E2E_SHELL_LOG is the
# compositor log.
set -u
. "$(dirname "$0")/../e2e-common/session.sh"
# (the second pass, inside the private bus, sees sandbox_env's guard)
if [ "${SHOTLET_E2E_SANDBOX:-}" != gnome ]; then
    command -v gnome-shell >/dev/null && command -v dbus-run-session >/dev/null || {
        echo "session.sh: gnome-shell or dbus-run-session missing" >&2; exit 77; }
    HOME=$(mktemp -d -t shotlet-e2e.XXXXXX) || exit 1
    export HOME
    sandbox_env gnome
    export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_DESKTOP=gnome
    # no FUSE mounts (gvfs) to outlive the session or block cleaning up
    export GSETTINGS_BACKEND=dconf GTK_A11Y=none NO_AT_BRIDGE=1 GVFS_DISABLE_FUSE=1 GIO_USE_VFS=local
    # predictable dialog labels and messages
    export LANGUAGE=C; unset LC_ALL LC_MESSAGES LC_CTYPE LC_TIME LC_NUMERIC LC_MONETARY LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION
    unset SSH_AUTH_SOCK GNOME_KEYRING_CONTROL SESSION_MANAGER XAUTHORITY GTK_IM_MODULE QT_IM_MODULE XMODIFIERS
    # the private bus daemon's activation chatter is noise here
    dbus-run-session -- "$0" "$@" 2> >(grep -v '^dbus-daemon\[' >&2); rc=$?
    # processes the private bus started (portals, ...) may linger a moment
    pkill -u "$(id -u)" -f "$HOME" 2>/dev/null; sleep 0.2
    if [ -n "${SHOTLET_E2E_KEEP:-}" ]; then echo "HOME=$HOME" >&2; else rm -rf "$HOME"; fi
    exit $rc
fi

# --- inside the private bus
export WAYLAND_DISPLAY=wayland-hl
export SHOTLET_E2E_SHELL_LOG="$HOME/shell.log"
# every window logs its frame times as it closes (the responsiveness checks)
export SHOTLET_LOOP_STATS=1
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    # the document portal mounts a FUSE file system in the runtime dir
    for mnt in "$XDG_RUNTIME_DIR/doc" "$XDG_RUNTIME_DIR/gvfs"; do
        mountpoint -q "$mnt" 2>/dev/null && fusermount3 -u -z "$mnt" 2>/dev/null
    done
}
trap cleanup EXIT
start_pipewire "$HOME"
# SHOTLET_E2E_APPS="a.desktop ...": installed before gnome-shell starts, so the
# shell maps windows to those apps from the beginning
if [ -n "${SHOTLET_E2E_APPS:-}" ]; then
    mkdir -p "$XDG_DATA_HOME/applications"
    cp $SHOTLET_E2E_APPS "$XDG_DATA_HOME/applications/"
fi
dbus-update-activation-environment HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME \
    XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_CURRENT_DESKTOP \
    XDG_SESSION_TYPE WAYLAND_DISPLAY GSETTINGS_BACKEND GTK_A11Y NO_AT_BRIDGE \
    GVFS_DISABLE_FUSE GIO_USE_VFS \
    LANG LANGUAGE
# no welcome tour, no animations (screenshots and timings stay stable)
gsettings set org.gnome.shell welcome-dialog-last-shown-version '999'
gsettings set org.gnome.desktop.interface enable-animations false
if [ -n "${SHOTLET_E2E_LAYOUT:-}" ]; then
    gsettings set org.gnome.desktop.input-sources sources "[('xkb','$SHOTLET_E2E_LAYOUT')]"
fi
# SHOTLET_E2E_IBUS=engine: an IBus input method as the only input source (gnome-shell
# then offers text-input-v3 backed by it)
if [ -n "${SHOTLET_E2E_IBUS:-}" ] && command -v ibus-daemon >/dev/null; then
    # a fixed address: ibus derives its address file from DISPLAY and
    # crashes without one (ibus_write_address); DISPLAY points nowhere
    export IBUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/ibus"
    DISPLAY=:4242 ibus-daemon --panel disable --address="$IBUS_ADDRESS" \
        >"$HOME/ibus.log" 2>&1 & pids+=($!)
    wait_until 5 eval 'ibus engine >/dev/null 2>&1'
    gsettings set org.gnome.desktop.input-sources sources "[('ibus','$SHOTLET_E2E_IBUS')]"
fi
# SHOTLET_E2E_EXTENSIONS="path/uuid ...": user extensions, enabled before gnome-shell
# starts (a running shell on Wayland never discovers new ones)
if [ -n "${SHOTLET_E2E_EXTENSIONS:-}" ]; then
    uuids=
    for e in $SHOTLET_E2E_EXTENSIONS; do
        mkdir -p "$XDG_DATA_HOME/gnome-shell/extensions"
        cp -r "$e" "$XDG_DATA_HOME/gnome-shell/extensions/"
        uuids="$uuids${uuids:+, }'$(basename "$e")'"
    done
    gsettings set org.gnome.shell disable-user-extensions false
    gsettings set org.gnome.shell enabled-extensions "[$uuids]"
fi
: >"$SHOTLET_E2E_SHELL_LOG"
start_gnome_shell ${SHOTLET_E2E_MONITORS:-1600x900} ||
    { echo "session.sh: gnome-shell did not start" >&2; tail "$SHOTLET_E2E_SHELL_LOG" >&2; exit 77; }
pids+=("$SHELL_PID")
# (its first frames and the portals' startup: nothing marks them done)
sleep 1
"$@"
