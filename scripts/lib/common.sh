#!/usr/bin/env bash
# Shared functions for the web-toolkit scripts (init.sh, update.sh,
# convert.sh). Sourced, not executed directly.
#
# Master/child policy (see README.md "Master/child relationship"): a
# profile (master-configs/base/profiles/<name>/) is the single source
# of truth for its category of project. For anything a profile
# declares, a child under that profile must match exactly - no
# per-child override, no layering, no drift. A child may still declare
# things its profile doesn't mention at all; those are preserved
# untouched. Profiles are never mixed - one is chosen per project, once,
# at init.sh time.
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: bash 4.0+ required (current: $BASH_VERSION)" >&2
    exit 1
fi

require() {
    command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found on PATH" >&2; exit 1; }
}
require node
require npm
require git
require jq
require flock
require sha256sum

# node_modules, dist, and git commits created by these scripts need to
# be owned by the invoking user, not root.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: do not run this with sudo, it creates files (node_modules, dist, git commits) a normal user needs to own." >&2
    exit 1
fi

# Callers set DRY_RUN before sourcing; default here only so an unset
# caller doesn't trip `set -u`. LOG_FILE is not defaulted here - every
# caller must call init_log_file (below) before the first log call.
: "${DRY_RUN:=1}"

# set -e caveat that applies throughout this file: a command's failure
# inside `< <(...)` (process substitution) is NOT visible to set -e the
# way `var="$(cmd)"` is - `var="$(cmd)"` trips set -e on failure (see
# merge_package_json's `jq -s` assignments below), but `done < <(cmd)`
# does not, even if cmd is the only thing that could reasonably fail.
# Anything read via `< <(...)` that can fail in a way worth catching
# needs its own explicit pre-check using a plain command, not an
# assumption that a bad input will halt the script (see
# remove_superseded_tooling's `jq empty` check and convert.sh's
# readability check before its `find_templates` read).

# Exits with an error if the named variable is already non-empty -
# used to reject a repeated --master-config/--profile flag. Takes the
# variable's name (not its value) so one helper covers both flags
# across all three scripts. Sets nothing.
reject_if_already_set() {
    local varname="$1" msg="$2"
    if [[ -n "${!varname}" ]]; then
        echo "ERROR: $msg" >&2
        exit 1
    fi
    return 0
}

# Validates that MASTER_CONFIG and PROFILE (set by the caller's own
# argument parsing) are both present and resolve to a real profile
# directory, with a distinct error message for each of the four ways
# this can fail - missing --master-config, missing master config
# directory, missing --profile, or profile not found - rather than
# letting a later, less specific check catch an earlier problem
# transitively. Centralized here so init.sh, update.sh, and convert.sh
# share one implementation instead of three independent copies that
# can silently diverge from each other (script_style_guide.md §3). Sets
# PROFILE_DIR. Callers must set MASTER_CONFIG and PROFILE before
# calling.
resolve_profile_dir() {
    [[ -z "$MASTER_CONFIG" ]] && { echo "ERROR: --master-config is required" >&2; exit 1; }
    [[ -d "$MASTER_CONFIG" ]] || { echo "ERROR: master config directory not found: $MASTER_CONFIG" >&2; exit 1; }
    [[ -z "$PROFILE" ]] && { echo "ERROR: --profile is required" >&2; exit 1; }
    PROFILE_DIR="${MASTER_CONFIG}/profiles/${PROFILE}"
    [[ -d "$PROFILE_DIR" ]] || { echo "ERROR: profile not found: $PROFILE_DIR" >&2; exit 1; }
}

# Resolves a path under <repo-root>/logs/ (one level above wherever the
# calling script lives, i.e. web/logs/ when the script is in
# web/scripts/), creating the directory if needed, and truncates it for
# a fresh run. Sets LOG_FILE. Requires SCRIPT_DIR to already be set by
# the caller before sourcing this file.
init_log_file() {
    local name="$1"
    local logs_dir="${SCRIPT_DIR}/../logs"
    mkdir -p -- "$logs_dir"
    LOG_FILE="$(cd "$logs_dir" && pwd)/${name}"
    : > "$LOG_FILE"
}

# Prints and appends a timestamped line to LOG_FILE. Sets nothing.
log() {
    local level="$1" msg="$2"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg"
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}
log_info()  { log "INFO"  "$1"; }
log_warn()  { log "WARN"  "$1"; }
log_error() { log "ERROR" "$1" >&2; }

