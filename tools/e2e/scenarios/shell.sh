# GNOME integration scenarios of tools/e2e.sh (sourced by its inner side,
# with its helpers): `shotlet gnome-integration` install and uninstall,
# Print through the extension with no prompt, on mixed scales, from the
# tray and from a terminal.
#   shell  shell-owner  shell-mixed  shell-tray  shell-terminal

# GNOME's screenshot keys, as gsettings and dconf see them
dump_keys() { for k in show-screenshot-ui screenshot screenshot-window show-screen-recording-ui; do
    echo "$k $(gsettings get org.gnome.shell.keybindings $k) [$(dconf read /org/gnome/shell/keybindings/$k)]"; done; }
# GNOME's custom shortcuts and its shell's keybindings
dump_media_keys() { dconf dump /org/gnome/settings-daemon/plugins/media-keys/; dconf dump /org/gnome/shell/keybindings/; }

# stock GNOME: Print opens GNOME's screenshot tool. install offers Print to
# Shotlet (GNOME's tool moves to Shift+Super+S), the key then captures
# without any prompt, uninstall restores it all
scenario_shell() {
    drv_ready Meta-0
    drv move 0 800 450
    plain_desktop
    shell_install
    shell_print
    shell_early
    shell_refused
    "$BIN" gnome-integration uninstall >"$OUT/uninstall.log" 2>&1
    dump_keys >"$OUT/keys-after.txt"
    check "uninstall gives GNOME its screenshot keys back exactly" cmp -s "$OUT/keys-before.txt" "$OUT/keys-after.txt"
    check "  ... and the extension is gone" test ! -e "$XDG_DATA_HOME/gnome-shell/extensions/$EXT_UUID"
}

shell_install() {
    check "the extension leaves GNOME's Print alone" shell_wait 5 "Print is GNOME's screenshot shortcut" 1
    shell1_prop BlockedShortcuts >"$OUT/blocked.txt"
    check "  ... and says so on the bus" grep -q "Print" "$OUT/blocked.txt"
    dump_keys >"$OUT/keys-before.txt"
    "$BIN" gnome-integration install </dev/null >"$OUT/install.log" 2>&1
    check "install gives Print to Shotlet" grep -q "Print now captures with Shotlet" "$OUT/install.log"
    check "  ... moving GNOME's screenshot tool to Shift+Super+S" eq "$(gsettings get org.gnome.shell.keybindings show-screenshot-ui)" "['<Shift><Super>s']"
    check "  ... and no other GNOME shortcut" eq "$(gsettings get org.gnome.shell.keybindings screenshot) $(gsettings get org.gnome.shell.keybindings screenshot-window)" "['<Shift>Print'] ['<Alt>Print']"
    check "  ... the extension binds Print" eval 'shell1_prop Shortcuts | grep -q Print'
    check "  ... pointing it at this shotlet" eq "$(ext_gsettings get shotlet-path)" "'$BIN'"
    "$BIN" gnome-integration status >"$OUT/status.log" 2>&1
    check "status: captures through the integration" grep -q "capture: through the GNOME integration (no prompts)" "$OUT/status.log"
}

# the capture
shell_print() {
    touch "$OUT/marker"
    sleep 1
    t0=$(date +%s%N)
    drv key print
    check "Print opens Shotlet's editor" shell_wait 10 "startup: capture=" 1
    t1=$(date +%s%N)
    echo "  key to editor (measured outside): $(((t1 - t0) / 1000000)) ms; shotlet says: $(grep -o "key press to editor [0-9]*ms.*" "$SHOTLET_E2E_SHELL_LOG" | tail -1)"
    sleep 0.8
    shot 0 editor
    check "  ... without any consent dialog" no_dialog
    check "  ... or dialog button on screen" no_find_on 0 "$ACCENT" 24 10
    check "  ... the capture file is gone once read" capture_dir_empty
    check "  ... and no capture was written anywhere else" eq "$(new_pngs)" ""
    check "  ... the capture directory is private" eq "$(stat -c %a "$XDG_RUNTIME_DIR/shotlet")" 700
    drv pixel "$OUT/editor.png" 800 600
    check "  ... the editor shows the desktop (dimmed blue)" test "${VAL:2:6}" != "$DESKTOP_BG"
    drag 0 400 300 0 600 400 0 800 500
    keys enter
    check "Copy gives the selection" clip_is clip 400x200
    check "  ... with the desktop's pixels, not the cursor or a dim" pixel_near "$OUT/clip.png" 200 100 "$DESKTOP_BG"
}

