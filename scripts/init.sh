#!/usr/bin/env bash
# Scaffolds a new project and brings it into exact parity with a single
# profile under a master config. See README.md "Master/child
# relationship" for the zero-drift-per-profile policy this enforces,
# and for how init.sh relates to update.sh and convert.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: init.sh --master-config <dir> --profile <name> --target <dir> [--apply]

  --master-config <dir>  Directory holding profiles (expects
                          <dir>/profiles/<name>/). Exactly one - there
                          is a single source of truth, not a stack.
  --profile <name>        Which profile to apply (e.g. vite-react,
                          astro-static). Exactly one - profiles are
                          never mixed.
  --target <dir>         Where to scaffold the new project. Must not
                          already exist (use update.sh on an existing
                          project instead).
  --apply                Actually write changes. Without this flag,
                          init.sh reports what it would do and exits.
EOF
}

MASTER_CONFIG=""
PROFILE=""
TARGET_DIR=""
DRY_RUN=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --master-config)
            reject_if_already_set MASTER_CONFIG "--master-config given more than once - exactly one master config, not a stack"
            MASTER_CONFIG="$2"; shift 2 ;;
        --profile)
            reject_if_already_set PROFILE "--profile given more than once - profiles are never mixed"
            PROFILE="$2"; shift 2 ;;
        --target)  TARGET_DIR="$2"; shift 2 ;;
        --apply)   DRY_RUN=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

resolve_profile_dir
[[ -z "$TARGET_DIR" ]] && { echo "ERROR: --target is required" >&2; exit 1; }
[[ -e "$TARGET_DIR" ]] && { echo "ERROR: target already exists: $TARGET_DIR (use update.sh, not init.sh, on an existing project)" >&2; exit 1; }

init_log_file "$(target_name "$TARGET_DIR").init.log"
acquire_target_lock "$TARGET_DIR"

check_node_version 20

MANIFEST="${PROFILE_DIR}/manifest.json"
[[ -f "$MANIFEST" ]] || { log_error "manifest.json not found in profile: $PROFILE_DIR"; exit 1; }
jq empty "$MANIFEST" || { log_error "manifest.json is not valid JSON: $MANIFEST"; exit 1; }

# The scaffold command is profile-declared, not hardcoded - a Vite
# React profile and an Astro profile use different scaffolding tools
# entirely, so this can't be one fixed npm-create invocation the way
# it was before profiles existed.
SCAFFOLD_CMD="$(jq -r '.scaffold_command // empty' "$MANIFEST")"
if [[ -z "$SCAFFOLD_CMD" ]]; then
    log_error "manifest.json has no scaffold_command: $MANIFEST"
    exit 1
fi
# Run as an argv array, not through eval: the target path can hold spaces
# or shell metacharacters. The command's words are split on whitespace, so
# an argument in scaffold_command must not itself contain a space.
# create-vite 9.3.4 created an absolute --target under the current
# directory (observed), so the scaffold runs from the target's parent with
# the target's own name.
TARGET_PARENT="$(cd "$(dirname -- "$TARGET_DIR")" 2>/dev/null && pwd)" || {
    log_error "parent directory of --target does not exist: $(dirname -- "$TARGET_DIR")"
    exit 1
}
TARGET_NAME="$(basename -- "$TARGET_DIR")"
read -r -a SCAFFOLD_ARGV <<< "$SCAFFOLD_CMD"
for i in "${!SCAFFOLD_ARGV[@]}"; do
    SCAFFOLD_ARGV[i]="${SCAFFOLD_ARGV[i]//\{target\}/$TARGET_NAME}"
done

SYNCED=0
UNCHANGED=0

log_info "scaffolding new project at: $TARGET_DIR (profile: $PROFILE)"
if (( DRY_RUN )); then
    log_info "[DRY RUN] would run in $TARGET_PARENT: $(printf '%q ' "${SCAFFOLD_ARGV[@]}")"
else
    ( cd "$TARGET_PARENT" && "${SCAFFOLD_ARGV[@]}" )
fi

# Whatever default config files the scaffold tool ships (Vite's own
# tsconfig.json/eslint.config.js, Astro's equivalents) get replaced by
# the profile's versions here - copy_template_file always overwrites
# rather than skipping on an existing file.
log_info "applying profile: $PROFILE_DIR"
apply_master_config "$PROFILE_DIR" "$TARGET_DIR"
SYNCED=$((SYNCED + APPLY_CHANGED_COUNT))
UNCHANGED=$((UNCHANGED + APPLY_UNCHANGED_COUNT))

if (( DRY_RUN )); then
    log_info "[DRY RUN] would run: npm install (in $TARGET_DIR)"
    INSTALLED="skipped (dry run)"
else
    log_info "installing dependencies"
    ( cd "$TARGET_DIR" && npm install )
    INSTALLED="yes"
fi

# Checked here too, not just in update.sh: a project that only ever
# runs init.sh and never update.sh again would otherwise get zero
# protection from this check. Not folded into SYNCED/UNCHANGED - right
# after a fresh scaffold these markers are expected to be missing,
# not drifted; this is a to-do reminder for this run, not an error.
# Skipped in a dry run: TARGET_DIR doesn't exist yet in that case
# (the scaffold step itself was skipped), so there's nothing to check.
if (( DRY_RUN )); then
    MARKER_MISSING_COUNT=0
    log_info "[DRY RUN] would check structural markers after applying"
else
    check_structural_markers "$PROFILE_DIR" "$TARGET_DIR"
fi

echo
echo "Summary:"
echo "  Profile:              $PROFILE"
echo "  Brought into parity: $SYNCED"
echo "  Already in sync:     $UNCHANGED"
echo "  Installed:            $INSTALLED"
echo "  Still to hand-author:  $MARKER_MISSING_COUNT (see warnings above)"
echo "  Log:                 $LOG_FILE"
if (( DRY_RUN )); then
    echo "  Mode:                 DRY RUN - no files were written. Re-run with --apply to write."
fi
