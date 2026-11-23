#!/usr/bin/env bash
# Runs the verification gate against an existing project: type check,
# build, lint. Does not edit tracked files; like running the commands by
# hand, it writes dist/ and node_modules/.tmp inside the target. Exits 1
# if any step fails. See README.md "The five scripts".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: verify.sh --target <dir> [--install] [--context <n>]

  --target <dir>   Project to verify. Must already have a package.json.
  --install        Run `npm install` in the target first. Without it, the
                   target must already have node_modules.
  --context <n>    Source lines shown before and after each type error
                   (default 4).

Steps, in order: tsc -b, npm run build, npm run lint. Every step runs
even if an earlier one fails, so one run reports all three results. A
failed type check prints an error count per code and per file, then each
error with its surrounding source lines.
USAGE
}

TARGET_DIR=""
INSTALL=0
CONTEXT=4
HEAD_LINES=12

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  TARGET_DIR="$2"; shift 2 ;;
        --install) INSTALL=1; shift ;;
        --context) CONTEXT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -n "$TARGET_DIR" ]] || { echo "ERROR: --target is required" >&2; usage; exit 1; }
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: --target must be an existing directory" >&2; exit 1; }
[[ -f "$TARGET_DIR/package.json" ]] || { echo "ERROR: no package.json in target: $TARGET_DIR" >&2; exit 1; }
[[ "$CONTEXT" =~ ^[0-9]+$ ]] || { echo "ERROR: --context needs a number, got: $CONTEXT" >&2; exit 1; }

init_log_file "$(basename -- "$TARGET_DIR").verify.log"
acquire_target_lock "$TARGET_DIR"

RESULTS=()
FAILED=0

# Prints lines $2..$3 of file $1 with line numbers; line $4 is marked ">".
show_lines() {
    awk -v s="$2" -v e="$3" -v t="$4" '
        NR >= s && NR <= e { printf "  %s %4d | %s\n", (NR == t ? ">" : " "), NR, $0 }
    ' "$1"
}

# Prints a type-error report from saved `tsc -b` output $1: counts per
# code and per file, then each error with context. Returns 1 when the
# output holds no parseable "error TS" lines (the caller falls back to
# the raw tail). Source files are read relative to the target.
print_tsc_context() {
    local raw="$1" errs other count file line col code msg start end prev_file=""
    errs="$(mktemp)"
    other="$(mktemp)"
    sed -nE 's/^(.+)\(([0-9]+),([0-9]+)\): error (TS[0-9]+): (.*)$/\1\t\2\t\3\t\4\t\5/p' "$raw" > "$errs"
    grep -E 'error TS' "$raw" | grep -vE '^.+\([0-9]+,[0-9]+\): error TS' > "$other" || true
    count="$(wc -l < "$errs")"
    if (( count == 0 )) && [[ ! -s "$other" ]]; then
        rm -f -- "${errs:?}" "${other:?}"
        return 1
    fi
    echo "  type errors: $count"
    echo "  by code:"
    cut -f4 "$errs" | sort | uniq -c | sort -rn | sed 's/^/    /'
    echo "  by file:"
    cut -f1 "$errs" | sort | uniq -c | sort -rn | sed 's/^/    /'
    if [[ -s "$other" ]]; then
        echo "  other diagnostics:"
        sed 's/^/    /' "$other"
    fi
    while IFS=$'\t' read -r file line col code msg; do
        if [[ "$file" != "$prev_file" ]]; then
            echo
            echo "  ---- $file"
            if [[ -f "${TARGET_DIR}/${file}" ]]; then
                echo "  first ${HEAD_LINES} lines:"
                show_lines "${TARGET_DIR}/${file}" 1 "$HEAD_LINES" 0
            fi
            prev_file="$file"
        fi
        echo
        echo "  [$code] $file:$line:$col  $msg"
        if [[ -f "${TARGET_DIR}/${file}" ]]; then
            start=$(( line > CONTEXT ? line - CONTEXT : 1 ))
            end=$(( line + CONTEXT ))
            show_lines "${TARGET_DIR}/${file}" "$start" "$end" "$line"
        fi
    done < <(sort -t $'\t' -k1,1 -k2,2n "$errs")
    rm -f -- "${errs:?}" "${other:?}"
    return 0
}

# Runs "$@" inside the target. Output goes to the log; on failure the
# last 20 lines (or, for the type check, the error report) are also
# shown. Records PASS/FAIL and never exits early.
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
        log_error "FAIL ${name} (full output in the log)"
        if [[ "$name" == "type check" ]]; then
            if ! { print_tsc_context "$out" | tee -a "$LOG_FILE" >&2; }; then
                tail -n 20 -- "$out" >&2
            fi
        else
            tail -n 20 -- "$out" >&2
        fi
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
