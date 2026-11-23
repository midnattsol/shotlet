#!/bin/sh
# Remove what install.sh installed (the files `install.sh --manifest`
# lists). Settings ($XDG_CONFIG_HOME/shotlet) and the capture history
# ($XDG_STATE_HOME/shotlet) are kept; delete those directories by hand to
# forget them too.
# Env: PREFIX (default ~/.local), XDG_DATA_HOME, XDG_CONFIG_HOME.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/install.sh" ] || { echo "uninstall.sh: install.sh must sit next to it" >&2; exit 1; }
manifest=$(sh "$here/install.sh" --manifest)
bin=$(echo "$manifest" | sed -n 's/^bin //p')
extension_dir=$(echo "$manifest" | sed -n 's/^extension //p')

pkill -f "$bin --daemon" 2>/dev/null || true
if [ -d "$extension_dir" ] && [ -x "$bin" ]; then
    "$bin" gnome-integration uninstall || true
fi
echo "$manifest" | sed -n -e 's/^bin //p' -e 's/^file //p' | while IFS= read -r f; do
    rm -f "$f"
done
sh "$here/install.sh" --refresh-caches
echo "Shotlet removed (settings and history kept in ${XDG_CONFIG_HOME:-$HOME/.config}/shotlet and ${XDG_STATE_HOME:-$HOME/.local/state}/shotlet)"