# Takes a non-blocking flock scoped to TARGET, so two runs against the
# same target can't execute concurrently while runs against different
# targets never block each other. Hashes the canonicalized target path
# when it already exists, or its canonicalized parent directory plus
# basename when it doesn't yet (e.g. init.sh's target, which this same
# run creates) - so two different relative paths to the same target
# still collide on the same lock file. Known limitation: a target
# reached via a symlink that resolves elsewhere is not detected as the
# same target; this covers the common relative-path-variation case, not
# every possible path aliasing. Exits if another run already holds the
# lock. Requires SCRIPT_DIR to already be set. Sets LOCK_FILE and
# registers a trap to release it on exit.
acquire_target_lock() {
    local target="$1"
    local canonical
    if [[ -d "$target" ]]; then
        canonical="$(cd "$target" && pwd)"
    else
        local parent
        parent="$(cd "$(dirname -- "$target")" && pwd)" || {
            log_error "parent directory does not exist: $(dirname -- "$target")"
            exit 1
        }
        canonical="${parent}/$(basename -- "$target")"
    fi

    local lock_dir="${SCRIPT_DIR}/../logs/locks"
    mkdir -p -- "$lock_dir"
    local lock_hash
    lock_hash="$(printf '%s' "$canonical" | sha256sum | cut -d' ' -f1)"
    LOCK_FILE="${lock_dir}/${lock_hash}.lock"

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_error "another run is already active against: $target"
        exit 1
    fi
    trap 'rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT
}

# Extracts the numeric Node major version from `node -v` and compares
# it against MIN_MAJOR using arithmetic, never string comparison
# (script_style_guide.md §12 - "v9" sorts after "v22" lexicographically).
# Sets NODE_MAJOR. Exits the script if node is below MIN_MAJOR.
check_node_version() {
    local min_major="$1"
    NODE_MAJOR=""
    NODE_MAJOR="$(node -v | grep -oP '(?<=^v)[0-9]+')" || true
    if [[ -z "$NODE_MAJOR" ]]; then
        log_error "could not determine Node major version from 'node -v'"
        exit 1
    fi
    if (( NODE_MAJOR < min_major )); then
        log_error "Node ${min_major}+ required, found v${NODE_MAJOR}"
        exit 1
    fi
}

# Always brings dest into exact byte-for-byte parity with src - the
# master config always wins for these files, so there is no collision
# policy left to configure and no --force flag needed. Sets
# TEMPLATE_CHANGED (1 if dest didn't already match src, 0 if it was
# already in sync - so callers can tell parity-restored from
# already-in-parity). Respects DRY_RUN.
copy_template_file() {
    local src="$1" dest="$2"
    TEMPLATE_CHANGED=0
    if [[ ! -f "$src" ]]; then
        log_warn "template file not found in master config, skipping: $src"
        return
    fi
    if [[ -f "$dest" ]] && cmp -s -- "$src" "$dest"; then
        log_info "already in sync with master: $dest"
        return
    fi
    TEMPLATE_CHANGED=1
    if (( DRY_RUN )); then
        log_info "[DRY RUN] would bring into parity with master: $dest"
    else
        mkdir -p -- "$(dirname -- "$dest")"
        cp -- "$src" "$dest"
        log_info "brought into parity with master: $dest"
    fi
}

