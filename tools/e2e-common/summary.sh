# The runners' reports: every check line ("PASS|FAIL|SKIP TAG: what")
# collected in one results.txt, and one summary line at the end.

# result_lines RESULTS NOISE: stdin's check lines and notes (indented)
# appended to RESULTS and shown; anything else appended to NOISE
result_lines() {
    local line
    while IFS= read -r line; do
        case $line in
            PASS* | FAIL* | SKIP* | "  "*) echo "$line" | tee -a "$1" ;;
            *) echo "$line" >>"$2" ;;
        esac
    done
}
# print_summary NAME RESULTS: "NAME: N passed, M failed, K skipped"
print_summary() {
    local p f s
    p=$(grep -c '^PASS' "$2" 2>/dev/null) f=$(grep -c '^FAIL' "$2" 2>/dev/null) s=$(grep -c '^SKIP' "$2" 2>/dev/null)
    echo "$1: ${p:-0} passed, ${f:-0} failed, ${s:-0} skipped"
}
