#!/bin/sh
# Lists functions longer than a soft limit (default fn_limit in
# tools/sources.sh), longest first, in the sources that file lists: Zig,
# shell, Python and JavaScript. A report only: it never fails. Relies on
# formatted code, where a function's closing brace sits at the
# indentation of its first line (Python's ends before the next line
# indented no deeper than its def); a function nested in another counts
# toward the outer one.
set -eu

. tools/sources.sh
limit=${1:-$fn_limit}

sources | xargs awk -v limit="$limit" '
    function done_(last) {
        n = last - start + 1
        if (n > limit) printf "%5d  %s:%d  %s\n", n, file, start, name
        depth = 0
    }
    FNR == 1 {
        if (depth == 1 && py) done_(lastline)
        depth = 0
        file = FILENAME
        py = FILENAME ~ /\.py$/
        if (FILENAME ~ /\.zig$/) head = "^ *(pub )?(export )?(inline )?fn [A-Za-z_][A-Za-z0-9_]*\\(.*[^;]$"
        else if (FILENAME ~ /\.sh$/) head = "^ *[A-Za-z_][A-Za-z0-9_]*\\(\\) *\\{"
        else if (py) head = "^ *(async )?def [A-Za-z_][A-Za-z0-9_]*\\("
        else head = "^ *((async|static|get|set) )*(function\\*? *)?[A-Za-z_$][A-Za-z0-9_$]*\\([^()]*\\) *\\{$"
    }
    # a Python function ends before the first code line indented no deeper
    depth == 1 && py && $0 ~ /[^ ]/ && $0 !~ /^ *#/ {
        match($0, /^ */)
        if (RLENGTH <= indent) done_(lastline)
    }
    depth == 0 && $0 ~ head && $0 !~ /^ *(if|for|while|switch|catch|return)\>/ {
        match($0, /^ */)
        indent = RLENGTH
        name = $0
        sub(/^ *((pub|export|inline|async|static|get|set) )*(fn |function\*? *|def )?/, "", name)
        sub(/\(.*/, "", name)
        start = FNR
        lastline = FNR
        depth = 1
        # a shell one-liner that wraps ends at the first line ending in }
        inline_end = $0 !~ /\{ *(#.*)?$/
        if (!py && $0 ~ /}$/) depth = 0
        next
    }
    depth == 1 && py {
        if ($0 ~ /[^ ]/) lastline = FNR
        next
    }
    depth == 1 {
        match($0, /^ */)
        if (inline_end ? $0 ~ /}$/ : RLENGTH == indent && $0 ~ /^ *}[;,)]*$/) done_(FNR)
    }
    END { if (depth == 1 && py) done_(lastline) }
' | sort -rn
