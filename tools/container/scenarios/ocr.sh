# Text recognition scenarios of the container suite (sourced by
# scenarios.sh, with lib.sh's helpers): searching the history by text, and
# the editor's text tools.
#   ocr  ocr-tools

EN_TEXT="Quarterly invoice from Midnattsol"

# search WORDS...: type a search into the history panel; Esc clears the
# previous one first (with an empty one it would close the panel)
search() { [ -n "$searched" ] && keys esc; searched=1; drv type "$*"; }
# _cards_shown N: the thumbnail showed N captures in all
_cards_shown() { [ "$(cat "$OUT"/shotlet-*.log 2>/dev/null | grep -cE "quick access: (showing|added)")" -ge "$1" ]; }

scenario_ocr() {
    local f n=0
    require lib:libtesseract || return
    quick_cfg
    start_app droptarget
    drv textpng "$OUT/en.png" 40 "$EN_TEXT" || { fail "text picture"; return; }
    drv textpng "$OUT/es.png" 40 "Canción del año en España" || { fail "text picture"; return; }
    for f in en es; do
        drv png "$OUT/$f.png"
        run_shotlet "shotlet-$f" shot --from "$OUT/$f.png" --sel "0,0,${VAL%x*},${VAL#*x}"
        wait_editor 10 && keys enter
        n=$((n + 1))
        wait_until 10 _cards_shown "$n"
    done
    stop_kept quick
    LANG=es_ES.UTF-8 run_shotlet shotlet-panel history
    check "the panel has a search field (Tesseract found)" wait_log 5 "text search on"
    check "  ... and reads both captures" wait_log 60 "history: read the text of 2 captures"
    grep "text of" "$SHOT_LOG" | sed 's/^/  /' >&2
    searched=
    search invoice
    check "search 'invoice' finds the English capture" wait_log 3 "search 'invoice': 1 shown"
    search midnattsol quarterly
    check "search 'midnattsol quarterly' (every word) finds it" wait_log 3 "search 'midnattsol quarterly': 1 shown"
    search cancion
    check "search 'cancion' finds 'Canción' (accents folded)" wait_log 3 "search 'cancion': 1 shown"
    search espana
    check "search 'espana' finds 'España'" wait_log 3 "search 'espana': 1 shown"
    search zebra
    check "search 'zebra' finds nothing" wait_log 3 "search 'zebra': 0 shown"
    shot 0 search
    keys esc esc esc
    wait_exit 5
}

# the editor's text tools: shotlet text, Copy text, Redact
scenario_ocr_tools() {
    require lib:libtesseract || return
    cfg_set thumbnail=never
    drv textpng "$OUT/en.png" 40 "$EN_TEXT" || { fail "text picture"; return; }
    drv png "$OUT/en.png"
    W=${VAL%x*} H=${VAL#*x}
    ocr_text_command
    ocr_copy_text
    ocr_redact
}

# `shotlet text` on the picture
ocr_text_command() {
    local x0 y0
    run_shotlet shotlet-text text --from "$OUT/en.png"
    wait_editor 10
    # the picture is centred on the monitor, at 1:1
    x0=$(((MW - W) / 2)) y0=$(((MH - H) / 2))
    select_area 0 $((x0 + 2)) $((y0 + 2)) $((x0 + W - 2)) $((y0 + H - 2))
    check "shotlet text reads the region selected" wait_log 60 "copy text: [0-9]+ bytes"
    check "  ... puts its text on the clipboard" eq "$(clip_text 'text/plain;charset=utf-8')" "$EN_TEXT"
    check "  ... shows a toast with the first line" any_log 10 "toast: Copied: Quarterly invoice"
    clip_set "something else"
    wait_exit 5
}

# in the editor: Copy text (Ctrl+Shift+C) on the selection
ocr_copy_text() {
    run_shotlet shotlet-copytext shot --from "$OUT/en.png" --sel "0,0,$W,$H"
    wait_editor 10
    keys ctrl+shift+c
    check "Copy text in the editor" wait_log 60 "copy text: [0-9]+ bytes"
    check "  ... copies the selection's text" eq "$(clip_text)" "$EN_TEXT"
    check "  ... and the editor stays open" alive
    keys esc esc
    wait_exit 5
    clip_set "something else"
}

# Redact sensitive data finds an e-mail address and a token
ocr_redact() {
    drv textpng "$OUT/secret.png" 36 "Mail jane.doe@example.com key ghp_16C7e42F292c6912E7710c838347Ae178B4a" || { fail "text picture"; return; }
    drv png "$OUT/secret.png"
    W=${VAL%x*} H=${VAL#*x}
    run_shotlet shotlet-redact shot --from "$OUT/secret.png" --sel "0,0,$W,$H"
    wait_editor 10
    keys ctrl+shift+r
    check "Redact sensitive data finds the e-mail address" wait_log 60 "redact: email"
    check "  ... and the token" wait_log 5 "redact: (api_key|token)"
    grep "redact:" "$SHOT_LOG" | sed 's/^/  /' >&2
    shot 0 redacted
    keys enter
    check "  ... the redacted capture copies" wait_until 5 clip_png "$OUT/redacted-clip.png"
    # the redaction covers the address: no black text pixels left where it was
    drv findpng "$OUT/redacted-clip.png" "$REDACT_BOX" 6 40 && echo "  redaction box: $VAL" >&2
    check "  ... with a solid box over it" drv findpng "$OUT/redacted-clip.png" "$REDACT_BOX" 6 40
    clip_set "something else"
    wait_exit 5
}
