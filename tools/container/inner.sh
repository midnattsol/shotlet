#!/bin/bash
# Inside the container (tools/container/run.sh): a private session bus,
# PipeWire + WirePlumber, one headless compositor and its portal backend,
# then one scenario against the real shotlet binary.
#
# usage: inner.sh COMPOSITOR SCENARIO
# COMPOSITOR: sway | labwc | kwin; SCENARIO: a row of table.sh, which
# says what outputs it wants and what it needs. The helpers come from
# /opt/shotlet/common (tools/e2e-common) and lib.sh. Logs and screenshots
# go to /out. Prints PASS/FAIL/SKIP lines.
set -u
COMP=$1 SCEN=$2
CTR=/opt/shotlet/ctr
COMMON=/opt/shotlet/common
BINDIR=/opt/shotlet/bin
OUT=/out
E2E_TAG="$COMP $SCEN"
. "$COMMON/report.sh"
. "$COMMON/session.sh"
. "$COMMON/table.sh"
. "$CTR/table.sh"

case " $COMPOSITORS " in *" $COMP "*) ;; *) echo "inner.sh: unknown compositor $COMP" >&2; exit 2 ;; esac
scenario_row "$SCEN" || { fail "no such scenario"; exit 2; }
# what this container cannot run
if [ -z "${CTR_RENDER_NODE:-}" ]; then
    if [ "$COMP" = kwin ]; then
        skip "KWin without a GPU render node composites with QPainter: no screenshots, no screencasts"
        exit 0
    elif scenario_flag gpu; then
        skip "the portal's screencast needs a GPU render node (/dev/dri/renderD*)"
        exit 0
    fi
fi

if [ -z "${CTR_INNER:-}" ]; then
    [ "${SHOTLET_E2E_SANDBOX:-}" = container ] || { echo "inner.sh: only inside the container" >&2; exit 2; }
    export HOME=${HOME:-/tmp/home}
    mkdir -p "$HOME"
    sandbox_env container
    # (CTR_INNER: the second pass, inside the private bus)
    export CTR_INNER=1
    exec dbus-run-session -- "$0" "$@" 2> >(grep --line-buffered -v '^dbus-daemon\[' >&2)
fi

# ------------------------------------------------------------- the session
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT
# who stops a scenario early leaves a trace
trap 'echo "inner.sh: SIGTERM at $(date +%T)" >&2; ps -eo pid,ppid,stat,etime,comm >&2; exit 143' TERM

# a stuck scenario leaves a process list behind (run.sh stops it at 300 s)
# (process names first: reading another process's command line can block
# when it is stuck in the kernel)
( sleep 270
  ps -eo pid,ppid,stat,wchan:32,etime,comm >"$OUT/stuck-ps.txt" 2>&1
  for p in /proc/[0-9]*; do echo "${p#/proc/} $(cat "$p/wchan" 2>/dev/null) $(cat "$p/comm" 2>/dev/null)"; done >>"$OUT/stuck-ps.txt"
  timeout 5 ps -eo pid,args >>"$OUT/stuck-ps.txt" 2>&1 ) &
pids+=($!)

start_pipewire "$OUT"

# as a Plasma session does: KService (which KWin asks which .desktop file
# an executable belongs to) only lists applications found through a menu
[ "$COMP" = kwin ] && export XDG_MENU_PREFIX=plasma-

# Shotlet installed as a person would (install.sh into ~/.local), so KWin
# finds its .desktop file; on KWin a `portal` scenario leaves it out to
# see the portal take over when KWin refuses direct capture
if [ "$COMP" = kwin ] && scenario_flag portal; then
    export SHOTLET_BIN=$BINDIR/shotlet
else
    PREFIX=$HOME/.local /opt/shotlet/pkg/install.sh --no-gnome-extension >"$OUT/install.log" 2>&1 ||
        { fail "install.sh"; exit 1; }
    export SHOTLET_BIN=$HOME/.local/bin/shotlet
fi
# the test driver asks KWin the same way for its input and screenshots
mkdir -p "$XDG_DATA_HOME/applications"
cat >"$XDG_DATA_HOME/applications/shotlet-wldrive.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Shotlet test driver
Exec=$BINDIR/shotlet-wldrive
X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2
X-KDE-Wayland-Interfaces=org_kde_kwin_fake_input
EOF
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1

# the outputs the scenario wants (its row in table.sh, or E2E_MONITORS)
MONITORS=${E2E_MONITORS:-$S_MONS}
[ "$COMP" != kwin ] && scenario_flag portal && export SHOTLET_NO_DIRECT=1
set -- $MONITORS
NMON=$#

mkdir -p "$XDG_CONFIG_HOME/xdg-desktop-portal" "$XDG_CONFIG_HOME/xdg-desktop-portal-wlr"
xkbcli compile-keymap --layout us >"$HOME/keymap.xkb"
export WLDRIVE_KEYMAP=$HOME/keymap.xkb

