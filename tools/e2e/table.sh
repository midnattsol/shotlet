# The GNOME suite's scenarios, one row each: the runner (tools/e2e.sh)
# picks the runs from it and the session each one gets. Each NAME is a
# scenario_NAME function (dashes as underscores) in scenarios/*.sh.
# `tools/e2e.sh --list` prints it.
#
# monitors  the virtual monitors, WxH each
# flags     nothumb    Shotlet's settings say thumbnail=never (these check
#                      what happens without the floating thumbnail)
#           ext        the Shotlet extension, installed and enabled before
#                      the shell starts
#           portal     (with ext) the extension cannot start this shotlet
#                      (shotlet-path points nowhere): captures go through
#                      the portal, the floating windows use the extension
#           layout=L   the XKB layout L
#           ibus=E     the IBus engine E as the only input source
#           manual     only when asked for by name, not in the default run
scenario_table() {
    cat <<'EOF_TABLE'
capture             | 1600x900           | nothumb                | the portal's consent, its restore token, the clipboard, a shortcut-style launch
blink               | 1600x900           | nothumb                | with animations: the editor closes with no ghost frames (filmed)
blink-ext           | 1600x900           | nothumb ext portal     | the same with the extension: it opens with none too
cancel              | 1600x900           | nothumb                | Esc in the portal's dialog ends shotlet, nothing stored
multimon            | 1600x900 1280x720  | nothumb                | both monitors shared, a selection across the seam, one surface each
mixed               | 2560x1440 1280x720 | nothumb                | scales 2 and 1: a selection across the seam exported at 2x
fractional          | 2560x1440 1280x720 | nothumb                | scale 1.5: the selection maps 1:1 to physical pixels, the Copy button
integer             | 2560x1440 1280x720 | nothumb                | the same at scale 2 without fractional scaling
keyboard            | 1600x900           | nothumb layout=es      | typing on a Spanish layout, key repeat, undo, selection modifiers, Esc, saving
clipboard           | 1600x900           | nothumb layout=es      | text pasted in and copied out, the image served until replaced
saveas              | 1600x900           | nothumb                | Save As through the portal's file chooser, and cancelling it
daemon              | 1600x900           | nothumb                | the tray daemon: one at a time, a late tray host, Activate, Quit
fallback            | 1600x900           | nothumb                | no ScreenCast backend: the Screenshot portal, asked from Shotlet's own window (denied, granted)
ime                 | 1600x900           | nothumb ibus=hangul    | an input method (IBus Hangul): preedit, then committed text
cursors             | 1600x900           | nothumb                | the editor's cursors (cursor-shape): crosshair, hands, resize arrows
cursors-drawn       | 2560x1440          | nothumb                | the same drawn by Shotlet at scale 2
quick               | 1600x900           | ext portal             | the thumbnail kept above by the extension: focus, Copy, click-through, drag out (same-second names), Pin
quick-plain         | 1600x900           | -                      | the thumbnail as a plain window without the extension
annotate            | 1600x900           | ext portal             | the thumbnail's Annotate reopens the editor, its Copy updates the capture
pin                 | 1600x900           | nothumb ext portal     | a pin: where it opens, its menu, opacity, Copy, Lock, Save, Annotate, Close All Pins, dark
history             | 1600x900           | ext portal             | Recent captures: kept, listed, saved, copied, deleted, cleared, across a restart
settings            | 1600x900           | -                      | Settings from the keyboard: reset permissions, choices, Clear history, Enable; snapped
shell               | 1600x900           | nothumb ext            | gnome-integration install and uninstall: Print with no prompt, other callers refused
shell-owner         | 1600x900           | nothumb ext            | install moves a custom shortcut running shotlet to the extension, uninstall back
shell-mixed         | 2560x1440 1280x720 | nothumb ext            | Print through the extension on scales 2 and 1
shell-tray          | 1600x900           | nothumb ext            | the tray's captures through the extension, one at a time
shell-terminal      | 1600x900           | nothumb ext            | shotlet and shotlet text from a terminal ask the extension; the portal without it
modes-screen        | 1600x900 1280x720  | ext                    | the monitor under the pointer, all screens, the previous area, after_fullscreen
modes-strip         | 1600x900           | ext                    | the editor's mode strip: a window lit and clicked, its keys, More, dark
modes-timer         | 1600x900           | ext                    | shotlet timer 3: the shell's countdown, not in the capture
modes-window        | 1600x900           | ext                    | the window picker: exactly the window, its corners clear; with its shadow
modes-scroll        | 1600x900           | ext                    | a scrolling capture of a long page, stitched to its height, the marker once
modes-scroll-manual | 1600x900           | ext                    | scroll_auto=false: the person scrolls, a jump warns, Stop ends it
modes-scroll-stops  | 1600x900           | ext                    | why a scrolling capture pauses or stops: didn't move, no match, height limit, Esc
modes-scroll-dark   | 1600x900           | ext                    | the same in the dark appearance
scroll-unavailable  | 1600x900           | -                      | shotlet scroll without the extension says why and exits 1; works after a new login
area-editor         | 1600x900           | ext                    | the editor's area: drag, resize, move, arrows, size, Enter, Shift, click, Esc
area-record         | 1600x900           | ext                    | the same in the recording picker
area-scroll         | 1600x900           | ext                    | the same in the scrolling capture's picker
area-shots          | 1600x900           | ext manual             | each area picker idle, dragging, selected, a handle hovered (pictures)
area-shots-dark     | 1600x900           | ext manual             | the same in the dark appearance
modes-keys          | 1600x900           | ext                    | each mode's key set from the CLI and from Settings; keys GNOME holds stay unbound
tools               | 1600x900           | -                      | the editor's extra tools on a test picture: picker, ruler, spotlight, crop, magnifier; pin refused
rec-shell           | 1600x900           | ext                    | an MP4 through the extension: no dialog, size, rate, clicks, sound, the thumbnail, one at a time
rec-pick            | 1600x900           | ext                    | the recording picker and the floating control
rec-gif             | 1600x900           | ext                    | a GIF recording, and pause
rec-trim            | 1600x900           | ext                    | the trim window exports a shorter file
rec-settings        | 1600x900           | -                      | Settings' Recording view
rec-portal          | 1600x900           | -                      | recording through the ScreenCast portal: one consent, then none
perms               | 1600x900           | nothumb                | shotlet permissions after a portal grant, reset --dry-run and reset
perms-shell         | 1600x900           | nothumb ext            | captures through the extension store no permission
gnome-install       | 1600x900           | nothumb                | gnome-integration install loads at the next login and finishes the setup
rec-bench           | 1600x900           | ext manual             | CPU, memory and size of 10 s recordings per encoder (a report)
EOF_TABLE
}

