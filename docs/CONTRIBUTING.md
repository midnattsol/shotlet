# Contributing

## Start

You need Zig 0.17.

```sh
zig build run -- shot      # build and run
zig build test             # unit tests and the guards; silent when all is well
zig fmt src tools build.zig
```

A pull request needs these to pass; CI runs them, and the release builds.

## How the code is laid out

The editor, rendering, encoders, history and the rest are portable.
Everything that speaks Wayland, D-Bus, portals, PipeWire or a particular
desktop is in `src/platform/linux/`, and the rest reaches it only through
`src/platform/api.zig`. [PLATFORM.md](PLATFORM.md) has the details.

| Folder | What is in it |
| --- | --- |
| `src/cli` | the commands and their output |
| `src/app` | what each command does: capture, deliver, history, settings |
| `src/ui` | every window: editor, pickers, recording, Settings |
| `src/gfx` | drawing, text, images |
| `src/encode`, `src/record` | video and recording |
| `src/ocr`, `src/redact` | reading text, hiding sensitive data |
| `src/platform` | the desktop |
| `gnome-extension` | the GNOME Shell extension |

The binary and the extension are one version: install them together.

## One place for each job

Before writing a helper, look here:

| Job | Where |
| --- | --- |
| Points, rectangles, monitors | `src/geom.zig` |
| Scaling on a surface | `src/ui/scale.zig` |
| Colours and sizes, buttons | `src/ui/theme.zig`, `src/ui/barkit.zig` |
| Picking an area | `src/ui/areasel.zig` |
| A picker over the frozen desktop | `src/ui/freeze_pick.zig` |
| Opening the editor | `src/ui/editor/opening.zig` |
| A capture from the GNOME extension | `freeze.js` in the extension, `src/platform/linux/gnome/shellcap.zig` |
| Save, copy, notify | `src/app/deliver.zig` |
| Tell the person about a problem | `src/app/report.zig` |
| A command's output and exit status | `src/cli/out.zig` |
| State files and one-time flags | `src/app/statefile.zig`, `src/app/stateflag.zig` |
| Files of a history entry | `src/app/kvfile.zig` |
| Talk to a running Shotlet | `src/app/ipc.zig` |
| Start another Shotlet command | `src/app/relaunch.zig` |
| Work side by side | `src/parallel.zig` |
| Mutex and event | `src/sync.zig` |
| Optional libraries | `src/optlib.zig` |
| `file://` URIs | `src/uri.zig` |
| Test helpers | `src/testutil.zig` |

## Rules the build checks

| Step | Rule |
| --- | --- |
| `check-size` | no source file over 600 lines |
| `check-layers` | only `src/platform/linux` touches the desktop |
| `check-tests` | every file's tests are reached (add yours to its folder's root: see the end of `src/main.zig`) |
| `check-portable` | the core compiles for Windows and macOS |

Not checked, but please keep functions under 60 lines
(`zig build long-fns` lists the longer ones).

## End-to-end tests

They run the real program on private, invisible desktops; yours is never
touched.

```sh
zig build e2e                        # GNOME, everything
zig build e2e -- quick pin           # only these
zig build e2e-container              # sway, labwc and KWin (Docker or Podman)
zig build e2e-container -- sway:pin  # only this
tools/e2e.sh --list                  # what there is (also tools/container/run.sh)
```

- Use a debug build, the default: some checks read debug log lines that
  `-Doptimize=safe` leaves out.
- Do not build or edit the extension while they run.
- `E2E_OUT=dir` keeps the logs and screenshots.
- Anything missing on your system is skipped, and said so. The packages are
  in [e2e.yml](../.github/workflows/e2e.yml); the first container run builds
  an image of about 1.5 GB.
- CI runs them every night and on demand, not on pull requests.

A scenario is a `scenario_NAME` function in `tools/e2e/scenarios/` or
`tools/container/scenarios/`, and a row in that suite's `table.sh`. Other
options are at the top of `tools/e2e.sh`, `tools/e2e/session.sh` and
`tools/container/run.sh`.

## Debugging

Log lines go to stderr as `LEVEL: subsystem: message` (`src/logfmt.zig`).

`SHOTLET_*` variables turn parts off or show more. The whole list is in
`src/platform/api/switches.zig`; the handiest:

| Variable | Effect |
| --- | --- |
| `SHOTLET_NO_DIRECT=1` | capture through the portal or the GNOME extension only |
| `SHOTLET_NO_LAYER_SHELL=1` | floating windows become ordinary ones |
| `SHOTLET_DUMP_FRAME=/path/prefix` | save each window's last frame as a PNG |
| `SHOTLET_LOOP_STATS=1` | log each window's frame times |

## Releases

Pushing a tag such as `v0.1.0` builds and publishes that version. Other
builds take theirs from git (`tools/version.zig`).
