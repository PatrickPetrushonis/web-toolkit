#!/usr/bin/env bash
# Shows what moving a project onto a profile would do, without touching
# the project. Works on temporary copies (node_modules, dist and .git are
# not copied): a baseline copy is verified as it is, a second copy gets
# `update.sh --apply` and is verified again. The real project only gets
# the read-only `update.sh` dry run. See README.md "The five scripts".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: preflight.sh --master-config <dir> --profile <name> --target <dir>
                    [--skip-baseline] [--keep]

  --master-config <dir>  Directory holding profiles (expects
                          <dir>/profiles/<name>/).
  --profile <name>        Profile to apply to the copy.
  --target <dir>         Existing project to assess. Never modified.
  --skip-baseline        Skip verifying the unmodified copy.
  --keep                 Keep the temporary copies and print their paths.

Needs network access: each verified copy runs `npm install`. Reports, in
order: the drift of the real project, the baseline result, the files the
update would change, and the result after the update.
USAGE
}

MASTER_CONFIG=""
PROFILE=""
TARGET_DIR=""
SKIP_BASELINE=0
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --master-config)
            reject_if_already_set MASTER_CONFIG "--master-config given more than once - exactly one master config, not a stack"
            MASTER_CONFIG="$2"; shift 2 ;;
        --profile)
            reject_if_already_set PROFILE "--profile given more than once - profiles are never mixed"
            PROFILE="$2"; shift 2 ;;
        --target)        TARGET_DIR="$2"; shift 2 ;;
        --skip-baseline) SKIP_BASELINE=1; shift ;;
        --keep)          KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

resolve_profile_dir
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: --target must be an existing directory" >&2; exit 1; }
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
NAME="$(basename -- "$TARGET_DIR")"

init_log_file "${NAME}.preflight.log"
# No target lock here: the update.sh dry run below takes its own lock on
# the real target, and each copy is locked by the scripts that use it.

WORK="$(mktemp -d)"
cleanup() {
    if (( KEEP )); then
        echo "kept: ${WORK}"
    else
        rm -rf -- "${WORK:?}"
    fi
}
trap cleanup EXIT

copy_project() {
    local dest="$1"
    mkdir -p -- "$dest"
    tar -C "$TARGET_DIR" --exclude=./node_modules --exclude=./dist --exclude=./.git -cf - . | tar -C "$dest" -xf -
}

# Runs "$@" with its output saved to $WORK/$1-style file $out, then prints
# its "Summary:" block. Sets LAST_RC to the exit status.
run_quiet() {
    local out="$1"; shift
    LAST_RC=0
    "$@" >"$out" 2>&1 || LAST_RC=$?
    { echo "----- $* -----"; cat -- "$out"; } >> "$LOG_FILE"
    sed -n '/^Summary:/,$p' "$out"
    if (( LAST_RC != 0 )) && ! grep -q '^Summary:' "$out"; then
        tail -n 20 -- "$out"
    fi
    return 0
}

log_info "preflight for ${TARGET_DIR} (profile: ${PROFILE})"

echo
echo "== 1. drift of the real project (read-only)"
run_quiet "${WORK}/drift.out" "${SCRIPT_DIR}/update.sh" --master-config "$MASTER_CONFIG" --profile "$PROFILE" --target "$TARGET_DIR"
DRIFT_RC="$LAST_RC"

BASELINE="skipped"
if (( ! SKIP_BASELINE )); then
    echo
    echo "== 2. baseline: the unmodified copy"
    copy_project "${WORK}/${NAME}.baseline"
    run_quiet "${WORK}/baseline.out" "${SCRIPT_DIR}/verify.sh" --target "${WORK}/${NAME}.baseline" --install
    if (( LAST_RC == 0 )); then BASELINE="PASS"; else BASELINE="FAIL"; fi
fi

echo
echo "== 3. update applied to a copy"
copy_project "${WORK}/${NAME}.preflight"
run_quiet "${WORK}/update.out" "${SCRIPT_DIR}/update.sh" --master-config "$MASTER_CONFIG" --profile "$PROFILE" --target "${WORK}/${NAME}.preflight" --apply
UPDATE_RC="$LAST_RC"
echo "  files the update changes:"
CHANGES="$(diff -rq --exclude=node_modules --exclude=dist --exclude=.git "$TARGET_DIR" "${WORK}/${NAME}.preflight" || true)"
if [[ -n "$CHANGES" ]]; then
    sed -e "s#${TARGET_DIR}#<project>#g" -e "s#${WORK}/${NAME}.preflight#<updated>#g" -e 's/^/    /' <<< "$CHANGES"
else
    echo "    (none)"
fi

echo
echo "== 4. after the update: the updated copy"
run_quiet "${WORK}/after.out" "${SCRIPT_DIR}/verify.sh" --target "${WORK}/${NAME}.preflight" --install
AFTER_RC="$LAST_RC"
if (( AFTER_RC == 0 )); then AFTER="PASS"; else AFTER="FAIL"; fi

echo
echo "Summary:"
echo "  Project:           $TARGET_DIR"
echo "  Profile:           $PROFILE"
echo "  Drift check:       exit ${DRIFT_RC} (see section 1)"
echo "  Baseline verify:   $BASELINE"
echo "  Update on copy:    exit ${UPDATE_RC}"
echo "  Verify after:      $AFTER"
echo "  Log:               $LOG_FILE"
(( UPDATE_RC == 0 && AFTER_RC == 0 )) || exit 1
