# Building blocks of the private sessions the suites run in
# (tools/e2e/session.sh: GNOME; tools/container/inner.sh: wlroots, KWin).
# Nothing here may reach the caller's desktop.

. "$(dirname "${BASH_SOURCE[0]}")/wait.sh"

# sandbox_env KIND: every XDG location inside $HOME (which the caller
# made), no display or session bus of the caller's, and
# SHOTLET_E2E_SANDBOX=KIND (gnome | container), the guard the test helpers
# check before they start
sandbox_env() {
    export XDG_RUNTIME_DIR=$HOME/run
    mkdir -m 700 -p "$XDG_RUNTIME_DIR"
    export XDG_CONFIG_HOME=$HOME/.config XDG_STATE_HOME=$HOME/.local/state \
        XDG_DATA_HOME=$HOME/.local/share XDG_CACHE_HOME=$HOME/.cache
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$HOME/Pictures"
    export LANG=C.UTF-8 XDG_SESSION_TYPE=wayland
    unset WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS PIPEWIRE_REMOTE PULSE_SERVER XDG_PICTURES_DIR
    export SHOTLET_E2E_SANDBOX=$1
}

# wait_socket PATTERN SECS: until a socket matching PATTERN (a path, or a
# glob) exists; its path in SOCKET
wait_socket() { SOCKET=; wait_until "$2" _socket_at "$1"; }
_socket_at() { local f; for f in $1; do [ -S "$f" ] && { SOCKET=$f; return 0; }; done; return 1; }

# start_pipewire LOGDIR: PipeWire and WirePlumber, their pids added to the
# caller's `pids`. WirePlumber watches no device of the machine: no
# camera (V4L2, libcamera), sound card (ALSA) or Bluetooth is opened, so
# a test never turns the camera's light on or touches a microphone.
start_pipewire() {
    local conf=$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d
    mkdir -p "$conf"
    cat >"$conf/90-shotlet-e2e-no-devices.conf" <<'EOF'
wireplumber.profiles = {
  main = {
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
  }
}
EOF
    pipewire >"$1/pipewire.log" 2>&1 &
    pids+=($!)
    wait_socket "$XDG_RUNTIME_DIR/pipewire-0" 5
    wireplumber >"$1/wireplumber.log" 2>&1 &
    pids+=($!)
}

# start_gnome_shell MONITOR...: a headless gnome-shell on wayland-hl with
# those virtual monitors (WxH), output appended to $SHOTLET_E2E_SHELL_LOG; its pid
# in SHELL_PID. True once its socket is up; it waits (up to 20 s) for
# Mutter's RemoteDesktop too, which the input driver needs.
start_gnome_shell() {
    local mons=() m
    for m in "$@"; do mons+=(--virtual-monitor "$m"); done
    WAYLAND_DEBUG=${SHOTLET_E2E_WLDEBUG:-0} gnome-shell --headless --no-x11 "${mons[@]}" \
        --wayland-display wayland-hl >>"$SHOTLET_E2E_SHELL_LOG" 2>&1 &
    SHELL_PID=$!
    wait_until 20 _shell_up
    [ -S "$XDG_RUNTIME_DIR/wayland-hl" ]
}
_shell_up() {
    [ -S "$XDG_RUNTIME_DIR/wayland-hl" ] && gdbus introspect --session \
        --dest org.gnome.Mutter.RemoteDesktop --object-path /org/gnome/Mutter/RemoteDesktop >/dev/null 2>&1
}
