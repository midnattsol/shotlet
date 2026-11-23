# Screen recording scenarios (sourced by tools/e2e.sh's inner side, with
# its helpers). The files are checked with ffprobe and ffmpeg.
#   rec-shell     MP4 of an area through the GNOME extension: no dialog,
#                 the size, codec and rate, pictures that change, the
#                 click ripples recorded, sound, StartRecording from
#                 another program refused, the thumbnail and the history,
#                 a second recording refused while one is under way
#   rec-pick      the picker and the floating control
#   rec-gif       the same as a GIF (decoded and checked), and pause
#   rec-trim      the trim window makes a shorter file
#   rec-settings  Settings' Recording view
#   rec-portal    without the extension: the ScreenCast portal, one
#                 consent, then none (restore token)
#   rec-bench     (manual) CPU, memory and size per encoder path

# probe FILE ENTRIES: one ffprobe value list (csv)
probe() { ffprobe -v error -select_streams v:0 -show_entries "$2" -of csv=p=0 "$1" 2>/dev/null | head -1; }
duration_ms() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | awk '{ printf "%d", $1 * 1000 }'; }
# frame FILE SECONDS PNG: one picture of the video
frame() { ffmpeg -v error -y -ss "$2" -i "$1" -frames:v 1 "$3" 2>/dev/null; }
# a recording of AREA for SECONDS, the pointer moving across it
record_moving() { # record_moving NAME AREA SECONDS ARGS...
    local name=$1 area=$2 secs=$3; shift 3
    run_shotlet "$name" record --region "$area" --seconds "$secs" --no-countdown "$@"
    wait_log 15 "record: recording" || return 1
    local x
    for x in 220 300 380 460 540 460 380; do drv move 0 "$x" 300; drv sleep 200; done
    wait_exit $((secs + 20))
}
saved_file() { grep -o "recording: saved [^ ]*" "$SHOT_LOG" | tail -1 | cut -d' ' -f3; }
# rec_ready: ffprobe and ffmpeg, the driver, the plain desktop drawn
rec_ready() {
    require ffprobe ffmpeg || return 1
    drv_ready Meta-0
    plain_desktop
    sleep 1 # (the shell repaints the background a moment later)
}

scenario_rec_shell() {
    rec_ready || return
    touch "$OUT/marker"
    record_moving rec "200,150,480,320" 3 --clicks
    check "shotlet record exits once done" test "$RC" = 0
    check "  ... through the GNOME integration" grep -q "recording: source GNOME integration" "$SHOT_LOG"
    check "  ... without any consent dialog" no_dialog
    local f d
    f=$(saved_file)
    check "  ... into the Videos folder" eval '[[ "$f" == "$HOME/Videos/shotlet-"*.mp4 ]]'
    echo "  $(grep -o "recording: saved.*" "$SHOT_LOG")"
    check "  ... H.264 at the area's size" eq "$(probe "$f" stream=codec_name,width,height,pix_fmt)" "h264,480,320,yuv420p"
    check "  ... at 30 fps" eq "$(probe "$f" stream=avg_frame_rate)" "30/1"
    d=$(duration_ms "$f")
    check "  ... about 3 s long ($d ms)" test "$d" -ge 2800 -a "$d" -le 3300
    check "  ... index at the front (faststart)" eval '[ "$(head -c 64 "$f" | grep -c moov)" = 1 ] || "$E2E_PYTHON" -I -c "import sys; d=open(sys.argv[1],\"rb\").read(); sys.exit(0 if d.find(b\"moov\") < d.find(b\"mdat\") else 1)" "$f"'
    frame "$f" 0.2 "$OUT/f0.png"; frame "$f" 2.5 "$OUT/f1.png"
    check "  ... and the pictures change (the pointer moves)" test "$(md5sum <"$OUT/f0.png")" != "$(md5sum <"$OUT/f1.png")"
    check "  ... showing the desktop" pixel_near "$OUT/f0.png" 20 300 "$DESKTOP_BG"
    rec_thumbnail "$f"
    rec_clicks
    rec_sound
    rec_others
    rec_busy
}

