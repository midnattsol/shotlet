# Contributing

## Architecture and contributing

Shotlet is a portable core (the editor, rendering and text, encoders,
OCR, history, the floating windows' logic) over a platform backend:
everything that speaks Wayland, D-Bus, the portals, PipeWire, GNOME
Shell, KWin or wlroots lives in `src/platform/linux/`, and the core
reaches it only through `src/platform/api.zig`. `docs/PLATFORM.md` maps
the seams, how a backend is chosen and what a Windows or macOS port
implements.

Each job has one place; use it rather than writing another:

| Job | Where |
| --- | --- |
| Points, rectangles, monitors; logical layout ↔ capture pixels | `src/geom.zig` (core and backend alike; a surface's own scale: `src/ui/scale.zig`) |
| `file://` URIs, both ways | `src/uri.zig` |
| Optional native libraries, opened at run time | `src/optlib.zig`, over `api.libs` |
| Mutex and event on the platform's futex | `src/sync.zig` |
| How a capture leaves: save, copy, `copy_on_save`, the notification, Show in Files | `src/app/deliver.zig` (file names: `src/app/filename.zig`) |
| Starting another shotlet subcommand, detached | `src/app/relaunch.zig` (names from `src/cli/commands.zig`) |
| Talking to a running shotlet (thumbnail, pins, recording) | `src/app/ipc.zig` |
| A history entry's `meta` and `video` files | `src/app/kvfile.zig` |
| Shotlet's own state files and one-time flags | `src/app/statefile.zig`, `src/app/stateflag.zig` |
| Telling the person about a problem: card, stderr, log | `src/app/report.zig` (the desktop integration refusing this copy of Shotlet: `src/app/refused.zig`) |
| A command's output and exit status | `src/cli/out.zig` |
| Colours and metrics of every surface, light and dark | `src/ui/theme.zig` (buttons: `src/ui/barkit.zig`) |
| Picking an area: drag, move, resize, click, arrows | `src/ui/areasel.zig` (the editor through `src/ui/editor/area.zig`) |
| A picker over the frozen desktop (surfaces, dim, fade, the area's chrome) | `src/ui/freeze_pick.zig` (the recording and scrolling capture pickers) |
| Opening the editor: the capture as the first frame, the caches made off the event loop; when each step happened | `src/ui/editor/opening.zig` (the steps: `src/app/shot/timeline.zig`) |
| A capture the GNOME integration hands over: its frozen frame in the shell, waiting for its pieces, decoding each into place | `gnome-extension/shotlet@midnattsol.github.io/freeze.js`; `src/platform/linux/gnome/shellcap.zig`, `shellcap_place.zig` (loaded while Shotlet starts: `src/app/shot/handed.zig`) |
| The `SHOTLET_*` switches | `src/platform/api/switches.zig` |
| Unit-test helpers (temporary dirs and `$HOME`, images, fonts) | `src/testutil.zig` |

Unit tests are reached from one root: `src/main.zig`'s `test {}` names
each folder's root (`src/app/tests.zig`, `src/ui/tests.zig`...), which
names the files of its folder that have tests; the comment there has
the rule. A new file with tests goes into its folder's root.

`zig build test` also runs the guards (`tools/sources.sh` holds the
limits and the files they check):

| Step | Fails when |
| --- | --- |
| `check-size` | a source file grows past 600 lines (`tools/size-allowlist.txt` may only shrink) |
| `check-layers` | a file outside `src/platform/linux` imports it, `std.os.linux` or the raw backend, or names Wayland, D-Bus, keysyms, evdev codes or GTK accelerators in code |
| `check-tests` | a file's tests are not reached from the test root, or a `test {}` block sits outside `src/main.zig` |
| `check-portable` | the core does not compile for Windows and macOS against the stub backend |

Keep functions within 60 lines (`zig build long-fns -- 60` lists the
longer ones) and the tree formatted (`zig fmt --check src build.zig
tools`). CI (`.github/workflows/ci.yml`) runs the formatting check, the
guards, `zig build test` and the builds on every pull request.

The version comes from git (`tools/version.zig`): a build past the last
tag calls itself the next patch's prerelease (`0.1.1-dev.12+abc1234`).
A release is a tag: pushing `v0.1.0` builds it with `-Dversion=v0.1.0`,
which may not be older than `build.zig.zon`'s version; raise that one
only to plan a minor or major release.

## Tests

```sh
zig build test --summary all             # unit tests and the guards
zig build e2e                            # end-to-end, private headless GNOME
zig build e2e -- quick pin               # only those scenarios
zig build e2e-container                  # sway, labwc and KWin, in containers
zig build e2e-container -- labwc         # one compositor
zig build e2e-container -- sway:pin      # one scenario on one compositor
tools/e2e.sh --list                      # the GNOME scenarios and what each checks
tools/container/run.sh --list            # the container scenarios
```

Both suites print PASS, FAIL or SKIP per check and a summary, and exit
1 when a check failed, 2 for an unknown scenario. Each scenario is a
`scenario_NAME` function in `tools/e2e/scenarios/*.sh` or
`tools/container/scenarios/*.sh`, with a row in that suite's
`table.sh` (monitors, flags, what it checks: what `--list` prints).
`rec-bench` (the encoders' CPU, memory and size) and `perf-owner` (on
two 4K monitors at 2 and 1.5: the time from the key to the frozen
screen, to the editor's first frame and to a ready editor, then each
surface's frame times; build it with `-Doptimize=ReleaseSafe` for its
bounds) only run when named. Every window in the GNOME suite logs its frame times as it closes
(`SHOTLET_LOOP_STATS`); `modes-scroll-mixed` fails when the scrolling
capture's picker or control kept the compositor's pings waiting.
`zig build e2e-driver` builds the binaries the scripts need when run
directly. CI runs both suites nightly and on demand
(`.github/workflows/e2e.yml`, `e2e-container.yml`), never on pull
requests.

**GNOME.** `tools/e2e.sh` runs the real binary against real portal
dialogs, PipeWire and the clipboard, each scenario in a private,
invisible GNOME session (`tools/e2e/session.sh`: its own `HOME`,
session bus, PipeWire and `gnome-shell --headless` with virtual
monitors; with the Shotlet extension where the table says `ext`).
Nothing reaches the desktop you are logged into: the drivers refuse
to start outside the sandbox. `shotlet-drive` (`tools/e2e/drive.zig`)
types and points through a Mutter RemoteDesktop session and screenshots
each monitor through ScreenCast; `tools/e2e/target.py` (GTK 4) and
`shotlet-droptarget` play the other apps. The suite skips without
`gnome-shell`, `dbus-run-session`, PipeWire and WirePlumber, `gdbus`,
`wl-clipboard`, `xdg-desktop-portal` and `xdg-desktop-portal-gnome`;
checks skip without Python's GTK 4 bindings (scenarios with another
app: thumbnail, pins, modes, scrolling, tools), `ffmpeg`/`ffprobe`
(`rec-*`), `ibus-hangul` (`ime`) or `dbus-monitor` (the "Saved to…"
notifications). What CI installs on Ubuntu:

```sh
apt install gnome-shell mutter xdg-desktop-portal xdg-desktop-portal-gnome \
  pipewire wireplumber libpipewire-0.3-0 libxkbcommon0 wl-clipboard \
  ibus ibus-hangul dbus-daemon dbus-bin libglib2.0-bin python3 python3-gi \
  gir1.2-gtk-4.0 ffmpeg mesa-utils libgl1-mesa-dri fonts-noto-core fonts-noto-cjk
```

**Containers.** `tools/container/run.sh` covers what GNOME cannot: the
layer-shell thumbnail, pins and history on wlroots (sway, labwc) and
KWin, direct capture with no dialog (wlr-screencopy; KWin's ScreenShot2
authorized by the installed desktop entry, never by KWin's
permission-check overrides), mixed scales and rotated outputs, the
wlroots and KDE portals, and Tesseract. Each scenario runs in a
throwaway Debian trixie container (`--rm`, no network) with its own
session bus, PipeWire and headless compositor, and Shotlet installed by
`install.sh`; nothing reaches the host's display, bus or PipeWire.
Docker or Podman is needed (the suite skips without). The image
(`shotlet-e2e:trixie`, about 1.5 GB, its packages in
`tools/container/Containerfile`) is built on first use; `docker rmi
shotlet-e2e:trixie` removes it. `shotlet-wldrive`
(`tools/container/wldrive.zig`) is the input driver: wlroots' virtual
pointer and keyboard plus screencopy, or KWin's fake input and
ScreenShot2. A GPU render node (`/dev/dri/renderD*`, never a display
node) is passed in when the host has one; `xdg-desktop-portal-wlr` and
KWin need it (the table's `gpu`), so without one those skip and the
rest runs on software rendering. Debian trixie's wlroots offers only
wlr-screencopy; `Containerfile.sid` is for the ext-image-copy-capture
path: `SHOTLET_E2E_IMAGE=shotlet-e2e:sid tools/container/run.sh
sway:capture sway:multimon sway:rotated`.

The suites' variables (the runners set the rest themselves):

| Variable | Effect |
| --- | --- |
| `E2E_OUT=dir` | keep the run's logs and screenshots there (both suites) |
| `E2E_MONITORS="WxH ..."` | containers: these outputs for every scenario |
| `SHOTLET_E2E_KEEP=1` | GNOME: keep the private `HOME` (its path is printed) |
| `SHOTLET_E2E_WLDEBUG=1` | GNOME: gnome-shell's `WAYLAND_DEBUG` |
| `SHOTLET_E2E_TARGET_DEBUG=1` | the GTK test app logs its Wayland traffic |
| `SHOTLET_E2E_MONITORS`, `_LAYOUT`, `_IBUS`, `_APPS`, `_EXTENSIONS` | `tools/e2e/session.sh` run by hand: its monitors, XKB layout, IBus engine, desktop files and extensions (`e2e.sh` sets them from the table) |
| `SHOTLET_E2E_ENGINE=docker\|podman` | containers: the engine (default: whichever works) |
| `SHOTLET_E2E_GPU=0` | containers: never pass a render node |
| `SHOTLET_E2E_IMAGE=name:TAG` | containers: the image (built from `Containerfile.TAG` when missing) |
| `SHOTLET_E2E_PROBE='code'`, `SHOTLET_E2E_PROBE0` | containers: shell code the `probe` scenario runs (after, before the driver starts) |
| `SHOTLET_E2E_KWIN_LOG=rules` | containers: KWin's `QT_LOGGING_RULES` |

`tools/e2e/session.sh` also runs any one command in such a session, e.g.
`SHOTLET_E2E_MONITORS="1600x900 1280x720" tools/e2e/session.sh
zig-out/bin/shotlet shot --from IMG.png`.

### Log lines

Shotlet logs to stderr as `LEVEL: subsystem: message`, for example
`info: quick access: showing`. Every file logs through its subsystem's
scoped logger (`std.log.scoped(.quick_access)`); `src/logfmt.zig` adds the
subsystem name and holds the level rules (err: the action failed, warn:
degraded, info: the flow, debug: details).

### Debugging and test switches

Every `SHOTLET_*` variable the program reads, read once at startup
(`src/platform/api/switches.zig` holds the same table). A switch that
turns something off is on when set at all (`=1`); the others take a value.

| Variable | Effect | Read by |
| --- | --- | --- |
| `SHOTLET_NO_DIRECT` | never capture straight from the compositor (ext-image-copy / wlr-screencopy / KWin): the portal or the GNOME integration only | `platform/linux/capture*` |
| `SHOTLET_NO_LAYER_SHELL` | ignore wlr-layer-shell: floating windows become plain toplevels | `platform/linux/window/registry.zig` |
| `SHOTLET_NO_FRACTIONAL` | ignore wp-fractional-scale: integer buffer scales only | `platform/linux/window/registry.zig` |
| `SHOTLET_NO_CURSOR_SHAPE` | ignore cursor-shape-v1: Shotlet draws its own cursors | `platform/linux/window/registry.zig` |
| `SHOTLET_NO_SHELL_RECORD` | record through the ScreenCast portal even when the GNOME integration could | `platform/linux/record/source.zig` |
| `SHOTLET_NO_LIBAV` | do not load the FFmpeg libraries (MP4s go through the `ffmpeg` program) | `encode/av.zig` |
| `SHOTLET_NO_VAAPI` | no VA-API hardware encoding through the `ffmpeg` program | `encode/ffmpeg_proc.zig` |
| `SHOTLET_NO_OCR` | do not load Tesseract: no text recognition or search | `ocr/tesseract.zig` |
| `SHOTLET_ENCODER=libav\|ffmpeg` | force one MP4 encoder path | `encode/sink.zig` |
| `SHOTLET_OCR_LANG=eng+spa` | Tesseract's languages (default: the desktop's language plus English) | `ocr/tesseract.zig` |
| `SHOTLET_DUMP_FRAME=/path/prefix` | each window surface's last frame goes to `<prefix>-<n>.png` when it closes | `platform/linux/window/dump.zig` |
| `SHOTLET_LOOP_STATS=1` | as each window closes, log its frame times (p50, p95, max) and the longest time the event loop stayed away from the compositor (unanswered pings) | `platform/linux/window/loopstats.zig` |
| `SHOTLET_EDITOR_DUMP=/path/prefix` | the editor writes every pane's last frame and the export at exit | `ui/editor/session.zig` |
| `SHOTLET_EDITOR_SCRIPT="key ...; quit"` | scripted editor input (`ui/script_input.zig`); turns animations off | `ui/editor/session.zig` |
| `SHOTLET_SETTINGS_FOCUS=n` | Settings starts with its n-th control focused | `ui/settings/app.zig` |
| `SHOTLET_SETTINGS_VIEW=general\|editor\|shortcuts\|recording` | the view Settings starts on | `ui/settings/app.zig` |

One more, read by a unit test only: `SHOTLET_LIVE_WINDOW_TEST=1` (with
`SHOTLET_LIVE_WAIT_MS`) runs the window test against a live compositor;
run it inside `tools/e2e/session.sh`, never on your desktop. The test
suites' own variables are under [Tests](#tests).
