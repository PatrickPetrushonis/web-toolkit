#!/usr/bin/env bash
# Shared functions for the gh-pages-toolkit scripts (init.sh, update.sh,
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
    [[ -n "${!varname}" ]] && { echo "ERROR: $msg" >&2; exit 1; }
}

# Validates that MASTER_CONFIG and PROFILE (set by the caller's own
# argument parsing) are both present and resolve to a real profile
# directory, with a distinct error message for each of the four ways
# this can fail - missing --master-config, missing master config
# directory, missing --profile, or profile not found - rather than
# letting a later, less specific check catch an earlier problem
# transitively. Centralized here so init.sh, update.sh, and convert.sh
# share one implementation instead of three independent copies that
# can silently diverge from each other (Bash_Style_Guide §4). Sets
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
# (Bash_Style_Guide #2 - "v9" sorts after "v22" lexicographically).
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
    for field in scripts dependencies devDependencies; do
        local forced preserved
        forced="$(jq -s -r --arg f "$field" '
            (.[0][$f] // {}) as $t | (.[1][$f] // {}) as $m
            | ($m | keys[]) as $k
            | select(($t[$k] // null) != $m[$k])
            | "  \($f).\($k): \($t[$k] // "(none)") -> \($m[$k]) (forced to match master)"
        ' "$target_pkg" "$master_pkg")" || true
        [[ -n "$forced" ]] && while IFS= read -r line; do log_info "$line"; done <<< "$forced"

        preserved="$(jq -s -r --arg f "$field" '
            (.[0][$f] // {}) as $t | (.[1][$f] // {}) as $m
            | ($t | keys[]) as $k
            | select(($m[$k] // null) == null)
            | "  \($f).\($k): \($t[$k]) (child-only, preserved)"
        ' "$target_pkg" "$master_pkg")" || true
        [[ -n "$preserved" ]] && while IFS= read -r line; do log_info "$line"; done <<< "$preserved"
    done
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
# (Bash_Style_Guide §7). Must run before merge_package_json reads
# target's package.json, so a package being removed here is never also
# logged as "child-only, preserved" by report_package_changes in the
# same run. Sets SUPERSEDED_REMOVED_COUNT. Respects DRY_RUN.
remove_superseded_tooling() {
    local master_dir="$1" target_dir="$2"
    SUPERSEDED_REMOVED_COUNT=0
    local roles_file="${master_dir}/tool-roles.json"
    [[ -f "$roles_file" ]] || return

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
    done
}

# Merges master's package.json into target's: for scripts/dependencies/
# devDependencies, any key master declares is forced to master's exact
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
    merged="$(jq -s '
        .[0] as $target | .[1] as $master |
        $target
        | .scripts        = (($target.scripts // {})        + ($master.scripts // {}))
        | .dependencies    = (($target.dependencies // {})    + ($master.dependencies // {}))
        | .devDependencies = (($target.devDependencies // {}) + ($master.devDependencies // {}))
    ' "$target_pkg" "$master_pkg")"

    if diff -q <(jq -S . "$target_pkg") <(echo "$merged" | jq -S .) &>/dev/null; then
        MERGE_CHANGED=0
    else
        MERGE_CHANGED=1
    fi

    if (( DRY_RUN )); then
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
# for indirect function calls with no real gain (Bash_Style_Guide §4:
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
    [[ -f "$manifest" ]] || return
    jq empty "$manifest" || { log_error "manifest.json is not valid JSON: $manifest"; exit 1; }

    local has_markers
    has_markers="$(jq -r 'has("structural_markers")' "$manifest")"
    [[ "$has_markers" == "true" ]] || return

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
