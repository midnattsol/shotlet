# The clipboard (wl-clipboard).

is_png() { [ "$(head -c 8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; } # is_png FILE
clip_png() { # clip_png FILE: the clipboard's image/png into FILE
    timeout 5 wl-paste -n -t image/png >"$1" 2>/dev/null && is_png "$1"
}
_clip_size_is() { clip_png "$1" && CLIP_SIZE=$(png_size "$1") && [ "$CLIP_SIZE" = "$2" ]; }
# clip_is NAME WxH [SECS]: within SECS (default 3) the clipboard holds a
# WxH PNG, saved as $OUT/NAME.png
clip_is() {
    CLIP_SIZE=
    wait_until "${3:-3}" _clip_size_is "$OUT/$1.png" "$2" && return 0
    echo "  clipboard: expected a $2 PNG, got '${CLIP_SIZE:-no PNG}'" >&2
    return 1
}
# clip_set TEXT: another app copies TEXT. Without data-control (GNOME)
# (and KWin) wl-copy maps a surface and waits for the keyboard focus to
# set the selection: it gets up to 5 s, then is given up on.
clip_set() {
    timeout 5 wl-copy -- "$*" &
    local pid=$!
    wait_until 5 eval "! kill -0 $pid 2>/dev/null"
}
