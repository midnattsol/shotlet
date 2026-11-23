#!/bin/bash
# Container e2e suite: Shotlet on wlroots (sway, labwc) and KDE (KWin),
# each scenario in a throwaway container (--rm, no network, no host
# display, bus or PipeWire mounted). See tools/container/inner.sh for what
# runs inside, table.sh for the scenarios, and the README's "Tests".
#
# usage: tools/container/run.sh [--list] [--bins SHOTLET WLDRIVE DROPTARGET] [--] [TARGET...]
#        zig build e2e-container [-- TARGET...]
# TARGET is COMPOSITOR (all its scenarios), COMPOSITOR:SCENARIO, or `all`
# (the default). Compositors: sway labwc kwin. --list prints the scenarios.
# Prints PASS/FAIL/SKIP per check (all of them also in results.txt) and a
# summary line; exits 1 when anything failed, 0 with a SKIP when neither
# docker nor podman is usable, 2 for an unknown target.
# Env: CTR_ENGINE=docker|podman   pick the engine (default: whichever works)
#      CTR_GPU=0                  never pass a GPU render node (capture and
#                                 KWin then skip)
#      CTR_PROBE='shell code'     run it in the `probe` scenario (debugging;
#                                 CTR_PROBE0 runs before the driver starts)
#      CTR_KWIN_LOG=rules         KWin's QT_LOGGING_RULES
#      CTR_IMAGE=name:TAG         image (default shotlet-e2e:trixie; built
#                                 when missing from tools/container/
#                                 Containerfile, or Containerfile.TAG, e.g.
#                                 shotlet-e2e:sid from Containerfile.sid)
#      E2E_MONITORS="WxH ..."     outputs for every scenario run (else each
#                                 scenario's own, from table.sh)
#      E2E_OUT=dir                keep logs and screenshots there
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${CTR_IMAGE:-shotlet-e2e:trixie}
. "$ROOT/tools/container/table.sh"
. "$ROOT/tools/e2e-common/summary.sh"

list_scenarios() {
    local n c m f d
    printf '%-10s %-16s %-33s %-11s %s\n' SCENARIO COMPOSITORS MONITORS FLAGS "WHAT IT CHECKS"
    while IFS='|' read -r n c m f d; do
        printf '%-10s %-16s %-33s %-11s %s\n' "$(_trim "$n")" "$(_trim "$c")" "$(_trim "$m")" "$(_trim "$f")" "$(_trim "$d")"
    done < <(scenario_table)
}

BIN=$ROOT/zig-out/bin/shotlet
WLDRIVE=$ROOT/zig-out/bin/shotlet-wldrive
DROP=$ROOT/zig-out/bin/shotlet-droptarget
targets=()
while [ $# -gt 0 ]; do
    case $1 in
        --list) list_scenarios; exit 0 ;;
        --bins) BIN=$2 WLDRIVE=$3 DROP=$4; shift 4 ;;
        --) shift; targets+=("$@"); break ;;
        *) targets+=("$1"); shift ;;
    esac
done
[ ${#targets[@]} -eq 0 ] && targets=(all)
runs=()
for t in "${targets[@]}"; do
    case $t in
        all) for c in $COMPOSITORS; do for s in $(scenarios_on "$c"); do runs+=("$c:$s"); done; done ;;
        sway | labwc | kwin) for s in $(scenarios_on "$t"); do runs+=("$t:$s"); done ;;
        *:*)
            case " $COMPOSITORS " in *" ${t%%:*} "*) ;; *) echo "run.sh: unknown compositor in $t" >&2; exit 2 ;; esac
            scenario_row "${t#*:}" || { echo "run.sh: unknown scenario in $t (--list)" >&2; exit 2; }
            runs+=("$t")
            ;;
        *) echo "run.sh: unknown target $t" >&2; exit 2 ;;
    esac
done

engine=${CTR_ENGINE:-}
if [ -z "$engine" ]; then
    for e in docker podman; do
        command -v "$e" >/dev/null && "$e" info >/dev/null 2>&1 && { engine=$e; break; }
    done
fi
if [ -z "$engine" ]; then
    echo "SKIP container: neither docker nor podman is usable"
    exit 0
fi
for f in "$BIN" "$WLDRIVE" "$DROP"; do
    [ -x "$f" ] || { echo "run.sh: $f missing (zig build e2e-driver)" >&2; exit 2; }
done

