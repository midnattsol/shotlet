# The scenario tables' helpers (tools/e2e/table.sh, tools/container/
# table.sh: one row per scenario, fields split by "|").

# _trim TEXT: without its leading and trailing blanks
_trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