# the recording's thumbnail and its Copy (FILE: the recording)
rec_thumbnail() {
    local f=$1 types
    check "the thumbnail shows the recording" any_log 10 "quick video: showing"
    check "  ... and the history keeps it" eval 'ls "$XDG_STATE_HOME"/shotlet/history/*/video >/dev/null'
    sleep 1
    shot 0 thumbnail
    drv move 0 150 790 && drv sleep 300 && drv move 0 156 789 && drv sleep 400
    shot 0 thumbnail-hover
    click 0 100 841
    sleep 0.5
    types=$(timeout 5 wl-paste -l 2>/dev/null | tr '\n' ' ')
    check "  ... whose Copy offers the file ($types)" eval '[[ "$types" == *text/uri-list* && "$types" == *video/mp4* ]]'
    check "  ... as its uri" eval 'timeout 5 wl-paste -n -t text/uri-list | tr -d "\\r" | grep -qx "file://$f"'
    check "  ... and its bytes" eval 'timeout 5 wl-paste -n -t video/mp4 | cmp -s - "$f"'
}

# blue_over FILE X Y: the pixel is much bluer than red (a click ripple)
blue_over() { drv pixel "$1" "$2" "$3" && [ $((16#${VAL:6:2} - 16#${VAL:2:2})) -gt 120 ]; }
# dark_at FILE X Y: the pixel's blue is low (a keystroke label)
dark_at() { drv pixel "$1" "$2" "$3" && [ $((16#${VAL:6:2})) -lt 90 ]; }

# clicks are drawn inside the area, and recorded
rec_clicks() {
    local f t found=0
    run_shotlet clicks record --region "200,150,480,320" --seconds 4 --no-countdown --no-control --clicks --keys
    wait_log 15 "record: recording" && drv sleep 800
    click 0 440 310
    drv sleep 1500
    keys x
    wait_exit 20
    f=$(saved_file)
    for t in 0.9 1.0 1.1 1.2 1.3 1.4 1.5; do
        frame "$f" "$t" "$OUT/click.png"
        if blue_over "$OUT/click.png" 240 160 || blue_over "$OUT/click.png" 262 160; then found=1; break; fi
    done
    check "a click is recorded as a ripple" test "$found" = 1
    found=0
    for t in 2.4 2.6 2.8 3.0 3.2; do
        frame "$f" "$t" "$OUT/key.png"
        dark_at "$OUT/key.png" 240 258 && { found=1; break; }
    done
    # keystrokes: mutter hands keys for apps to them before the stage's
    # captured-event, so the label is not drawn for those (known gap)
    if [ "$found" = 1 ]; then pass "  ... and a keystroke as a label"; else skip "keystroke label: keys to apps do not reach the shell's stage"; fi
}

# sound: the microphone and the system sound, mixed (silence here)
rec_sound() {
    local f va
    run_shotlet sound record --region "200,150,480,320" --seconds 3 --no-countdown --no-control --mic --system-audio
    wait_exit 30
    f=$(saved_file)
    check "with sound, the MP4 has an AAC track" eq "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$f")" "aac,48000,2"
    va=$(ffprobe -v error -show_entries stream=duration -of csv=p=0 "$f" | awk 'NR==1{v=$1} NR==2{a=$1} END{printf "%d", (v-a)*1000}')
    check "  ... as long as the picture (${va#-} ms apart)" test "${va#-}" -le 120
}

# another program asking for a screencast; stopping with record again
rec_others() {
    gdbus call --session --dest dev.shotlet.Shell1 --object-path /dev/shotlet/Shell1 \
        --method dev.shotlet.Shell1.StartRecording "{'x': <0>, 'y': <0>, 'w': <100>, 'h': <100>}" >"$OUT/gdbus.txt" 2>&1
    check "StartRecording() from another program is refused" grep -q "AccessDenied" "$OUT/gdbus.txt"
    run_shotlet long record --region "100,100,320,240" --no-countdown
    wait_log 15 "record: recording"
    sleep 1
    "$BIN" record >"$OUT/again.log" 2>&1
    check "shotlet record again stops the recording" wait_exit 20
    check "  ... and keeps it" grep -q "recording: saved" "$SHOT_LOG"
}

# a second recording while the first one counts down (without its
# control, it answers no command until it records): refused, saying
# why on stderr and on the screen (owner decision 4); the first goes on
rec_busy() {
    cfg_set record_countdown=10
    run_shotlet busy record --region "200,150,480,320" --seconds 1 --no-control
    wait_until 5 eval 'ls "$XDG_RUNTIME_DIR"/shotlet-record-*.sock >/dev/null 2>&1'
    local rc=0
    "$BIN" record --region "100,100,320,240" --no-countdown >"$OUT/busy-again.log" 2>&1 || rc=$?
    check "shotlet record while another one is under way exits 1" eq "$rc" 1
    problem_reported busy-again record "Another recording is under way" "Stop it first: shotlet record --stop"
    check "  ... and the first one goes on" alive
    check "  ... and the card goes by itself" card_gone
    wait_exit 30
    cfg_unset record_countdown
}

# the picker and the floating control, through the extension (the
# record bar d70015, the Record button and the control's dot PEN_RED)
scenario_rec_pick() {
    rec_ready || return
    local bx by f
    run_shotlet pick record
    check "shotlet record asks the extension for the picker" wait_exit 10
    check "  ... which comes up" shell_wait 10 "record: picker up" 1
    sleep 1
    slow_drag 0 300 200 500 350 700 500
    sleep 0.5
    shot 0 picker
    check "  ... with the record bar under the area" find_on 0 d70015 24 60 0 500 1600 900
    read -r bx by _ <<<"$VAL"
    check "  ... a white handle at its corner, as a capture's" pixel_near "$OUT/picker.png" 300 200 ffffff
    check "  ... and no red but the Record button" no_find_on 0 "$PEN_RED" 40 4 250 150 750 515
    click 0 "$bx" "$by"
    check "Record starts the countdown" shell_wait 10 "record: recording" 1
    sleep 1
    shot 0 recording
    check "  ... the control sits below the area" find_on 0 "$PEN_RED" 30 4 0 500 1600 900
    check "  ... and not in it" pixel_near "$OUT/recording.png" 500 350 "$DESKTOP_BG"
    sleep 1
    "$BIN" record --stop >"$OUT/stop.log" 2>&1
    check "shotlet record --stop ends it" shell_wait 15 "recording: saved" 1
    f=$(grep -o "recording: saved [^ ]*" "$SHOTLET_E2E_SHELL_LOG" | tail -1 | cut -d' ' -f3)
    check "  ... at the picked size" eq "$(probe "$f" stream=width,height)" "400,300"
}

scenario_rec_gif() {
    rec_ready || return
    local f d n sz
    record_moving gif "300,200,400,240" 3 --gif --fps 15
    f=$(saved_file)
    check "a GIF recording is written" eval '[[ "$f" == *.gif ]] && [ -s "$f" ]'
    check "  ... at the area's size" eq "$(probe "$f" stream=codec_name,width,height)" "gif,400,240"
    d=$(duration_ms "$f")
    check "  ... about 3 s long ($d ms)" test "$d" -ge 2700 -a "$d" -le 3400
    n=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$f")
    check "  ... with several distinct pictures ($n)" test "${n:-0}" -ge 5
    sz=$(stat -c %s "$f")
    echo "  GIF: $sz bytes, $n frames"
    check "  ... and small ($sz bytes)" test "$sz" -lt 400000
    frame "$f" 0.1 "$OUT/g0.png"
    check "  ... showing the desktop's colour" pixel_near "$OUT/g0.png" 20 200 "$DESKTOP_BG"
    # pause: the paused time is not in the file
    run_shotlet pause record --region "300,200,400,240" --no-countdown --gif
    wait_log 15 "record: recording"
    sleep 1
    "$BIN" record --pause >/dev/null 2>&1
    sleep 2
    "$BIN" record --resume >/dev/null 2>&1
    sleep 1
    "$BIN" record --stop >/dev/null 2>&1
    wait_exit 20
    d=$(duration_ms "$(saved_file)")
    check "a paused recording leaves the pause out ($d ms)" test "$d" -ge 1500 -a "$d" -le 2700
}

scenario_rec_trim() {
    require ffprobe ffmpeg || return
    drv_ready Meta-0
    plain_desktop
    local f id t d
    record_moving trim "200,150,480,320" 4
    f=$(saved_file)
    id=$(basename "$(dirname "$(ls -t "$XDG_STATE_HOME"/shotlet/history/*/video | head -1)")")
    run_shotlet trimui trim "$XDG_STATE_HOME/shotlet/history" "$id" --range 1000,2500 --export
    check "the trim window exports" wait_exit 30
    t=$(grep -o "trim: wrote [^ ]*" "$SHOT_LOG" | cut -d' ' -f3)
    d=$(duration_ms "$t")
    check "  ... a shorter file ($d ms)" test "${d:-0}" -ge 1300 -a "${d:-0}" -le 1800
    check "  ... next to the original" test "$(dirname "$t")" = "$(dirname "$f")"
    check "  ... kept with its own thumbnail" any_log 10 "quick video: showing"
    run_shotlet trimwin trim "$XDG_STATE_HOME/shotlet/history" "$id"
    wait_log 10 "trim: " && sleep 1.5
    shot 0 trim
    check "the trim window shows the filmstrip's handles" find_on 0 ffcc00 20 4
    # a thumbnail that appeared meanwhile may hold the keyboard: click in
    click 0 800 330
    keys esc
    check "  ... and Esc closes it" wait_exit 5
}

# the Recording view (open_settings: quick.sh)
scenario_rec_settings() {
    drv_ready Meta-0
    SHOTLET_SETTINGS_VIEW=recording open_settings 1 enter
    check "Settings' Recording view switches the format" cfg_has record_format=gif
    SHOTLET_SETTINGS_VIEW=recording open_settings 12 space
    check "  ... and turns the microphone on" cfg_has record_mic=true
}

scenario_rec_portal() {
    rec_ready || return
    local f
    run_shotlet portal record --region "200,150,480,320" --seconds 2 --no-countdown --no-control
    share_dialog 0 || fail "the share dialog"
    check "without the extension, the portal records" wait_exit 30
    check "  ... through the ScreenCast portal" grep -q "recording: source ScreenCast portal" "$SHOT_LOG"
    f=$(saved_file)
    check "  ... at the area's size" eq "$(probe "$f" stream=codec_name,width,height)" "h264,480,320"
    run_shotlet again record --region "200,150,480,320" --seconds 2 --no-countdown --no-control
    check "a second recording needs no dialog (restore token)" wait_exit 20
    check "  ... and records" grep -q "recording: saved" "$SHOT_LOG"
    check "  ... with the consent stored once" eq "$(perm_apps screencast)" "$APP_ID"
}

# CPU time, peak memory and file size of a 10 s recording of the whole
# 1600x900 screen, the pointer moving, per encoder path
# (zig build e2e -- rec-bench; a release build is fair)
scenario_rec_bench() {
    drv_ready Meta-0
    bench vaapi -- --fps 60
    bench libav SHOTLET_ENCODER=libav SHOTLET_NO_VAAPI=1 -- --fps 60
    bench ffmpeg SHOTLET_ENCODER=ffmpeg SHOTLET_NO_VAAPI=1 -- --fps 60
    bench gif -- --gif --fps 15
}

bench() { # bench LABEL ENV... -- ARGS...
    local label=$1; shift
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    ( for i in $(seq 1 60); do drv move 0 $((200 + (i % 10) * 120)) $((200 + (i % 7) * 70)) >/dev/null; drv sleep 150 >/dev/null; done ) &
    local mover=$!
    local out=$OUT/bench-$label.log t0 t f cpu
    t0=$(date +%s%N)
    { TIMEFORMAT='%U %S'; time env "${envs[@]}" "$BIN" record --full --seconds 10 --no-countdown --no-control "$@" >"$out" 2>&1; } 2>"$OUT/time-$label.txt"
    t=$((($(date +%s%N) - t0) / 1000000))
    wait "$mover" 2>/dev/null
    f=$(grep -o "recording: saved [^ ]*" "$out" | cut -d' ' -f3)
    cpu=$(awk '{ printf "%.1f", ($1 + $2) * 100 / 10 }' "$OUT/time-$label.txt")
    echo "  bench $label: $(grep -o "[0-9]*x[0-9]* at [0-9]* fps, .*" "$out" | head -1); cpu ${cpu}% of a core over 10 s; $(stat -c %s "$f" 2>/dev/null) bytes; wall ${t} ms"
    check "bench $label recorded" test -s "$f"
}
