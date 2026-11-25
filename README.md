<p align="center"><img src="assets/icon.svg" width="112" alt=""></p>

# Shotlet

A fast screenshot tool for **Linux on Wayland**: capture, annotate, copy.

- **Capture** an area, a window, a screen, everything, or a page that scrolls
- **Annotate**: arrows, shapes, text, blur, redaction, counters, a magnifier
- **Record** the screen to MP4 or GIF
- **Keep going**: a floating thumbnail, pinned captures, recent captures, text
  recognition, a colour picker

Built for GNOME first, and it works on KDE Plasma, Sway, Hyprland and any
compositor with the standard portals.

## Install

Needs Zig 0.17 to build, and a Wayland session with xdg-desktop-portal.

```sh
zig build -Doptimize=safe
./install.sh --gnome-extension --autostart
```

Everything goes into `~/.local`; nothing needs root. Off GNOME, leave out
`--gnome-extension`; leave out `--autostart` for no tray icon. On GNOME, log
out and back in once. `./uninstall.sh` removes it all and keeps your settings.

Recording MP4 and reading text use `ffmpeg` and Tesseract when they are
installed ([the full list](docs/GUIDE.md#optional-programs)).

## Use

| | Command | Key (GNOME) |
| --- | --- | --- |
| Area | `shotlet` | `Print` |
| Window | `shotlet window` | `Super+Print` |
| Screen | `shotlet fullscreen` | `Ctrl+Print` |
| Scrolling page | `shotlet scroll` | `Ctrl+Super+Print` |
| Recording | `shotlet record` | `Shift+Super+R` |

In the editor: `Enter` copies and closes, `Ctrl+S` saves, `Esc` quits.
`shotlet --help` lists the rest.

## More

- [Guide](docs/GUIDE.md): every mode, tool, shortcut and setting
- [Contributing](docs/CONTRIBUTING.md): how the code is laid out, and the tests
- [Platform layer](docs/PLATFORM.md): what a port has to provide

What the GNOME extension may and may not do is in
[the guide](docs/GUIDE.md#gnome).

## License

GPL-3.0: see [LICENSE](LICENSE).