# scenario_row NAME: its row in S_MONS, S_FLAGS, S_DESC; false for no
# such scenario
scenario_row() {
    local n m f d
    while IFS='|' read -r n m f d; do
        [ "$(_trim "$n")" = "$1" ] || continue
        S_MONS=$(_trim "$m") S_FLAGS=$(_trim "$f") S_DESC=$(_trim "$d")
        return 0
    done < <(scenario_table)
    return 1
}
# scenario_flag FLAG: the row scenario_row read has it
scenario_flag() { case " $S_FLAGS " in *" $1 "*) return 0 ;; esac; return 1; }
# scenario_value KEY: the value of its KEY=VALUE flag (empty without one)
scenario_value() {
    local f
    for f in $S_FLAGS; do case $f in "$1="*) echo "${f#*=}"; return ;; esac; done
}
# default_scenarios: the ones a plain run runs, in table order
default_scenarios() {
    local n m f rest
    while IFS='|' read -r n m f rest; do
        case " $(_trim "$f") " in *" manual "*) ;; *) _trim "$n"; echo ;; esac
    done < <(scenario_table)
}
list_scenarios() {
    local n m f d
    printf '%-20s %-19s %-19s %s\n' SCENARIO MONITORS FLAGS "WHAT IT CHECKS"
    while IFS='|' read -r n m f d; do
        printf '%-20s %-19s %-19s %s\n' "$(_trim "$n")" "$(_trim "$m")" "$(_trim "$f")" "$(_trim "$d")"
    done < <(scenario_table)
}