# Logs, per package.json field (scripts/dependencies/devDependencies),
# which keys master is about to force into parity (value differs from
# or is absent in target) versus which keys are child-only additions
# that will be preserved untouched. Read-only - does not write
# anything. Sets nothing.
report_package_changes() {
    local target_pkg="$1" master_pkg="$2"
    local field
    for field in $(jq -r '.[]' <<< "$MERGE_FIELDS_JSON"); do
        local ftype
        ftype="$(jq -r --arg f "$field" '.[$f] | type' "$master_pkg")"
        if [[ "$ftype" != "object" ]]; then
            local tval mval
            tval="$(jq -r --arg f "$field" '.[$f] // "(none)"' "$target_pkg")"
            mval="$(jq -r --arg f "$field" '.[$f] // "(none)"' "$master_pkg")"
            if [[ "$mval" != "(none)" && "$tval" != "$mval" ]]; then
                log_info "  ${field}: ${tval} -> ${mval} (forced to match master)"
            fi
            continue
        fi
        local forced preserved
        forced="$(jq -s -r --arg f "$field" '
            (.[0][$f] // {}) as $t | (.[1][$f] // {}) as $m
            | ($m | keys[]) as $k
            | select(($t[$k] // null) != $m[$k])
            | "  \($f).\($k): \($t[$k] // "(none)") -> \($m[$k]) (forced to match master)"
        ' "$target_pkg" "$master_pkg")" || true
        if [[ -n "$forced" ]]; then
            while IFS= read -r line; do log_info "$line"; done <<< "$forced"
        fi

        preserved="$(jq -s -r --arg f "$field" '
            (.[0][$f] // {}) as $t | (.[1][$f] // {}) as $m
            | ($t | keys[]) as $k
            | select(($m[$k] // null) == null)
            | "  \($f).\($k): \($t[$k]) (child-only, preserved)"
        ' "$target_pkg" "$master_pkg")" || true
        if [[ -n "$preserved" ]]; then
            while IFS= read -r line; do log_info "$line"; done <<< "$preserved"
        fi
    done
    return 0
}

# Reads master_dir/tool-roles.json (master_dir is a resolved profile
# directory - optional file, a no-op if it doesn't exist) and removes,
# from target, any package or config file that a role's
# superseded_packages/superseded_config_files lists.
# This exists to close a gap merge_package_json cannot: a competing
# tool under a different key name (e.g. "oxlint" when master's lint
# role is filled by "eslint") is invisible to a key-by-key merge, since
# nothing tells the merge that two different keys serve the same role.
# Keeping tool-roles.json current as new competing tools appear is an
# ongoing part of maintaining the master config, not a one-time setup
# step - a role/package/file not yet listed is not detected, the same
# way any keyword list only covers what has been added to it
# (script_style_guide.md §6). Must run before merge_package_json reads
# target's package.json, so a package being removed here is never also
# logged as "child-only, preserved" by report_package_changes in the
# same run. Sets SUPERSEDED_REMOVED_COUNT. Respects DRY_RUN.
remove_superseded_tooling() {
    local master_dir="$1" target_dir="$2"
    SUPERSEDED_REMOVED_COUNT=0
    local roles_file="${master_dir}/tool-roles.json"
    [[ -f "$roles_file" ]] || return 0

    jq empty "$roles_file" || {
        log_error "tool-roles.json is not valid JSON, skipping tool-role checks: $roles_file"
        exit 1
    }

    local role
    read_jq_array "$roles_file" 'keys[]'
    for role in "${MANIFEST_ARRAY[@]}"; do
        [[ -z "$role" ]] && continue

        local pkg
        read_jq_array "$roles_file" '.[$r].superseded_packages[]?' r "$role"
        for pkg in "${MANIFEST_ARRAY[@]}"; do
            [[ -z "$pkg" ]] && continue
            [[ -f "$target_dir/package.json" ]] || continue
            if jq -e --arg p "$pkg" '(.dependencies[$p] // .devDependencies[$p]) != null' \
                "$target_dir/package.json" >/dev/null 2>&1; then
                SUPERSEDED_REMOVED_COUNT=$((SUPERSEDED_REMOVED_COUNT+1))
                if (( DRY_RUN )); then
                    log_info "[DRY RUN] role '$role': would remove superseded package '$pkg' from $target_dir/package.json"
                else
                    local updated
                    updated="$(jq --arg p "$pkg" 'del(.dependencies[$p]?) | del(.devDependencies[$p]?)' "$target_dir/package.json")"
                    echo "$updated" | jq -S . > "$target_dir/package.json"
                    log_info "role '$role': removed superseded package '$pkg' from $target_dir/package.json"
                fi
            fi
        done

        local cfg
        read_jq_array "$roles_file" '.[$r].superseded_config_files[]?' r "$role"
        for cfg in "${MANIFEST_ARRAY[@]}"; do
            [[ -z "$cfg" ]] && continue
            if [[ -f "$target_dir/$cfg" ]]; then
                SUPERSEDED_REMOVED_COUNT=$((SUPERSEDED_REMOVED_COUNT+1))
                if (( DRY_RUN )); then
                    log_info "[DRY RUN] role '$role': would remove superseded config file '$cfg' from $target_dir"
                else
                    rm -f -- "$target_dir/$cfg"
                    log_info "role '$role': removed superseded config file '$cfg' from $target_dir"
                fi
            fi
        done

        remove_superseded_patterns "$roles_file" "$role" "$target_dir"
        remove_superseded_fields "$roles_file" "$role" "$target_dir"
        remove_superseded_scripts "$roles_file" "$role" "$target_dir" "$master_dir"
        warn_superseded_scripts "$roles_file" "$role" "$target_dir" "$master_dir"
    done
}

# Merges master's package.json into target's: for scripts/dependencies/
# devDependencies/engines, any key master declares is forced to master's exact
# value (no per-child override); any key present only in target is left
# untouched. Target's own name/version/private/type and any other
# top-level fields are preserved as-is - master never dictates those.
# Sets MERGE_CHANGED (1 if anything master declares differed from
# target's current value, 0 if package.json was already at parity).
# Respects DRY_RUN.
merge_package_json() {
    local master_pkg="$1" target_pkg="$2"
    MERGE_CHANGED=0
    if [[ ! -f "$target_pkg" ]]; then
        log_error "target package.json not found: $target_pkg"
        exit 1
    fi

    report_package_changes "$target_pkg" "$master_pkg"

    local merged
    merged="$(jq -s --argjson fields "$MERGE_FIELDS_JSON" '
        .[0] as $target | .[1] as $master |
        reduce $fields[] as $f ($target;
            if $master[$f] == null then .
            elif ($master[$f] | type) == "object" then .[$f] = ((.[$f] // {}) + $master[$f])
            else .[$f] = $master[$f]
            end)
    ' "$target_pkg" "$master_pkg")"

    if diff -q <(jq -S . "$target_pkg") <(echo "$merged" | jq -S .) &>/dev/null; then
        MERGE_CHANGED=0
    else
        MERGE_CHANGED=1
    fi

    if (( ! MERGE_CHANGED )); then
        log_info "already in sync with master: $target_pkg"
    elif (( DRY_RUN )); then
        log_info "[DRY RUN] would bring package.json into parity with master: $target_pkg"
    else
        echo "$merged" | jq -S . > "$target_pkg"
        log_info "brought package.json into parity with master: $target_pkg"
    fi
}

# Applies a profile to a target project: removes any tooling superseded
# per the profile's tool-roles.json (remove_superseded_tooling), brings
# package.json's scripts/dependencies/devDependencies into parity
# (merge_package_json), and then reads the profile's manifest.json to
# find out which other files to enforce. manifest.json's "always_copy"
# list is brought to exact parity via copy_template_file, same mechanism
# as before, just profile-declared instead of hardcoded - a profile
# with a different baseline file set (e.g. astro-static needing no
# vite.config.ts-equivalent copied at all, or needing an extra one)
# doesn't require a code change here, only a different manifest.json.
# manifest.json's "hand_authored" list gets only a warning, never
# copied - these are files that always mix structural and
# instance-specific concerns (vite.config.ts, astro.config.mjs, a
# content-collection schema) and are reviewed by hand every time,
# profile or not. profile_dir must contain manifest.json - there is no
# implicit default file set once profiles exist, so a profile without
# one is a configuration error, not a fallback case. Called identically
# from init.sh and update.sh, both of which resolve PROFILE_DIR
# themselves and pass it here as master_dir. Sets APPLY_CHANGED_COUNT
# and APPLY_UNCHANGED_COUNT across everything touched. A target
# package.json that doesn't exist yet is tolerated only when DRY_RUN is
# set (e.g. init.sh checking before the scaffold has run); otherwise
# it's an error. Respects DRY_RUN via the functions it calls.
apply_master_config() {
    local master_dir="$1" target_dir="$2"
    APPLY_CHANGED_COUNT=0
    APPLY_UNCHANGED_COUNT=0

    load_merge_fields "$master_dir"
    remove_superseded_tooling "$master_dir" "$target_dir"
    APPLY_CHANGED_COUNT=$((APPLY_CHANGED_COUNT + SUPERSEDED_REMOVED_COUNT))

    if [[ -f "$master_dir/package.json" ]]; then
        if [[ -f "$target_dir/package.json" ]]; then
            merge_package_json "$master_dir/package.json" "$target_dir/package.json"
            if (( MERGE_CHANGED )); then
                APPLY_CHANGED_COUNT=$((APPLY_CHANGED_COUNT+1))
            else
                APPLY_UNCHANGED_COUNT=$((APPLY_UNCHANGED_COUNT+1))
            fi
        elif (( DRY_RUN )); then
            log_info "[DRY RUN] target package.json does not exist yet - would bring into parity with master once it does"
        else
            log_error "target package.json not found: $target_dir/package.json"
            exit 1
        fi
    fi

    local manifest="${master_dir}/manifest.json"
    if [[ ! -f "$manifest" ]]; then
        log_error "manifest.json not found in profile: $master_dir"
        exit 1
    fi
    jq empty "$manifest" || {
        log_error "manifest.json is not valid JSON: $manifest"
        exit 1
    }

    local f
    read_jq_array "$manifest" '.always_copy[]?'
    for f in "${MANIFEST_ARRAY[@]}"; do
        copy_template_file "$master_dir/$f" "$target_dir/$f"
        if (( TEMPLATE_CHANGED )); then
            APPLY_CHANGED_COUNT=$((APPLY_CHANGED_COUNT+1))
        else
            APPLY_UNCHANGED_COUNT=$((APPLY_UNCHANGED_COUNT+1))
        fi
    done

    read_jq_array "$manifest" '.hand_authored[]?'
    for f in "${MANIFEST_ARRAY[@]}"; do
        if [[ -f "$master_dir/$f" ]]; then
            log_warn "$f found in profile - review and copy manually, not auto-applied by this script"
        fi
    done
}

# Reads JQ_FILTER's results from FILE into the global array
# MANIFEST_ARRAY (one array element per non-empty result line).
# Requires the caller to have already validated FILE with `jq empty`.
# ARG_NAME/ARG_VALUE are optional; when given, they're passed to jq as
# --arg ARG_NAME ARG_VALUE, for a filter that needs one substituted
# variable (e.g. a role name looked up per-iteration). This exists so
# every jq-array-into-bash read in this file (manifest.json's
# always_copy/hand_authored/structural_markers-keys, and
# tool-roles.json's per-role package/config-file lists) shares one
# place that does it, rather than each repeating its own
# `< <(jq -r ...)` process-substitution read (the construct this
# file's set -e caveat comment warns about). The per-item logic at
# each call site stays separate on purpose - copy-and-count, warn-only,
# grep-and-count, and tool removal are different enough operations
# that forcing them through one dispatcher would trade readable loops
# for indirect function calls with no real gain (script_style_guide.md §3:
# don't force an abstraction when the duplication itself is cheaper
# than the abstraction). Sets MANIFEST_ARRAY.
read_jq_array() {
    local file="$1" jq_filter="$2" arg_name="${3:-}" arg_value="${4:-}"
    MANIFEST_ARRAY=()
    local item
    if [[ -n "$arg_name" ]]; then
        while IFS= read -r item; do
            [[ -z "$item" ]] && continue
            MANIFEST_ARRAY+=("$item")
        done < <(jq -r --arg "$arg_name" "$arg_value" "$jq_filter" "$file")
    else
        while IFS= read -r item; do
            [[ -z "$item" ]] && continue
            MANIFEST_ARRAY+=("$item")
        done < <(jq -r "$jq_filter" "$file")
    fi
}

# Reads the resolved profile's manifest.json "structural_markers" map
# (optional field - a no-op if the profile doesn't define one) and
# checks that each listed hand_authored file still contains its
# expected marker string in the target. This does not diff the whole
# file - that would reintroduce the rigidity profiles exist to avoid
# for a file that's supposed to be legitimately customized per
# project. It only checks that whatever structural piece is actually
# required is still present, so "this file was never hand-authored at
# all, still the scaffold default" is distinguishable from "this file
# was customized and is fine." Called from both init.sh and update.sh:
# init.sh treats a missing marker as an expected to-do reminder on a
# fresh scaffold, not an error, while update.sh folds it into its
# drift count, since by then the review should already have happened.
# Sets MARKER_PRESENT_COUNT and MARKER_MISSING_COUNT. Read-only;
# unaffected by DRY_RUN.
check_structural_markers() {
    local profile_dir="$1" target_dir="$2"
    MARKER_PRESENT_COUNT=0
    MARKER_MISSING_COUNT=0
    local manifest="${profile_dir}/manifest.json"
    [[ -f "$manifest" ]] || return 0
    jq empty "$manifest" || { log_error "manifest.json is not valid JSON: $manifest"; exit 1; }

    local has_markers
    has_markers="$(jq -r 'has("structural_markers")' "$manifest")"
    [[ "$has_markers" == "true" ]] || return 0

    local file
    read_jq_array "$manifest" '.structural_markers | keys[]?'
    for file in "${MANIFEST_ARRAY[@]}"; do
        local marker
        marker="$(jq -r --arg f "$file" '.structural_markers[$f] // empty' "$manifest")"
        [[ -z "$marker" ]] && continue
        if [[ ! -f "$target_dir/$file" ]]; then
            log_warn "cannot check structural marker, file missing: $target_dir/$file"
            continue
        fi
        if grep -q -- "$marker" "$target_dir/$file"; then
            log_info "structural marker present in $file: '$marker'"
            MARKER_PRESENT_COUNT=$((MARKER_PRESENT_COUNT+1))
        else
            log_warn "structural marker MISSING from $file: expected '$marker' - this file may still be the scaffold default, not yet hand-authored per the profile (see README 'Hand-authored files are never auto-applied')"
            MARKER_MISSING_COUNT=$((MARKER_MISSING_COUNT+1))
        fi
    done
}

# --- fold additions (web_toolkit_fold.sh) ---------------------------------
# Defaults for manifest-driven package.json merging. A profile's
# manifest.json may declare "merge_fields"; without it the merge covers
# exactly the three fields it always did. Sets MERGE_FIELDS_JSON.
: "${MERGE_FIELDS_JSON:=[\"scripts\",\"dependencies\",\"devDependencies\"]}"

load_merge_fields() {
    local manifest="${1}/manifest.json" declared
    MERGE_FIELDS_JSON='["scripts","dependencies","devDependencies"]'
    [[ -f "$manifest" ]] || return 0
    jq empty "$manifest" || { log_error "manifest.json is not valid JSON: $manifest"; exit 1; }
    declared="$(jq -c '.merge_fields // empty' "$manifest")"
    if [[ -n "$declared" ]]; then
        MERGE_FIELDS_JSON="$declared"
    fi
    return 0
}

# Role keys read by the three functions below, all optional per role in
# tool-roles.json (absent means a no-op):
#   superseded_package_patterns  regexes matched against dependency and
#                                devDependency names (jq test(); names
#                                already in superseded_packages are skipped)
#   superseded_package_json_fields  top-level package.json fields removed
#   review_script_patterns       regexes matched against the child's own
#                                scripts; a match is a warning only, since
#                                the script may be intentional. Scripts the
#                                profile itself declares are skipped (the
#                                merge overwrites them). Sets nothing.
# The first two add to SUPERSEDED_REMOVED_COUNT. All respect DRY_RUN.
remove_superseded_patterns() {
    local roles_file="$1" role="$2" target_dir="$3"
    [[ -f "$target_dir/package.json" ]] || return 0
    read_jq_array "$roles_file" '.[$r].superseded_package_patterns[]?' r "$role"
    local patterns=("${MANIFEST_ARRAY[@]}")
    local re name matched updated
    for re in "${patterns[@]}"; do
        [[ -z "$re" ]] && continue
        jq -n --arg re "$re" '"" | test($re)' >/dev/null 2>&1 || {
            log_error "invalid regex in tool-roles.json (role '$role'): $re"
            exit 1
        }
        matched="$(jq -r --arg re "$re" '((.dependencies // {}) + (.devDependencies // {})) | keys[] | select(test($re))' "$target_dir/package.json")"
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if jq -e --arg r "$role" --arg n "$name" '(.[$r].superseded_packages // []) | index($n) != null' "$roles_file" >/dev/null 2>&1; then
                continue
            fi
            SUPERSEDED_REMOVED_COUNT=$((SUPERSEDED_REMOVED_COUNT+1))
            if (( DRY_RUN )); then
                log_info "[DRY RUN] role '$role': would remove superseded package '$name' (matches /$re/) from $target_dir/package.json"
            else
                updated="$(jq --arg p "$name" 'del(.dependencies[$p]?) | del(.devDependencies[$p]?)' "$target_dir/package.json")"
                echo "$updated" | jq -S . > "$target_dir/package.json"
                log_info "role '$role': removed superseded package '$name' (matches /$re/) from $target_dir/package.json"
            fi
        done <<< "$matched"
    done
    return 0
}

remove_superseded_fields() {
    local roles_file="$1" role="$2" target_dir="$3"
    [[ -f "$target_dir/package.json" ]] || return 0
    read_jq_array "$roles_file" '.[$r].superseded_package_json_fields[]?' r "$role"
    local fields=("${MANIFEST_ARRAY[@]}")
    local field updated
    for field in "${fields[@]}"; do
        [[ -z "$field" ]] && continue
        jq -e --arg f "$field" 'has($f)' "$target_dir/package.json" >/dev/null 2>&1 || continue
        SUPERSEDED_REMOVED_COUNT=$((SUPERSEDED_REMOVED_COUNT+1))
        if (( DRY_RUN )); then
            log_info "[DRY RUN] role '$role': would remove superseded package.json field '$field' from $target_dir/package.json"
        else
            updated="$(jq --arg f "$field" 'del(.[$f])' "$target_dir/package.json")"
            echo "$updated" | jq -S . > "$target_dir/package.json"
            log_info "role '$role': removed superseded package.json field '$field' from $target_dir/package.json"
        fi
    done
    return 0
}

warn_superseded_scripts() {
    local roles_file="$1" role="$2" target_dir="$3" master_dir="$4"
    [[ -f "$target_dir/package.json" ]] || return 0
    read_jq_array "$roles_file" '.[$r].review_script_patterns[]?' r "$role"
    local patterns=("${MANIFEST_ARRAY[@]}")
    local master_scripts="{}"
    if [[ -f "$master_dir/package.json" ]]; then
        master_scripts="$(jq -c '.scripts // {}' "$master_dir/package.json")"
    fi
    local re hits line
    for re in "${patterns[@]}"; do
        [[ -z "$re" ]] && continue
        hits="$(jq -r --arg re "$re" --argjson ms "$master_scripts" '(.scripts // {}) | to_entries[] | select($ms[.key] == null) | select(.value | test($re)) | "\(.key): \(.value)"' "$target_dir/package.json")"
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                log_warn "role '$role': script mentions /$re/, review by hand - $line"
            fi
        done <<< "$hits"
    done
    return 0
}

# Manifest checks run by update.sh after the profile is applied. All are
# optional manifest fields (absent means a no-op) and read-only.
#   requires_files   files the target must have for the profile to work
#                    (e.g. package-lock.json, since the workflow runs
#                    npm ci). Sets REQUIRED_MISSING_COUNT; counted as drift.
#   review_patterns  [{file, pattern, message}]: a warning when the
#                    target's file matches the ERE pattern. Not drift.
check_required_files() {
    local profile_dir="$1" target_dir="$2"
    REQUIRED_MISSING_COUNT=0
    local manifest="${profile_dir}/manifest.json" f
    [[ -f "$manifest" ]] || return 0
    read_jq_array "$manifest" '.requires_files[]?'
    local files=("${MANIFEST_ARRAY[@]}")
    for f in "${files[@]}"; do
        [[ -z "$f" ]] && continue
        if [[ -f "$target_dir/$f" ]]; then
            log_info "required file present: $f"
        else
            log_warn "required file MISSING: $f (required by profile '$PROFILE')"
            REQUIRED_MISSING_COUNT=$((REQUIRED_MISSING_COUNT+1))
        fi
    done
    return 0
}

check_review_patterns() {
    local profile_dir="$1" target_dir="$2"
    local manifest="${profile_dir}/manifest.json" entry file pattern message
    [[ -f "$manifest" ]] || return 0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        file="$(jq -r '.file' <<< "$entry")"
        pattern="$(jq -r '.pattern' <<< "$entry")"
        message="$(jq -r '.message // "review by hand"' <<< "$entry")"
        [[ -f "$target_dir/$file" ]] || continue
        if grep -qE -- "$pattern" "$target_dir/$file"; then
            log_warn "$file matches /$pattern/: $message"
        fi
    done < <(jq -c '.review_patterns[]?' "$manifest")
    return 0
}

# Compares the target's default branch with the manifest's "deploy_branch"
# (the branch the profile's workflow triggers on). Default branch is
# origin/HEAD, else the checked-out branch. Skipped, with a log line, when
# the manifest declares none, the target is not a git work tree, or the
# branch cannot be determined. Sets DEPLOY_BRANCH_MISMATCH (0 or 1).
check_deploy_branch() {
    local profile_dir="$1" target_dir="$2"
    DEPLOY_BRANCH_MISMATCH=0
    local manifest="${profile_dir}/manifest.json" expected actual
    [[ -f "$manifest" ]] || return 0
    expected="$(jq -r '.deploy_branch // empty' "$manifest")"
    [[ -n "$expected" ]] || return 0
    if ! git -C "$target_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_info "deploy branch check skipped: target is not a git work tree"
        return 0
    fi
    actual="$(git -C "$target_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || actual=""
    actual="${actual#origin/}"
    if [[ -z "$actual" ]]; then
        actual="$(git -C "$target_dir" branch --show-current 2>/dev/null)" || actual=""
    fi
    if [[ -z "$actual" ]]; then
        log_warn "deploy branch check skipped: could not determine the target's default branch"
        return 0
    fi
    if [[ "$actual" == "$expected" ]]; then
        log_info "deploy branch matches profile: $expected"
    else
        log_warn "target's default branch is '$actual' but profile '$PROFILE' deploys from '$expected'; the workflow would never trigger"
        DEPLOY_BRANCH_MISMATCH=1
    fi
    return 0
}

# Sets TARGET_DIRTY to 1 when the target (path-limited, so a project inside
# a larger repo ignores its siblings) has uncommitted or untracked changes.
check_clean_tree() {
    local target_dir="$1"
    TARGET_DIRTY=0
    git -C "$target_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    if [[ -n "$(git -C "$target_dir" status --porcelain -- . 2>/dev/null)" ]]; then
        TARGET_DIRTY=1
    fi
    return 0
}

# Writes logs/backups/<name>-<timestamp>.tar.gz of the target, leaving out
# node_modules, dist and .git. Sets BACKUP_FILE.
backup_target() {
    local target_dir="$1"
    local backups_dir="${SCRIPT_DIR}/../logs/backups"
    mkdir -p -- "$backups_dir"
    local canonical base
    canonical="$(cd "$target_dir" && pwd)"
    base="$(basename -- "$canonical")"
    BACKUP_FILE="$(cd "$backups_dir" && pwd)/${base}-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$BACKUP_FILE" --exclude=node_modules --exclude=dist --exclude=.git \
        -C "$(dirname -- "$canonical")" "$base"
}

# --- fold additions 2 (superseded scripts) --------------------------------
# Role key superseded_scripts: exact names of the child's scripts removed
# when a role replaces the tooling they drive (the old branch-deploy hooks
# "predeploy" and "deploy"). Each removal logs the script's command. Scripts
# the profile itself declares are skipped. Adds to SUPERSEDED_REMOVED_COUNT;
# respects DRY_RUN.
remove_superseded_scripts() {
    local roles_file="$1" role="$2" target_dir="$3" master_dir="$4"
    [[ -f "$target_dir/package.json" ]] || return 0
    read_jq_array "$roles_file" '.[$r].superseded_scripts[]?' r "$role"
    local names=("${MANIFEST_ARRAY[@]}")
    local name value updated
    for name in "${names[@]}"; do
        [[ -z "$name" ]] && continue
        if [[ -f "$master_dir/package.json" ]] && jq -e --arg n "$name" '(.scripts // {}) | has($n)' "$master_dir/package.json" >/dev/null 2>&1; then
            continue
        fi
        value="$(jq -r --arg n "$name" '.scripts[$n] // empty' "$target_dir/package.json")"
        [[ -n "$value" ]] || continue
        SUPERSEDED_REMOVED_COUNT=$((SUPERSEDED_REMOVED_COUNT+1))
        if (( DRY_RUN )); then
            log_info "[DRY RUN] role '$role': would remove superseded script '$name' ($value) from $target_dir/package.json"
        else
            updated="$(jq --arg n "$name" 'del(.scripts[$n])' "$target_dir/package.json")"
            echo "$updated" | jq -S . > "$target_dir/package.json"
            log_info "role '$role': removed superseded script '$name' ($value) from $target_dir/package.json"
        fi
    done
    return 0
}

# --- target_name (web_toolkit_patch_target_name.sh) ------------------------
# Prints the basename of the target's canonical path, so `--target .` or
# `--target ..` names logs after the directory instead of ".". Works for a
# target that does not exist yet (init.sh), using the name as given.
target_name() {
    local target="$1"
    if [[ -d "$target" ]]; then
        basename -- "$(cd "$target" && pwd)"
    else
        basename -- "$target"
    fi
}