# input on the shell's frozen frame, before Shotlet's editor is up, is
# the editor's: a drag begun there selects, Escape closes it
shell_early() {
    local n f
    ext_gap
    n=$(shell_count "frozen screen shown")
    drv key print
    wait_until 5 _shell_count_ge "frozen screen shown" $((n + 1))
    drv move 0 300 200 && drv down && drv move 0 500 350 && drv move 0 700 500
    check "a drag begun on the shell's frozen frame goes on in the editor" shell_wait 15 "startup: capture=" 2
    sleep 1.5
    drv move 0 700 500 && drv up
    keys enter
    check "  ... and selects from where it began" clip_is clip 400x300
    ext_gap
    n=$(shell_count "open timeline")
    f=$(shell_count "frozen screen shown")
    drv key print
    wait_until 5 _shell_count_ge "frozen screen shown" $((f + 1))
    keys esc
    check "Escape on the frozen frame closes the editor as it comes up" shell_wait 15 "Escape on the frozen frame: closed" 1
    sleep 1
    check "  ... before it was ever ready" eq "$(shell_count "open timeline")" "$n"
}

# anyone else asking over the bus is refused
shell_refused() {
    gdbus call --session --dest dev.shotlet.Shell1 --object-path /dev/shotlet/Shell1 \
        --method dev.shotlet.Shell1.CaptureMode area 0 >"$OUT/gdbus.txt" 2>&1
    check "CaptureMode() from another program is refused" grep -q "AccessDenied" "$OUT/gdbus.txt"
    sleep 1
    check "  ... and takes no screenshot" eq "$(shell_count "startup: capture=")" 3
    check "  ... nor leaves a file" capture_dir_empty
}

scenario_shell_owner() {
    # GNOME's screenshot tool off Print and a custom shortcut running
    # shotlet on Print: install moves that shortcut to the extension
    drv_ready Meta-0
    drv move 0 800 450
    gsettings set org.gnome.shell.keybindings show-screenshot-ui "[]"
    CK=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
    CKS=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$CK
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$CK']"
    gsettings set "$CKS" name 'Shotlet'
    gsettings set "$CKS" command "$BIN"
    gsettings set "$CKS" binding 'Print'
    dump_media_keys >"$OUT/before.txt"
    "$BIN" gnome-integration install </dev/null >"$OUT/install.log" 2>&1
    check "install moves the custom shortcut running shotlet" grep -q "Moved" "$OUT/install.log"
    check "  ... off GNOME's custom shortcuts" eq "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" "@as []"
    check "  ... to the extension's key" eq "$(ext_gsettings get capture-shortcut)" "['Print']"
    check "  ... which it binds" eval 'shell1_prop Shortcuts | grep -q Print'
    check "  ... leaving GNOME's shortcuts alone" eq "$(gsettings get org.gnome.shell.keybindings show-screenshot-ui)" "@as []"
    drv key print
    check "Print opens Shotlet's editor" shell_wait 10 "startup: capture=" 1
    check "  ... without any consent dialog" no_dialog
    sleep 0.8
    keys esc
    "$BIN" gnome-integration uninstall >"$OUT/uninstall.log" 2>&1
    dump_media_keys >"$OUT/after.txt"
    check "uninstall puts the custom shortcut back exactly" cmp -s "$OUT/before.txt" "$OUT/after.txt"
}

scenario_shell_mixed() {
    # Meta-0 2560x1440 at 2 (1280x720 logical), Meta-1 1280x720 at 1:
    # the shell paints the stage at 2, Shotlet maps both monitors on it
    plain_desktop
    "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
    drv_ready Meta-0 Meta-1
    drv move 0 1280 720
    free_print
    touch "$OUT/marker"
    drv key print
    check "Print opens the editor on both monitors" shell_wait 10 "startup: capture=" 1
    check "  ... capturing both" grep -q "monitors=2 through the GNOME integration" "$SHOTLET_E2E_SHELL_LOG"
    echo "  $(grep -o "key press to editor [0-9]*ms.*" "$SHOTLET_E2E_SHELL_LOG" | tail -1)"
    sleep 0.8
    shot 0 editor0
    shot 1 editor1
    check "  ... with no consent dialog" no_dialog
    check "  ... the capture file is gone" capture_dir_empty
    check "  ... nothing written elsewhere" eq "$(new_pngs)" ""
    # 480x300 logical across the seam, from the top: monitor 0's top
    # bar (it is the primary) on the left, plain desktop on the right
    drag 0 2000 0 0 2550 300 1 100 450 1 200 300
    sleep 0.3
    shot 0 sel0
    keys ctrl+c
    check "the selection is exported at 2x" clip_is clip 960x600
    drv pixel "$OUT/clip.png" 100 8
    check "  ... the 2x monitor's top bar on the left" test "${VAL:2:6}" != "$DESKTOP_BG"
    check "  ... the desktop below it" pixel_near "$OUT/clip.png" 100 300 "$DESKTOP_BG"
    check "  ... the 1x monitor (no top bar) on the right" pixel_near "$OUT/clip.png" 800 8 "$DESKTOP_BG"
    drv pixel "$OUT/clip.png" 559 8; a=$VAL
    drv pixel "$OUT/clip.png" 561 8; b=$VAL
    check "  ... meeting at the seam (x=560)" eval 'test "${a:2:6}" != "$DESKTOP_BG" && near "$b" "$DESKTOP_BG"'
    # once more, everything warm (the portal running, as in a session)
    sleep 1
    drv key print
    check "a second Print captures too" shell_wait 10 "startup: capture=" 2
    echo "  warm: $(grep -o "key press to editor [0-9]*ms.*" "$SHOTLET_E2E_SHELL_LOG" | tail -1)"
    sleep 0.8
    keys esc
}

