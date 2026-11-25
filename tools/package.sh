#!/bin/sh
# The release package's layout: everything install.sh needs to install
# from DIR, plus the uninstaller and the docs.
#   tools/package.sh DIR [BIN]   (BIN: default zig-out/bin/shotlet)
# The GNOME Shell extension is not shipped as files: it is embedded in the
# binary (`shotlet gnome-integration install`). Run from the repository
# root.
set -eu

[ $# -ge 1 ] || { echo "usage: tools/package.sh DIR [BIN]" >&2; exit 2; }
dir=$1
bin=${2:-zig-out/bin/shotlet}
[ -x "$bin" ] || { echo "tools/package.sh: no binary at $bin" >&2; exit 1; }

mkdir -p "$dir"
cp "$bin" "$dir/shotlet"
cp -r io.github.midnattsol.Shotlet.desktop assets install.sh uninstall.sh README.md docs LICENSE "$dir/"
