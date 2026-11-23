# The thumbnail's "Saved · Show in Files" link (sourced by tools/e2e.sh's
# inner side, with its helpers): a stand-in file manager owns
# org.freedesktop.FileManager1 (so no real one starts), and the bus is
# watched for its ShowItems calls.
#   quick-saved

# the link lit under the pointer: theme.accent_fill_hover, the default
# accent's fill (ACCENT_FILL) darkened by 12%
LINK_HOVER=2968b3

# fake_file_manager: own org.freedesktop.FileManager1 until the scenario
# ends; ShowItems logs "ShowItems URI..." on $OUT/fm.log and answers as
# $OUT/fm.mode says (ok, or fail: an error reply)
fake_file_manager() {
    echo ok >"$OUT/fm.mode"
    : >"$OUT/fm.log"
    "$PYGTK" -I - "$OUT/fm.mode" >>"$OUT/fm.log" 2>&1 <<'EOF' &
import sys
from gi.repository import Gio, GLib

MODE = sys.argv[1]
XML = """<node><interface name="org.freedesktop.FileManager1">
<method name="ShowItems"><arg type="as" direction="in"/><arg type="s" direction="in"/></method>
</interface></node>"""


def call(conn, sender, path, iface, method, params, inv):
    uris = params.unpack()[0]
    print("ShowItems", *uris, flush=True)
    if open(MODE).read().strip() == "fail":
        inv.return_dbus_error("org.freedesktop.DBus.Error.Failed", "e2e: refused")
    else:
        inv.return_value(None)


def acquired(conn, name):
    print("owned", flush=True)


def bus(conn, name):
    info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
    conn.register_object("/org/freedesktop/FileManager1", info, call, None, None)


Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.FileManager1",
                 Gio.BusNameOwnerFlags.NONE, bus, acquired, None)
GLib.MainLoop().run()
EOF
    wait_log 5 "^owned" "$OUT/fm.log"
}

# showitems_watch: the ShowItems calls on the session bus go to
# $OUT/showitems.txt (dbus-monitor; false, with a SKIP, without it)
showitems_watch() {
    require dbus-monitor || return
    : >"$OUT/showitems.txt"
    dbus-monitor --session "type='method_call',interface='org.freedesktop.FileManager1',member='ShowItems'" \
        >>"$OUT/showitems.txt" 2>&1 &
    wait_until 3 test -s "$OUT/showitems.txt"
    return 0
}
asked_to_show() { wait_log "$1" "string \"file://$2\"" "$OUT/showitems.txt"; } # asked_to_show SECS PATH
card_shows() { find_on 0 "$PEN_RED" 40 4 0 700 300 900; }

scenario_quick_saved() {
    quick_cfg
    cfg_set notify=true
    drv_ready Meta-0
    require_pygtk || return
    plain_desktop
    check "a stand-in file manager owns FileManager1" fake_file_manager || return
    showitems_watch || return
    notify_watch
    drv move 0 800 450
    red_capture first first
    check "thumbnail shown" wait_log 10 "quick access: showing"
    sleep 1
    saved_link_click
    saved_link_keys
    saved_link_video
    saved_link_fails
}

saves() { cat "$OUT"/*.log 2>/dev/null | grep -o "quick access: saved to .*"; }
_saved_more() { [ "$(saves | wc -l)" -gt "$1" ]; }
# card_save: save the newest card with its Save button; the file in SAVED
card_save() {
    local x y n
    n=$(saves | wc -l)
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.4
    read -r x y <<<"$(card_point 60 23)" # Save: the first button until saved
    click 0 "$x" "$y"
    wait_until 5 _saved_more "$n"
    SAVED=$(saves | tail -1 | cut -d' ' -f5-)
}

saved_link_click() {
    local x y
    card_save
    check "the card's Save saves into Pictures" eval '[[ "$SAVED" == "$HOME/Pictures/shotlet-"*.png ]]'
    sleep 1
    check "  ... with no notification (the card says Saved)" no_log "Saved to" "$OUT/notify.txt"
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.4
    shot 0 saved-link
    check "Saved is a link: the pointing hand over it" any_log 2 "cursor: pointer via cursor-shape"
    check "  ... lit in the accent" find_on 0 "$LINK_HOVER" 8 30 40 760 280 810
    click 0 "$x" "$y"
    check "a click on it asks the file manager to show the file (ShowItems)" asked_to_show 5 "$SAVED"
    check "  ... which the file manager got" wait_log 3 "^ShowItems file://$SAVED$" "$OUT/fm.log"
    check "  ... and the card goes" wait_until 5 eval '! card_shows'
    shot 0 shown
}

# the same from the keyboard: Enter while the link shows
saved_link_keys() {
    local n
    n=$(shown_count)
    red_capture second
    new_card "$n"
    card_save
    keys enter
    check "Enter while Saved shows asks the file manager too" asked_to_show 5 "$SAVED"
    check "  ... and the card goes" wait_until 5 eval '! card_shows'
}

# the recording's thumbnail (a made-up recording: its entry and a file):
# Save as..., then the same link
saved_link_video() {
    local hist=$XDG_STATE_HOME/shotlet/history id=1795280000000-0000f00d x y pid
    mkdir -p "$hist/$id" "$HOME/Videos"
    drv mkpng "$hist/$id/thumb.png" 480 300 "$RED" plain
    head -c 4096 /dev/urandom >"$OUT/rec.mp4"
    printf 'shotlet-video 1\npath=%s\nformat=mp4\nduration_ms=4200\nframes=126\nfps=30\nsize=1600x900\nstrip=\n' \
        "$OUT/rec.mp4" >"$hist/$id/video"
    "$BIN" quick-video "$hist" "$id" >"$OUT/video.log" 2>&1 &
    pid=$!
    check "a recording's thumbnail shown" wait_log 10 "quick video: showing" "$OUT/video.log"
    sleep 1
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.4
    read -r x y <<<"$(card_point 177 23)" # Save as...
    click 0 "$x" "$y"
    wait_button 0 15
    sleep 1.5 # (the chooser takes the keyboard once mapped)
    keys ctrl+a v i d enter
    check "  ... its Save as... saves" wait_log 10 "quick video: saved to $HOME/Videos/vid.mp4" "$OUT/video.log"
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.4
    shot 0 video-link
    check "  ... then its Saved link asks the file manager to show the copy" \
        eval 'click 0 $x $y && asked_to_show 5 "$HOME/Videos/vid.mp4"'
    check "  ... and the thumbnail goes" wait_until 5 eval '! kill -0 $pid 2>/dev/null'
}

# a file manager that refuses: the problem card says so and where the file
# is; the thumbnail stays
saved_link_fails() {
    local n x y
    echo fail >"$OUT/fm.mode"
    n=$(shown_count)
    red_capture third
    new_card "$n"
    card_save
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.3
    click 0 "$x" "$y"
    asked_to_show 5 "$SAVED"
    check "when the file manager fails, a problem card says so" \
        any_log 10 "toast: Couldn.{1,3}t open the file manager: The file is saved as $SAVED"
    sleep 1
    shot 0 refused
    check "  ... and the thumbnail stays" card_shows
}