scenario_shell_tray() {
    # the tray's Take screenshot asks the extension (CaptureMode()), which
    # takes the shot and starts the editor; no prompt, no child capture
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet daemon --daemon -f
    sleep 1
    ext_gsettings set shotlet-path "'$BIN'"
    sni Activate 0 0
    check "tray Activate captures through the extension" shell_wait 10 "startup: capture=" 1
    check "  ... with no consent dialog" no_dialog
    sleep 0.8
    keys esc
    sleep 1.2
    gdbus call --session --dest io.github.midnattsol.Shotlet --object-path /MenuBar \
        --method com.canonical.dbusmenu.Event 1 clicked "<0>" 0 >/dev/null 2>&1
    check "  ... and so does the menu's Take screenshot" shell_editor 2
    keys esc
    sleep 1.2
    # rate limit: two asks at once give one capture
    sni Activate 0 0
    sni Activate 0 0
    sleep 3
    check "two asks at once start one capture" eq "$(shell_count "startup: capture=")" 3
    check "  ... the other one declined" grep -q "Error.Busy" "$SHOT_LOG"
    check "  ... and no portal capture child" no_log "screencast" "$SHOT_LOG"
    keys esc
    check "the daemon keeps running" alive
}

scenario_shell_terminal() {
    # `shotlet` from a terminal asks the extension too
    drv_ready Meta-0
    drv move 0 800 450
    ext_gsettings set shotlet-path "'$BIN'"
    t0=$(date +%s%N)
    run_shotlet term
    check "shotlet hands the capture to the extension" wait_exit 5
    check "  ... and exits with status 0" eq "$RC" 0
    check "  ... saying so" grep -q "capture handed to the GNOME integration" "$SHOT_LOG"
    check "the extension's shotlet opens the editor" shell_wait 10 "startup: capture=" 1
    t1=$(date +%s%N)
    echo "  launch to editor: $(((t1 - t0) / 1000000)) ms"
    check "  ... with no consent dialog" no_dialog
    sleep 0.8
    keys esc
    # `shotlet text`: the extension's shotlet reads text, not an image
    sleep 1.2
    run_shotlet text text
    check "shotlet text hands the capture to the extension" wait_exit 5
    check "  ... whose shotlet is a text capture" shell_wait 10 "text capture: the selected area" 1
    check "  ... in its editor" shell_editor 2
    keys esc
    shell_copy_refused
    # an older or broken integration: the portal path as before
    ext_gsettings set shotlet-path "'/nonexistent/shotlet'"
    sleep 1.2
    run_shotlet portal
    check "if the extension cannot capture, the portal asks" share_dialog 0
    check "  ... and the editor opens" wait_editor 10
    keys esc
}

# shell_copy_refused: a copy of shotlet that is not the one the extension
# answers (zig-out/bin/shotlet beside the installed one): `scroll` is
# refused, and says so plainly once, then stops (exit 1)
shell_copy_refused() {
    local copy=$OUT/copy/shotlet
    local title="The GNOME integration only answers the installed Shotlet"
    mkdir -p "$OUT/copy" && cp "$BIN" "$copy"
    sleep 1.2
    BIN=$copy run_shotlet refused scroll
    check "a copy the extension does not answer: shotlet scroll exits 1" eval 'wait_exit 10 && eq "$RC" 1'
    problem_reported refused scroll "$title" "Run $BIN, or reinstall"
    check "  ... said once" eq "$(grep -c "^shotlet scroll: The GNOME integration only answers" "$OUT/refused.log")" 1
    check "  ... instead of the generic failure" no_log "no frame of the region" "$OUT/refused.log"
    check "  ... and no region picker" no_log "pick a region" "$OUT/refused.log"
    card_gone
}