if ! "$engine" image inspect "$IMAGE" >/dev/null 2>&1; then
    cf=$ROOT/tools/container/Containerfile
    [ "${IMAGE##*:}" != trixie ] && cf=$cf.${IMAGE##*:}
    [ -f "$cf" ] || { echo "run.sh: no $cf to build $IMAGE from" >&2; exit 2; }
    echo "building $IMAGE from ${cf#$ROOT/} (once; needs the network for apt)" >&2
    "$engine" build -t "$IMAGE" -f "$cf" "$ROOT/tools/container" >&2 ||
        { echo "FAIL container: image build"; exit 1; }
fi

if [ -n "${E2E_OUT:-}" ]; then
    OUT=$E2E_OUT; mkdir -p "$OUT"; keep=1
else
    OUT=$(mktemp -d -t shotlet-ctr.XXXXXX); keep=
fi
OUT=$(realpath "$OUT")
: >"$OUT/results.txt"

# run as the caller's uid so the results directory stays theirs
user_args=(--user "$(id -u):$(id -g)")
[ "$engine" = podman ] && user_args=(--userns=keep-id)

# A GPU render node (never a card/KMS node: nothing can reach a display),
# when the host has one: xdg-desktop-portal-wlr wants dmabuf formats from
# screencopy, which wlroots' pixman renderer cannot offer, and KWin only
# offers its screenshot and screencast interfaces when compositing with
# OpenGL. CTR_GPU=0 never passes one.
gpu_args=()
if [ "${CTR_GPU:-1}" != 0 ]; then
    for node in /dev/dri/renderD*; do
        [ -c "$node" ] || continue
        gpu_args=(--device "$node" --group-add "$(stat -c %g "$node")" -e CTR_RENDER_NODE="$node")
        break
    done
fi

failed=0
for r in "${runs[@]}"; do
    comp=${r%%:*} scen=${r#*:}
    dir=$OUT/$comp/$scen
    mkdir -p "$dir"
    : >"$dir/results.txt"
    name=shotlet-e2e-$$-$comp-$scen
    # a scenario still running after 4 minutes is stuck (inner.sh stops at
    # 5): keep what its processes are waiting on, seen from outside
    ( sleep 240 & sp=$!
      trap 'kill $sp; exit' TERM
      wait $sp
      "$engine" exec "$name" sh -c 'for p in /proc/[0-9]*; do echo "${p#/proc/} $(cat $p/wchan 2>/dev/null) $(cat $p/stat 2>/dev/null | cut -d" " -f3) $(cat $p/comm 2>/dev/null)"; done' \
          >"$dir/stuck-host.txt" 2>&1 ) &
    watch=$!
    "$engine" run --rm --name "$name" --network none --init --shm-size 256m \
        "${user_args[@]}" "${gpu_args[@]}" \
        -e SHOTLET_E2E_SANDBOX=container -e HOME=/tmp/home \
        ${CTR_PROBE:+-e CTR_PROBE} ${CTR_PROBE0:+-e CTR_PROBE0} ${CTR_KWIN_LOG:+-e CTR_KWIN_LOG} ${E2E_MONITORS:+-e E2E_MONITORS} \
        -v "$(realpath "$BIN")":/opt/shotlet/bin/shotlet:ro \
        -v "$(realpath "$WLDRIVE")":/opt/shotlet/bin/shotlet-wldrive:ro \
        -v "$(realpath "$DROP")":/opt/shotlet/bin/shotlet-droptarget:ro \
        -v "$ROOT/tools/container":/opt/shotlet/ctr:ro \
        -v "$ROOT/tools/e2e-common":/opt/shotlet/common:ro \
        -v "$(realpath "$BIN")":/opt/shotlet/pkg/shotlet:ro \
        -v "$ROOT/install.sh":/opt/shotlet/pkg/install.sh:ro \
        -v "$ROOT/io.github.midnattsol.Shotlet.desktop":/opt/shotlet/pkg/io.github.midnattsol.Shotlet.desktop:ro \
        -v "$ROOT/assets":/opt/shotlet/pkg/assets:ro \
        -v "$dir":/out \
        "$IMAGE" timeout 300 /opt/shotlet/ctr/inner.sh "$comp" "$scen" \
        2>"$dir/stderr.log" | result_lines "$dir/results.txt" "$dir/stdout.log"
    rc=${PIPESTATUS[0]}
    kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
    # the scenarios' own notes (indented) and driver errors; the rest of
    # the session's chatter stays in stderr.log
    grep -E '^(  |driver:)' "$dir/stderr.log" | sed "s/^/  [$comp:$scen] /" >&2
    grep -q "^FAIL" "$dir/results.txt" && failed=1
    if [ "$rc" -ne 0 ] && ! grep -q "^FAIL" "$dir/results.txt"; then
        echo "FAIL $comp $scen: the container exited with $rc" | tee -a "$dir/results.txt"
        failed=1
    fi
    grep -E '^(PASS|FAIL|SKIP) ' "$dir/results.txt" >>"$OUT/results.txt"
done

echo
print_summary e2e-container "$OUT/results.txt"
if [ "$failed" -ne 0 ] || [ -n "$keep" ]; then
    echo "logs and screenshots: $OUT"
else
    rm -rf "$OUT"
fi
exit $failed
