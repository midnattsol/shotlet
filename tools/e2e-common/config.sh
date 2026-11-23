# Shotlet's settings file, $XDG_CONFIG_HOME/shotlet/config (KEY=VALUE).

cfg_path() { echo "$XDG_CONFIG_HOME/shotlet/config"; }
cfg_write() { # cfg_write KEY=VALUE...: the whole file
    mkdir -p "$XDG_CONFIG_HOME/shotlet"
    printf '%s\n' "$@" >"$(cfg_path)"
}
cfg_set() { # cfg_set KEY=VALUE...: each key replaced, or added
    local f kv
    f=$(cfg_path)
    mkdir -p "${f%/*}"
    touch "$f"
    for kv in "$@"; do
        grep -v "^${kv%%=*}=" "$f" >"$f.new"
        echo "$kv" >>"$f.new"
        mv "$f.new" "$f"
    done
}
cfg_has() { # cfg_has KEY=VALUE | KEY: that line, or that key, is set
    case $1 in
        *=*) grep -qxF -- "$1" "$(cfg_path)" 2>/dev/null ;;
        *) grep -q "^$1=" "$(cfg_path)" 2>/dev/null ;;
    esac
}
# the quick-access scenarios: the thumbnail after copy and save, for long
quick_cfg() { cfg_set quick_access_seconds=600 thumbnail=after_copy_and_save; }