# wlr-randr: size, place and scale the headless outputs left to right
# (WxH[@SCALE][/TRANSFORM], e.g. 1600x900/90)
layout_wlr() {
    local x=0 i=1 m mode scale name tr w
    for m in $MONITORS; do
        tr=normal
        case $m in */*) tr=${m#*/}; m=${m%/*} ;; esac
        mode=${m%@*} scale=1
        [ "$m" != "$mode" ] && scale=${m#*@}
        name=HEADLESS-$i
        wlr-randr --output "$name" --custom-mode "$mode" --pos "$x,0" --scale "$scale" --transform "$tr" >>"$OUT/compositor.log" 2>&1 || return 1
        w=${mode%x*}
        case $tr in 90 | 270 | flipped-90 | flipped-270) w=${mode#*x} ;; esac
        x=$((x + w / scale))
        i=$((i + 1))
    done
}

# wlroots_up NAME: the compositor's socket (whatever it named it) is in
# WAYLAND_DISPLAY, and all the outputs exist
wlroots_up() {
    wait_socket "$XDG_RUNTIME_DIR/wayland-*" 10 || { fail "$1 did not start"; exit 1; }
    export WAYLAND_DISPLAY=${SOCKET##*/}
}
outputs_up() { [ "$(wlr-randr 2>/dev/null | grep -c '^HEADLESS-')" -ge "$NMON" ]; }

# wlroots: headless outputs, GLES2 on the render node when there is one
# (xdg-desktop-portal-wlr needs dmabuf-capable screencopy), else pixman
wlr_env() {
    export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
    if [ -n "${CTR_RENDER_NODE:-}" ]; then
        export WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=$CTR_RENDER_NODE
    else
        export WLR_RENDERER=pixman
    fi
}

case $COMP in
    sway)
        export XDG_CURRENT_DESKTOP=sway
        wlr_env
        cat >"$HOME/sway.conf" <<'EOF'
default_border none
focus_follows_mouse no
seat * hide_cursor 0
EOF
        sway -c "$HOME/sway.conf" >"$OUT/compositor.log" 2>&1 & pids+=($!)
        wlroots_up sway
        wait_socket "$XDG_RUNTIME_DIR/sway-ipc.*" 5
        export SWAYSOCK=$SOCKET
        for i in $(seq 2 "$NMON"); do swaymsg create_output >/dev/null; done
        wait_until 5 outputs_up
        layout_wlr || { fail "could not lay out the outputs"; exit 1; }
        ;;
    labwc)
        export XDG_CURRENT_DESKTOP=wlroots:labwc
        wlr_env
        export WLR_HEADLESS_OUTPUTS=$NMON
        mkdir -p "$XDG_CONFIG_HOME/labwc"
        cat >"$XDG_CONFIG_HOME/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <focus><followMouse>no</followMouse></focus>
  <windowRules>
    <windowRule identifier="shotlet-droptarget"><action name="Maximize"/></windowRule>
  </windowRules>
</labwc_config>
EOF
        labwc >"$OUT/compositor.log" 2>&1 & pids+=($!)
        wlroots_up labwc
        wait_until 5 outputs_up
        layout_wlr || { fail "could not lay out the outputs"; exit 1; }
        ;;
    kwin)
        # (not KDE_FULL_SESSION: kwin_wayland crashes on start with it)
        export XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6
        # no KWIN_*_NO_PERMISSION_CHECKS: Shotlet and the driver are
        # authorized by their .desktop files, as on a real desktop
        # OpenGL on the render node when there is one (screenshots and
        # screencasts need it), else QPainter
        [ -n "${CTR_RENDER_NODE:-}" ] || export KWIN_COMPOSE=Q
        export QT_QPA_PLATFORM=wayland
        mode=${1%@*}
        QT_LOGGING_RULES="${CTR_KWIN_LOG:-}" kwin_wayland --virtual --no-lockscreen --socket wayland-kw --output-count "$NMON" \
            --width "${mode%x*}" --height "${mode#*x}" >"$OUT/compositor.log" 2>&1 & pids+=($!)
        wait_socket "$XDG_RUNTIME_DIR/wayland-kw" 10 || { fail "kwin did not start"; tail "$OUT/compositor.log" >&2; exit 1; }
        export WAYLAND_DISPLAY=wayland-kw
        # kwin wakes xdg-desktop-portal while it starts, before its socket
        # is in the activation environment: the KDE backend dies then and
        # the portal never retries. Stop both once kwin has woken them (a
        # moment after its socket: nothing tells when); the bus restarts
        # them later.
        sleep 1
        pkill -f /usr/libexec/xdg-desktop-portal 2>/dev/null
        wait_until 3 eval '! pgrep -f /usr/libexec/xdg-desktop-portal >/dev/null'
        ;;
esac

# xdg-desktop-portal-wlr: the "chooser" is a script that logs each call
# and names the first output (or $HOME/chooser-output), no dialog
cat >"$XDG_CONFIG_HOME/xdg-desktop-portal-wlr/config" <<EOF
[screencast]
chooser_type=simple
chooser_cmd=$CTR/chooser.sh
EOF
case $COMP in
    sway | labwc) printf '[preferred]\ndefault=wlr\n' >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" ;;
    kwin) printf '[preferred]\ndefault=kde\n' >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" ;;
esac
# xdg-desktop-portal's test hook naming the client's app (a real session
# derives it from the app's systemd scope): restore tokens are per app
export XDG_DESKTOP_PORTAL_TEST_APP_ID=${CTR_PORTAL_APP_ID:-shotlet}
vars=()
for v in HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME \
    XDG_CACHE_HOME XDG_CURRENT_DESKTOP XDG_SESSION_TYPE WAYLAND_DISPLAY LANG \
    QT_QPA_PLATFORM XDG_DESKTOP_PORTAL_TEST_APP_ID SWAYSOCK KDE_SESSION_VERSION XDG_MENU_PREFIX; do
    [ -n "${!v:-}" ] && vars+=("$v")
done
dbus-update-activation-environment "${vars[@]}"

. "$CTR/scenarios.sh"
run_scenario "$SCEN"
exit $failed
