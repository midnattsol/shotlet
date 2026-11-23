# After-capture scenarios of the container suite (sourced by scenarios.sh,
# with lib.sh's helpers): the thumbnail as a layer-shell surface, pins and
# the history panel.
#   quick  pin  history

# app_clicks: the clicks the drop target got so far
app_clicks() { grep -c "^click" "$OUT/drop.log"; }
_clicked_since() { [ "$(app_clicks)" -gt "$1" ]; }
# click_app MON X Y: a click on the drop target, until it got it
click_app() {
    local n
    n=$(app_clicks)
    click "$@" && wait_until 3 _clicked_since "$n"
}
# hover_card: the pointer on the newest card, which then shows its buttons
hover_card() {
    local x y
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.4 # (they fade in; nothing logs it)
}

scenario_quick() {
    local x y
    quick_cfg
    check "another app is up and focused" start_app droptarget
    red_capture shotlet-first
    check "the thumbnail appears after Copy" any_log 10 "quick access: showing"
    check "  ... as a layer-shell surface" any_log 1 "quick access: showing .*\(layer shell\)"
    wait_until 5 card_red
    shot 0 thumb
    check "  ... bottom-left, above the other app" card_red
    keys a b c
    check "the other app keeps the keyboard (typing reaches it)" app_said 3 "^text c"
    check "a click beside the card (its shadow) reaches the app below" click_app 0 14 $((MH - 14))
    click_app 0 $((MW / 2)) $((MH / 2))
    check "  ... and the thumbnail stays above it" card_red
    hover_card
    shot 0 hover
    clip_set "something else"
    read -r x y <<<"$(card_point 177 23)" # Copy: the second button until saved
    click 0 "$x" "$y"
    any_log 3 "quick access: copied"
    drv move 0 $((MW / 2)) $((MH / 3))
    sleep 0.3 # (the card gives up the keyboard as the pointer leaves; nothing logs it)
    keys a
    if [ "$COMP" = kwin ]; then
        # KWin keeps the keyboard on a layer surface that clicked and
        # then went back to no keyboard interactivity
        check "after a click on the card and leaving it, typing does not run its shortcuts (A: Annotate)" \
            any_log 3 "key ignored, the pointer is elsewhere"
    else
        check "after a click on the card, once the pointer leaves it, typing reaches the app again" app_said 3 "^text a"
    fi
    check "  ... (no editor opened)" no_log "editing .* again"
    # (wl-paste maps a surface of its own on KWin, which moves the focus)
    check "the card's Copy puts the PNG back on the clipboard" clip_is clip "$CAP_SIZE"
    read -r x y <<<"$(card_point 120 75)"
    slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
    check "dragging the card drops the PNG into the app" app_said 5 "^drop image/png [0-9]+ 89504e47"
    check "  ... and the thumbnail goes away" any_log 5 "quick access: dropped"
    check "  ... from the screen" wait_until 3 eval '! card_red'
    shot 0 dropped
}

# _pin_at "CX CY W H" [X0 Y0 X1 Y1]: the red pin is found right there
_pin_at() { find_on 0 "$RED" 40 20 "${@:2}" && [ "$VAL" = "$1" ]; }
_pin_moved_from() { find_on 0 "$RED" 40 20 && [ "${VAL%% *}" != "$1" ]; }

