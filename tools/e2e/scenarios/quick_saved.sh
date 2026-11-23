# Saving from the thumbnails, and their menus' Show in Files (sourced by
# tools/e2e.sh's inner side, with its helpers): Save ends a card, Alt held
# keeps it, Copy keeps it; Show in Files asks the file manager. A
# stand-in file manager owns org.freedesktop.FileManager1 (so no real one
# starts), and the bus is watched for its ShowItems calls.
#   quick-saved

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
    saved_card_goes
    saved_alt_keeps
    saved_menu_shows
    unsaved_menu_dim
    copy_keeps
    menu_show_fails
    video_menu_shows
    video_save_goes
}

saves() { cat "$OUT"/*.log 2>/dev/null | grep -o "quick access: saved to .*"; }
_saved_more() { [ "$(saves | wc -l)" -gt "$1" ]; }
point() { read -r PX PY <<<"$(card_point "$1" "$2")"; } # point DX DY: a card's point in PX PY
hover() { point 120 75 && drv move 0 "$PX" "$PY" && sleep 0.4; }
away() { drv move 0 800 300 && sleep 0.5; }
# card_save [alt]: save the newest card with its Save button (Alt held
# with `alt`); the file in SAVED
card_save() {
    local n
    n=$(saves | wc -l)
    hover
    point 60 23 # Save: the first button
    drv move 0 "$PX" "$PY"
    drv sleep 150
    if [ "${1:-}" = alt ]; then
        drv key alt down && drv sleep 150 && drv click && drv sleep 150 && drv key alt up
    else
        drv click
    fi
    wait_until 5 _saved_more "$n"
    SAVED=$(saves | tail -1 | cut -d' ' -f5-)
}
# new_capture NAME: another capture, its card shown
new_capture() {
    local n
    n=$(shown_count)
    red_capture "$@"
    new_card "$n"
}
# menu_show: the newest card's menu, then its Show in Files (the menu's
# middle row on both cards: 7 rows on the screenshot card, 5 on the
# video card, centred)
menu_show() {
    hover
    drv click right
    sleep 0.4
    shot 0 "menu-$1"
    drv click
}

saved_card_goes() {
    new_capture first first
    card_save
    check "the card's Save saves into Pictures" eval '[[ "$SAVED" == "$HOME/Pictures/shotlet-"*.png ]]'
    shot 0 saved
    check "  ... says Saved, and the card goes" wait_until 3 eval '! card_shows'
    check "  ... with no notification (the card said it)" no_log "Saved to" "$OUT/notify.txt"
}

saved_alt_keeps() {
    new_capture second
    card_save alt
    check "Save with Alt held saves" any_log 3 "quick access: saved, kept open \(Alt\)"
    away
    sleep 1.5
    shot 0 alt-kept
    check "  ... and keeps the card" card_shows
}

# the card Alt kept: its menu's Show in Files shows the saved file
saved_menu_shows() {
    menu_show saved
    check "the menu's Show in Files asks the file manager for the saved file (ShowItems)" asked_to_show 5 "$SAVED"
    check "  ... which the file manager got" wait_log 3 "^ShowItems file://$SAVED$" "$OUT/fm.log"
    check "  ... and the card goes" wait_until 5 eval '! card_shows'
}

# not saved: the capture as kept in the history
# not saved: the item is dimmed (the kept copy is in Shotlet's own state
# folder) and does nothing
unsaved_menu_dim() {
    local n
    new_capture third
    n=$(grep -c "^ShowItems" "$OUT/fm.log")
    menu_show unsaved
    sleep 1
    check "before a save, Show in Files is dimmed and does nothing" eq "$(grep -c "^ShowItems" "$OUT/fm.log")" "$n"
    away
    check "  ... the card stays" card_shows
}

# (the same card)
copy_keeps() {
    hover
    point 177 23 # Copy
    click 0 "$PX" "$PY"
    check "Copy keeps the card (as before)" any_log 3 "quick access: copied"
    away
    sleep 1.5
    check "  ... on screen" card_shows
}

# a file manager that refuses: the problem card; the card stays (saved
# with Alt held, so that it stays for its menu)
menu_show_fails() {
    card_save alt
    echo fail >"$OUT/fm.mode"
    menu_show refused
    check "when the file manager fails, a problem card says so" \
        any_log 10 "toast: Couldn.{1,3}t open the file manager: The file is at "
    sleep 1
    away
    shot 0 refused
    check "  ... and the thumbnail stays" card_shows
    echo ok >"$OUT/fm.mode"
    stop_kept quick
}

# video_card N: a made-up recording (its entry and a file) shown in its
# thumbnail; its process in VID_PID
video_card() {
    local hist=$XDG_STATE_HOME/shotlet/history id=1795280000000-0000f00$1
    mkdir -p "$hist/$id" "$HOME/Videos"
    drv mkpng "$hist/$id/thumb.png" 480 300 "$RED" plain
    head -c 4096 /dev/urandom >"$OUT/rec$1.mp4"
    printf 'shotlet-video 1\npath=%s\nformat=mp4\nduration_ms=4200\nframes=126\nfps=30\nsize=1600x900\nstrip=\n' \
        "$OUT/rec$1.mp4" >"$hist/$id/video"
    "$BIN" quick-video "$hist" "$id" >"$OUT/video$1.log" 2>&1 &
    VID_PID=$!
    wait_log 10 "quick video: showing" "$OUT/video$1.log" && sleep 1
}
video_gone() { ! kill -0 "$VID_PID" 2>/dev/null; }

video_menu_shows() {
    video_card 1
    menu_show video
    check "a recording's menu has Show in Files: the file manager asked for the recording" asked_to_show 5 "$OUT/rec1.mp4"
    check "  ... and its thumbnail goes" wait_until 5 video_gone
}

video_save_goes() {
    video_card 2
    hover
    point 177 23 # Save as...
    click 0 "$PX" "$PY"
    wait_button 0 15
    sleep 1.5 # (the chooser takes the keyboard once mapped)
    keys ctrl+a v i d enter
    check "a recording's Save as... saves" wait_log 10 "quick video: saved to $HOME/Videos/vid.mp4" "$OUT/video2.log"
    check "  ... and its thumbnail goes" wait_until 5 video_gone
}
