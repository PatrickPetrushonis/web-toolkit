#!/usr/bin/env bash
# Inventories a legacy gulp+nunjucks project into a structured JSON file
# intended as LLM conversion input, and scaffolds a new project skeleton
# via init.sh under whichever profile is specified. Does NOT attempt to
# auto-convert template content - see README.md for why.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: convert.sh --source <dir> --target <dir> --master-config <dir> --profile <name> [--apply]

  --source <dir>         Root of the legacy gulp+nunjucks project.
  --target <dir>         Where to scaffold the new project (must not
                          already exist - passed through to init.sh).
  --master-config <dir>  Directory holding profiles (expects
                          <dir>/profiles/<name>/), passed through to
                          init.sh. Exactly one - there is a single
                          source of truth, not a stack.
  --profile <name>        Which profile init.sh should apply to the
                          scaffolded target. Exactly one.
  --apply                Actually write the inventory file and scaffold
                          the target project. Without it, convert.sh
                          only reports what it would inventory.
EOF
}

SOURCE_DIR=""
TARGET_DIR=""
MASTER_CONFIG=""
PROFILE=""
DRY_RUN=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --target) TARGET_DIR="$2"; shift 2 ;;
        --master-config)
            reject_if_already_set MASTER_CONFIG "--master-config given more than once - exactly one master config, not a stack"
            MASTER_CONFIG="$2"; shift 2 ;;
        --profile)
            reject_if_already_set PROFILE "--profile given more than once - profiles are never mixed"
            PROFILE="$2"; shift 2 ;;
        --apply)   DRY_RUN=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -d "$SOURCE_DIR" ]] || { echo "ERROR: --source must be an existing directory" >&2; exit 1; }
[[ -z "$TARGET_DIR" ]] && { echo "ERROR: --target is required" >&2; exit 1; }
resolve_profile_dir

init_log_file "$(basename -- "$TARGET_DIR").convert.log"
# Locks on SOURCE_DIR, not TARGET_DIR: init.sh is invoked as a separate
# process at the end of this script and takes its own lock on
# TARGET_DIR. Locking the same target here first would make init.sh's
# own lock attempt fail every time, since this process would still be
# holding it. Locking SOURCE_DIR instead still prevents two concurrent
# conversions of the same legacy project from racing on template scans.
acquire_target_lock "$SOURCE_DIR"

# Finds every .njk/.nunjucks template under $1. Sets nothing; the
# caller reads the null-delimited stream directly.
find_templates() {
    find "$1" -type f \( -name '*.njk' -o -name '*.nunjucks' \) -print0
}

log_info "inventorying templates under: $SOURCE_DIR"

[[ -r "$SOURCE_DIR" ]] || { log_error "cannot read source directory: $SOURCE_DIR"; exit 1; }

TEMPLATE_COUNT=0
MACRO_DEFS=()
PAGE_RECORDS=()

# Grep-based extraction of {% extends %}, {% include %}, and
# {% macro %} - not a real nunjucks parser. Known limitation: a
# macro/include referenced via a computed or variable path (not a
# literal string) will not be found. Separately: the readability check
# above only catches SOURCE_DIR itself being unreadable - a permission
# error on a subdirectory discovered mid-walk by `find` still wouldn't
# trip set -e, since this loop reads via `< <(...)` (see the set -e
# caveat comment in lib/common.sh).
while IFS= read -r -d '' tpl; do
    TEMPLATE_COUNT=$((TEMPLATE_COUNT+1))
    rel="${tpl#"$SOURCE_DIR"/}"

    extends=""
    extends="$(grep -oP "(?<=\{% extends [\"'])[^\"']+" "$tpl" | head -1)" || true
    includes=""
    includes="$(grep -oP "(?<=\{% include [\"'])[^\"']+" "$tpl" | sort -u | tr '\n' ',' | sed 's/,$//')" || true
    macros=""
    macros="$(grep -oP "(?<=\{% macro )[a-zA-Z0-9_]+" "$tpl" | sort -u)" || true

    while IFS= read -r m; do
        [[ -n "$m" ]] && MACRO_DEFS+=("${m}|${rel}")
    done <<< "$macros"

    page_json="$(jq -n \
        --arg path "$rel" \
        --arg extends "$extends" \
        --arg includes "$includes" \
        '{path: $path, extends: $extends, includes: ($includes | select(. != "") | split(","))}')"
    PAGE_RECORDS+=("$page_json")
done < <(find_templates "$SOURCE_DIR")

# Macro usage count across all templates - the highest-value signal for
# LLM conversion, since a macro called from multiple templates is a de
# facto reusable component candidate.
SHARED_MACROS="[]"
if [[ ${#MACRO_DEFS[@]} -gt 0 ]]; then
    declare -A macro_names=()
    for entry in "${MACRO_DEFS[@]}"; do
        macro_names["${entry%%|*}"]=1
    done
    for name in "${!macro_names[@]}"; do
        usage_count="$(grep -rlP "\{%\s*(from\s+\S+\s+)?import\s+.*\b${name}\b|${name}\(" \
            --include='*.njk' --include='*.nunjucks' "$SOURCE_DIR" | wc -l)"
        SHARED_MACROS="$(echo "$SHARED_MACROS" | jq --arg name "$name" --argjson count "$usage_count" \
            '. + [{macro: $name, used_in_files: $count}]')"
    done
fi

INVENTORY_DIR="${SCRIPT_DIR}/../logs/inventory"
mkdir -p -- "$INVENTORY_DIR"
INVENTORY_FILE="$(cd "$INVENTORY_DIR" && pwd)/$(basename -- "$TARGET_DIR")_inventory.json"

inventory_json="$(jq -n \
    --argjson pages "$(printf '%s\n' "${PAGE_RECORDS[@]:-}" | jq -s '. - [null]')" \
    --argjson macros "$SHARED_MACROS" \
    '{pages: $pages, shared_macros: $macros}')"

if (( DRY_RUN )); then
    log_info "[DRY RUN] would write inventory ($TEMPLATE_COUNT templates found) to: $INVENTORY_FILE"
else
    echo "$inventory_json" | jq . > "$INVENTORY_FILE"
    log_info "wrote inventory ($TEMPLATE_COUNT templates) to: $INVENTORY_FILE"
fi

echo
echo "Summary:"
echo "  Templates found: $TEMPLATE_COUNT"
echo "  Shared macros:   $(echo "$SHARED_MACROS" | jq 'length')"
echo "  Inventory:       $INVENTORY_FILE"
echo "  Log:              $LOG_FILE"
echo
echo "This inventory is scaffolding + flagging, not automated conversion:"
echo "template content still needs to be ported by hand or fed to an LLM"
echo "conversion pass per-page using this inventory. See README.md."

if (( ! DRY_RUN )); then
    log_info "scaffolding target project via init.sh (profile: $PROFILE)"
    "${SCRIPT_DIR}/init.sh" --target "$TARGET_DIR" --master-config "$MASTER_CONFIG" --profile "$PROFILE" --apply
fi
