#!/bin/sh
# Install Shotlet for the current user (into ~/.local; nothing needs root).
#
# usage: ./install.sh [--autostart] [--gnome-extension | --no-gnome-extension]
#   --autostart            start the tray daemon at login
#   --gnome-extension      install the GNOME Shell integration without asking
#   --no-gnome-extension   do not offer it
# Env: PREFIX (default ~/.local), XDG_DATA_HOME, XDG_CONFIG_HOME.
# Run it from a release tarball (tools/package.sh), or from the source tree
# after `zig build -Doptimize=safe`. Settings and history are never touched.
# uninstall.sh asks it what it installs (--manifest) and to refresh the
# desktop caches (--refresh-caches).
set -eu

app_id=io.github.midnattsol.Shotlet
ext_uuid=shotlet@midnattsol.github.io
here=$(cd "$(dirname "$0")" && pwd)
prefix=${PREFIX:-$HOME/.local}
data=${XDG_DATA_HOME:-$HOME/.local/share}
config=${XDG_CONFIG_HOME:-$HOME/.config}

# everything this installs (the one list: uninstall.sh removes it)
bin=$prefix/bin/shotlet
desktop=$data/applications/$app_id.desktop
icon=$data/icons/hicolor/scalable/apps/$app_id.svg
icon_symbolic=$data/icons/hicolor/symbolic/apps/$app_id-symbolic.svg
man=$data/man/man1/shotlet.1
bash_completion=$data/bash-completion/completions/shotlet
zsh_completion=$data/zsh/site-functions/_shotlet
fish_completion=$config/fish/completions/shotlet.fish
autostart_file=$config/autostart/$app_id.desktop
# files of versions before the app id, replaced by the ones above
legacy_desktop=$data/applications/shotlet.desktop
legacy_icon=$data/icons/hicolor/scalable/apps/shotlet.svg
legacy_autostart=$config/autostart/shotlet.desktop
# what `shotlet gnome-integration install` adds
extension_dir=$data/gnome-shell/extensions/$ext_uuid

# manifest: "KIND PATH" per line; KIND is bin, file or extension
manifest() {
    echo "bin $bin"
    for f in "$desktop" "$icon" "$icon_symbolic" "$man" "$bash_completion" "$zsh_completion" \
        "$fish_completion" "$autostart_file" "$legacy_desktop" "$legacy_icon" "$legacy_autostart"; do
        echo "file $f"
    done
    echo "extension $extension_dir"
}

# refresh_caches: the desktop entry, KService and icon caches
refresh_caches() {
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$data/applications" || true
    # KDE: KWin finds the file's X-KDE-DBUS-Restricted-Interfaces (screenshots
    # without a dialog) through the KService cache
    command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true
}

autostart=no
extension=ask
for arg in "$@"; do
    case $arg in
        --autostart) autostart=yes ;;
        --gnome-extension) extension=yes ;;
        --no-gnome-extension) extension=no ;;
        --manifest) manifest; exit 0 ;;
        --refresh-caches) refresh_caches; exit 0 ;;
        -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
    esac
done

if [ -x "$here/zig-out/bin/shotlet" ]; then
    built=$here/zig-out/bin/shotlet
elif [ -x "$here/shotlet" ]; then
    built=$here/shotlet
else
    echo "install.sh: no shotlet binary; build it first: zig build -Doptimize=safe" >&2
    exit 1
fi

install -Dm755 "$built" "$bin"
# an absolute Exec: launchers and GNOME's app matching need it to resolve
mkdir -p "$(dirname "$desktop")"
sed "s|^Exec=shotlet|Exec=$bin|" "$here/$app_id.desktop" >"$desktop"
chmod 644 "$desktop"
install -Dm644 "$here/assets/icon.svg" "$icon"
install -Dm644 "$here/assets/icon-symbolic.svg" "$icon_symbolic"
rm -f "$legacy_desktop" "$legacy_icon"
if [ -f "$legacy_autostart" ]; then
    rm -f "$legacy_autostart"
    autostart=yes
fi
refresh_caches
echo "installed $bin, $app_id.desktop and its icon"

# the man page and the shell completions, generated from the binary
for f in "$man" "$bash_completion" "$zsh_completion" "$fish_completion"; do mkdir -p "$(dirname "$f")"; done
"$bin" man-page >"$man"
"$bin" completions bash >"$bash_completion"
"$bin" completions zsh >"$zsh_completion"
"$bin" completions fish >"$fish_completion"
echo "installed man shotlet and completions for bash, zsh and fish"
echo "  zsh: add $data/zsh/site-functions to fpath (before compinit) if it is not there"

if [ "$autostart" = yes ]; then
    mkdir -p "$(dirname "$autostart_file")"
    sed -e "s|^Exec=shotlet --daemon|Exec=$bin --daemon|" \
        -e '/^Actions=/d' -e '/^\[Desktop Action/,$d' -e '/^$/d' \
        "$here/$app_id.desktop" >"$autostart_file"
    echo "X-GNOME-Autostart-enabled=true" >>"$autostart_file"
    echo "the tray daemon starts at login ($autostart_file)"
fi

case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:GNOME:* | *:gnome:*)
        if [ "$extension" = ask ]; then
            if [ -t 0 ]; then
                printf 'Install the GNOME Shell integration (keeps the thumbnail and pins above other windows)? [Y/n] '
                read -r answer || answer=n
                case $answer in [nN]*) extension=no ;; *) extension=yes ;; esac
            else
                extension=no
                echo "GNOME: run 'shotlet gnome-integration install' to keep the thumbnail and pins above other windows"
            fi
        fi
        [ "$extension" = yes ] && "$bin" gnome-integration install || true
        ;;
esac

case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "note: $prefix/bin is not in PATH; add it to run 'shotlet' from a terminal" ;;
esac
