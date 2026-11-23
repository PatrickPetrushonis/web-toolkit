#!/usr/bin/env bash
# Runs the verification gate against an existing project: type check,
# build, lint. Does not edit tracked files; like running the commands by
# hand, it writes dist/ and node_modules/.tmp inside the target. Exits 1
# if any step fails. See README.md "The four scripts".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: verify.sh --target <dir> [--install]

  --target <dir>  Project to verify. Must already have a package.json.
  --install       Run `npm install` in the target first. Without it, the
                  target must already have node_modules.

Steps, in order: tsc -b, npm run build, npm run lint. Every step runs
even if an earlier one fails, so one run reports all three results.
USAGE
}

TARGET_DIR=""
INSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  TARGET_DIR="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -n "$TARGET_DIR" ]] || { echo "ERROR: --target is required" >&2; usage; exit 1; }
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: --target must be an existing directory" >&2; exit 1; }
[[ -f "$TARGET_DIR/package.json" ]] || { echo "ERROR: no package.json in target: $TARGET_DIR" >&2; exit 1; }
for cmd in node npm; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing command: $cmd" >&2; exit 1; }
done

init_log_file "$(basename -- "$TARGET_DIR").verify.log"
acquire_target_lock "$TARGET_DIR"

RESULTS=()
FAILED=0

# Runs "$@" inside the target. Output goes to the log; on failure the
# last 20 lines are also shown. Records PASS/FAIL and never exits early.
run_step() {
    local name="$1"; shift
    local out
    out="$(mktemp)"
    log_info "step '${name}': $*"
    if ( cd -- "$TARGET_DIR" && "$@" ) >"$out" 2>&1; then
        RESULTS+=("PASS  ${name}")
        log_info "PASS ${name}"
    else
        RESULTS+=("FAIL  ${name}")
        FAILED=$((FAILED+1))
        log_error "FAIL ${name} (last 20 lines below; full output in the log)"
        tail -n 20 -- "$out" >&2
    fi
    { echo "----- ${name} output -----"; cat -- "$out"; } >> "$LOG_FILE"
    rm -f -- "${out:?}"
}

if (( INSTALL )); then
    run_step "install" npm install
elif [[ ! -d "$TARGET_DIR/node_modules" ]]; then
    log_error "node_modules not found in $TARGET_DIR - pass --install"
    exit 1
fi

run_step "type check" ./node_modules/.bin/tsc -b
run_step "build" npm run build
run_step "lint" npm run lint

echo
echo "Summary:"
printf '  %s\n' "${RESULTS[@]}"
echo "  Log: $LOG_FILE"
(( FAILED == 0 )) || exit 1
