#!/usr/bin/env bash
# Brings an existing project into exact parity with a single profile
# under a master config, and runs that profile's route parity check if
# it declares one. See README.md "Master/child relationship" for the
# zero-drift-per-profile policy this enforces.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: update.sh --master-config <dir> --profile <name> --target <dir> [--apply]

  --master-config <dir>  Directory holding profiles (expects
                          <dir>/profiles/<name>/). Exactly one - there
                          is a single source of truth, not a stack.
  --profile <name>        Which profile to enforce. Exactly one -
                          profiles are never mixed.
  --target <dir>         Existing project to check/update.
  --apply                Write the parity-enforcing changes instead of
                          only reporting what would change.
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
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: --target must be an existing directory" >&2; exit 1; }

init_log_file "$(basename -- "$TARGET_DIR").update.log"
acquire_target_lock "$TARGET_DIR"

IN_SYNC=0
DRIFTED=0

log_info "enforcing parity against profile: $PROFILE_DIR"
apply_master_config "$PROFILE_DIR" "$TARGET_DIR"
DRIFTED=$((DRIFTED + APPLY_CHANGED_COUNT))
IN_SYNC=$((IN_SYNC + APPLY_UNCHANGED_COUNT))

check_structural_markers "$PROFILE_DIR" "$TARGET_DIR"
DRIFTED=$((DRIFTED + MARKER_MISSING_COUNT))
IN_SYNC=$((IN_SYNC + MARKER_PRESENT_COUNT))

# Route parity check: static <Route path="..."> entries in App.tsx
# (excluding dynamic segments and the catch-all) versus the routes
# array in vite.config.ts. Grep-based, not a real JSX/TS parser -
# known limitation: a path split across multiple lines or built from a
# template literal won't match. Correct for the flat string-literal
# style this toolkit's own vite-react profile uses. Only meaningful for
# a profile that actually has App.tsx-style client routing at all -
# see the manifest.json check below, not a file-existence guess.
check_route_parity() {
    local app_tsx="$1" vite_config="$2"
    if [[ ! -f "$app_tsx" || ! -f "$vite_config" ]]; then
        log_warn "route parity check skipped - App.tsx or vite.config.ts not found"
        return
    fi
    local app_routes vite_routes only_in_app only_in_vite
    app_routes="$(grep -oP '(?<=path=")[^"]+' "$app_tsx" | grep -v ':' | grep -v '^\*$' | grep -v '^/$' | sed 's#^/##' | sort -u)" || true
    vite_routes="$(grep -oP "(?<=')[a-zA-Z0-9_-]+(?=')" "$vite_config" | sort -u)" || true
    only_in_app="$(comm -23 <(echo "$app_routes") <(echo "$vite_routes"))"
    only_in_vite="$(comm -13 <(echo "$app_routes") <(echo "$vite_routes"))"
    if [[ -n "$only_in_app" ]]; then
        log_warn "routes in App.tsx but missing from vite.config.ts routes array: $(echo "$only_in_app" | tr '\n' ' ')"
        DRIFTED=$((DRIFTED+1))
    fi
    if [[ -n "$only_in_vite" ]]; then
        log_warn "routes in vite.config.ts but not found as static routes in App.tsx: $(echo "$only_in_vite" | tr '\n' ' ')"
        DRIFTED=$((DRIFTED+1))
    fi
    if [[ -z "$only_in_app" && -z "$only_in_vite" ]]; then
        log_info "route parity check: in sync"
        IN_SYNC=$((IN_SYNC+1))
    fi
}

ROUTE_CHECK_TYPE_MANIFEST="${PROFILE_DIR}/manifest.json"
jq empty "$ROUTE_CHECK_TYPE_MANIFEST" || { log_error "manifest.json is not valid JSON: $ROUTE_CHECK_TYPE_MANIFEST"; exit 1; }
ROUTE_CHECK_TYPE="$(jq -r '.route_parity_check // "none"' "$ROUTE_CHECK_TYPE_MANIFEST")"
if [[ "$ROUTE_CHECK_TYPE" == "vite-react-spa" ]]; then
    check_route_parity "$TARGET_DIR/src/App.tsx" "$TARGET_DIR/vite.config.ts"
else
    log_info "route parity check not applicable for profile '$PROFILE' (route_parity_check: $ROUTE_CHECK_TYPE)"
fi

echo
echo "Summary:"
echo "  Profile:  $PROFILE"
echo "  In sync:  $IN_SYNC"
echo "  Drifted:  $DRIFTED  (see log for exactly which keys/files/routes)"
echo "  Log:      $LOG_FILE"
(( DRY_RUN )) && echo "  Mode:     DRY RUN - re-run with --apply to write config changes."
