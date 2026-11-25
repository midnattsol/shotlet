# Guide

- [Capture](#capture) · [After a capture](#after-a-capture) ·
  [Editor](#editor) · [Recording](#recording)
- [GNOME](#gnome) · [Permissions](#permissions) · [Settings](#settings) ·
  [Optional programs](#optional-programs)

## Capture

| Mode | Command | GNOME key |
| --- | --- | --- |
| Area | `shotlet` | `Print` |
| Window | `shotlet window` | `Super+Print` |
| Screen under the pointer | `shotlet fullscreen` | `Ctrl+Print` |
| All screens | `shotlet screens` | `Ctrl+Shift+Print` |
| Previous area | `shotlet previous` | `Shift+Super+Print` |
| Scrolling page | `shotlet scroll` | `Ctrl+Super+Print` |
| Self-timer | `shotlet timer [3\|5\|10]` | `Ctrl+Shift+Super+Print` |
| Recording | `shotlet record` | `Shift+Super+R` |
| Text (OCR) | `shotlet text` | |

All but the timer, recording and text take `--delay S`. The GNOME keys come with the
[extension](#gnome) and can be changed in Settings › Shortcuts; on other
desktops, bind the commands yourself.

**Picking an area.** Drag it out. `Shift` makes a square, `Ctrl` draws from the
centre, `Space` moves it while you draw. A click takes the window under the
pointer (GNOME with the extension, KDE) or the whole monitor. Arrows move it a
pixel (`Shift`: 10), `Ctrl`+arrows resize it. `Enter` confirms, `Esc` leaves.

**Switching mode.** Before you select, the bar at the bottom changes mode: `G`
area, `W` window, `D` screen, `J` scrolling, `O` text, `Q` record, `H` timer.

**Magnifier.** Hold `Ctrl` while you pick an area. `Alt` shows the colour under
the pointer, `C` copies it, the wheel zooms.

**Scrolling.** Pick the part that scrolls and press Start. Shotlet scrolls,
stitches, and opens the result at the end of the page. If it stops short it
says why: Continue (`C`), Finish (`Enter`) or Cancel (`Esc`). On KDE you may
have to scroll yourself.

## After a capture

A thumbnail stays in the corner for a few seconds after saving. Drag it into
any app, or use its buttons: copy, save, annotate, pin. Right-click for the
rest. `shotlet thumbnail` brings the last one back.

**Pins** keep a capture on screen, above other windows: scroll to zoom, drag to
move, right-click for opacity, lock and annotate, `Esc` to close.

**Recent captures** (`shotlet history`, or the tray) lists what you copied or
saved. With Tesseract installed you can search it by text.

## Editor

Press `?` in the editor for every shortcut. The main ones:

| Key | Does |
| --- | --- |
| `Enter`, `Ctrl+C` | copy and close |
| `Ctrl+S`, `Ctrl+Shift+S` | save, save as |
| `Esc` | cancel what is in progress, then close |
| `V` `P` `L` `A` `R` `E` `M` | select, pen, line, arrow, rectangle, ellipse, marker |
| `T` `N` | text, counter |
| `X` (again) | blur, pixelate, solid redaction |
| `I` `U` `S` `C` | colour picker, ruler, spotlight, crop |
| `F` `B` | shape style, beautify frame |
| `1`–`9`, wheel | colour, size |
| `Ctrl+P` | pin to the screen |
| `Ctrl+Shift+C` | copy the text in the picture |
| `Ctrl+Shift+R` | redact e-mails, phones, cards, keys |
| `Ctrl+Z`, `Ctrl+Shift+Z` | undo, redo |

Every annotation can be selected again to move, resize, recolour or delete.
Text recognition and redaction run on your computer.

`shotlet edit FILE` opens an image (PNG, JPEG, WebP), and so does dropping one
on the editor. `shotlet pin [FILE]` pins one, or the clipboard's.

## Recording

`shotlet record`, pick an area, choose MP4 or GIF, microphone and system sound,
and press Record. Stop with the control, the same key, or `shotlet record
--stop`; `--pause`, `--resume` and `--discard` work too. The scissors on the
thumbnail trim the result. Recordings go to your Videos folder.

## GNOME

GNOME does not let an app place its own windows or capture without asking, so
Shotlet comes with a small Shell extension (GNOME 45 to 50):

```sh
shotlet gnome-integration install    # then log out and back in
shotlet gnome-integration status
```

With it there are no prompts, the keys above work, the thumbnail and pins stay
on top, and scrolling capture works. Without it Shotlet uses the
screen-sharing portal: one question the first time, and the thumbnail is an
ordinary window. The tray icon needs the AppIndicator extension.

**Safety.** The extension answers only the installed `shotlet`, never on the
lock screen. It returns no pictures over D-Bus: captures go through private
files that Shotlet deletes once read. While a scrolling capture runs it moves
the pointer and turns the wheel inside the chosen area, nothing else.

The keys are changed with `shotlet gnome-integration shortcut MODE KEY`
(`none` for no key). `uninstall` gives GNOME back the ones it took.

## Permissions

`shotlet permissions` says how captures go and what Shotlet was granted;
`shotlet permissions reset` forgets it (`--dry-run` only lists). On KDE and on
wlroots compositors (Sway, Hyprland...) Shotlet captures directly, with no
prompt.

## Settings

`shotlet settings`, or the file `~/.config/shotlet/config` (`key=value`; safe to
edit while Shotlet runs).

| Key | Does |
| --- | --- |
| `save_dir`, `record_dir` | where files go (default: Pictures, Videos) |
| `copy_on_save` | saving also copies |
| `thumbnail` | after which actions: save, copy and save, never |
| `after_fullscreen` | screens and windows: `thumbnail`, `copy`, `save`, `editor` |
| `history`, `history_max`, `history_max_mb` | recent captures |
| `loupe` | magnifier: `hold`, `always`, `never` |
| `scroll_auto`, `scroll_max_height` | scrolling capture |
| `record_format`, `record_fps`, `record_quality` | recording |
| `beautify_always` | the beautify frame on every capture |

Recent captures are in `~/.local/state/shotlet`, readable only by you.

## Optional programs

Shotlet runs without these, and says so when something needs one.

| Program or library | For |
| --- | --- |
| PipeWire | fast portal captures, recording |
| `ffmpeg` (or FFmpeg's libraries) | MP4; GIF needs nothing |
| Tesseract and language data | copy text, redact, history search |
| `libxkbcommon`, `libfontconfig` | your keyboard layout, your fonts |
| `libturbojpeg`, `libwebp` | progressive JPEG, WebP |

Every command: `shotlet --help`, `shotlet help COMMAND`, `man shotlet`.