scenario_pin() {
    local x y ex ey ew eh cx0 cy0 cx1 cy1
    quick_cfg
    start_app droptarget
    red_capture shotlet-first
    any_log 10 "quick access: showing"
    wait_until 5 card_red
    hover_card
    read -r x y <<<"$(card_point 219 129)"
    click 0 "$x" "$y"
    check "the card's Pin opens a pin" any_log 5 "pin: showing"
    check "  ... as a layer-shell surface" any_log 1 "pin: showing .*layer shell"
    # 1:1 at margin 120,120 plus the shadow room (app/pin/state.zig
    # shadow_room, 32 logical px)
    drv findpng "$OUT/shotlet-first.png" "$RED" 40 20; read -r ex ey ew eh <<<"$VAL"
    wait_until 5 _pin_at "$((ex + 152)) $((ey + 152)) $ew $eh"
    read -r cx0 cy0 _ <<<"$VAL"
    check "  ... at its place, 1:1" eq "$VAL" "$((ex + 152)) $((ey + 152)) $ew $eh"
    shot 0 pinned
    click_app 0 $((MW - 40)) 40
    check "  ... above the app after clicking the app" find_on 0 "$RED" 40 20
    keys a
    check "  ... which keeps the keyboard" app_said 3 "^text a"
    # drag the pin by its picture: +200, +100
    slow_drag 0 400 400 450 420 500 450 550 470 600 500
    wait_until 3 _pin_moved_from "$cx0"
    read -r cx1 cy1 _ <<<"$VAL"
    shot 0 pin-moved
    echo "  pin centre ${cx0},${cy0} -> ${cx1},${cy1}" >&2
    check "dragging the pin moves it with the pointer (+200, +100)" \
        test $((cx1 - cx0)) -ge 190 -a $((cx1 - cx0)) -le 210 -a $((cy1 - cy0)) -ge 90 -a $((cy1 - cy0)) -le 110
    # the compositor's own cursors (cursor-shape-v1; debug builds log them)
    check "  ... an open hand over it (the desktop's cursor)" any_log 1 "cursor: grab via cursor-shape"
    check "  ... closed while dragging it" any_log 1 "cursor: grabbing via cursor-shape"
    keys b
    app_said 0.5 "^text b" && echo "  (after the drag the app has the keyboard)" >&2
    click 0 $((cx1 + 100)) $((cy1 + 50))
    sleep 0.3 # (the compositor moves the keyboard focus a moment after the click)
    keys c
    app_said 0.5 "^text c" && echo "  (after a click on the pin the app has the keyboard)" >&2
    keys esc
    check "Esc closes the pin" any_log 5 "pin: closed"
    pin_menu_layer
}

# Pins --at a place (the layer surface's margins), the menu (right-click),
# its opacity key and Close All Pins. The test picture is 300x200, red
# inside 60..240 x 40..160; the menu opens with its top-left at the
# pointer, its last row (Close All Pins) 237..267 px down.
pin_menu_layer() {
    drv mkpng "$OUT/small.png" 300 200 "$RED"
    run_shotlet pin-a pin "$OUT/small.png" --at 400,300
    wait_log 5 "pin: showing"
    run_shotlet pin-b pin "$OUT/small.png" --at 1000,300
    wait_log 5 "pin: showing"
    # (180x120 centred on 400,300: find's centre rounds down)
    wait_until 5 _pin_at "399 299 180 120" 0 0 700 "$MH"
    check "a pin --at X,Y opens centred there" eq "$VAL" "399 299 180 120"
    shot 0 pins-at
    drv move 0 350 260
    sleep 0.3 # (the pin takes the pointer on its first motion over it)
    click 0 330 250 right
    check "right-click on a pin opens its menu" wait_log 3 "pin: menu open" "$OUT/pin-a.log"
    check "  ... beside the pointer" wait_find 3 0 "$MENU_BG" 3 200 330 250 700 600
    shot 0 pin-menu
    # the open menu has the keyboard
    keys 3
    check "  ... and 3 sets the pin to 50%" wait_log 3 "pin: opacity 50%" "$OUT/pin-a.log"
    click 0 458 502
    check "Close All Pins closes that pin" wait_log 3 "pin: closed" "$OUT/pin-a.log"
    check "  ... and the other" wait_log 3 "pin: closed" "$OUT/pin-b.log"
}

scenario_history() {
    quick_cfg
    start_app droptarget
    red_capture shotlet-one
    any_log 10 "quick access: showing"
    stop_kept quick
    run_shotlet shotlet-panel history
    check "Recent captures lists the capture" wait_log 5 "history: 1 captures"
    sleep 1.5 # (the panel maps and takes the keyboard after it lists; nothing logs that)
    shot 0 panel
    keys tab enter
    check "Enter copies the picked capture" wait_log 5 "history: copied"
    # Esc drops the pick, a second one closes; the process stays to
    # serve the copy until another app copies
    keys esc esc
    check "Esc twice closes the panel" wait_until 3 no_find_on 0 "$RED" 40 20
    shot 0 closed
    check "  ... the copy is a PNG" clip_png "$OUT/hclip.png"
    check "  ... of the capture's size" eq "$(png_size "$OUT/hclip.png")" "$CAP_SIZE"
    clip_set "something else"
    check "  ... which then exits once another app copies" wait_exit 5
}
