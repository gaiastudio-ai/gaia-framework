#!/usr/bin/env bash
# resolve-story-file.sh — canonical story-file resolver (E79-S7 / AF-2026-05-12-1, FR-476)
#
# Resolves a {story_key} to its on-disk path using the E79-S4 precedence rule:
#   1. Canonical nested path: .gaia/artifacts/implementation-artifacts/epic-*/stories/{story_key}-*.md
#   2. Legacy flat fallback:  docs/implementation-artifacts/{story_key}-*.md (read-only,
#      with stderr WARNING "legacy-flat path — {flat_path} (migrate via E79-S6)")
#
# If both exist for the same {story_key}, the nested file wins and the flat sibling is
# logged as "WARNING: legacy-flat shadow ignored — {flat_path}" and NOT returned.
#
# Exit codes:
#   0 - single match resolved; path written to stdout
#   1 - zero matches; actionable error on stderr
#   2 - multiple nested matches (ambiguity); both paths listed on stderr
#
# Usage:
#   source resolve-story-file.sh
#   resolve_story_file E85-S1
#   # OR as a CLI:
#   resolve-story-file.sh E85-S1
#
# Override $IMPLEMENTATION_ARTIFACTS to retarget the search root (defaults to
# .gaia/artifacts/implementation-artifacts/ relative to CWD).

resolve_story_file() {
    local story_key="${1:?usage: resolve_story_file <story_key>}"
    # E96-S6 (ADR-111): prefer .gaia/artifacts/implementation-artifacts/ when
    # present on disk; fall back to legacy docs/ during the deprecation window.
    # IMPLEMENTATION_ARTIFACTS env-var override wins over both.
    local impl_root
    if [[ -n "${IMPLEMENTATION_ARTIFACTS:-}" ]]; then
        impl_root="$IMPLEMENTATION_ARTIFACTS"
    elif [[ -d ".gaia/artifacts/implementation-artifacts" ]]; then
        impl_root=".gaia/artifacts/implementation-artifacts"
    else
        impl_root="docs/implementation-artifacts"
    fi

    if [[ ! -d "$impl_root" ]]; then
        printf 'error: implementation-artifacts root not found: %s\n' "$impl_root" >&2
        return 1
    fi

    # 1. Canonical nested search: epic-*/stories/{key}-*.md
    local nested_matches=()
    while IFS= read -r -d '' path; do
        nested_matches+=("$path")
    done < <(find "$impl_root" -type f -path "*/stories/${story_key}-*.md" -print0 2>/dev/null)

    # 2. Legacy flat search (non-recursive, immediate children only): {key}-*.md
    local flat_matches=()
    local f
    for f in "$impl_root"/"${story_key}"-*.md; do
        [[ -f "$f" ]] && flat_matches+=("$f")
    done

    local nested_count=${#nested_matches[@]}
    local flat_count=${#flat_matches[@]}

    # Multi-nested ambiguity: misconfiguration, operator must resolve
    if (( nested_count > 1 )); then
        printf 'error: multiple nested story files matched key %s — resolve ambiguity\n' "$story_key" >&2
        local m
        for m in "${nested_matches[@]}"; do
            printf '  %s\n' "$m" >&2
        done
        return 2
    fi

    # Nested wins (single hit); log flat shadows as ignored
    if (( nested_count == 1 )); then
        if (( flat_count > 0 )); then
            local fp
            for fp in "${flat_matches[@]}"; do
                printf 'WARNING: legacy-flat shadow ignored — %s\n' "$fp" >&2
            done
        fi
        printf '%s\n' "${nested_matches[0]}"
        return 0
    fi

    # No nested hit; fall back to flat with WARNING (read-only migration window)
    if (( flat_count == 1 )); then
        printf 'WARNING: legacy-flat path — %s (migrate via E79-S6)\n' "${flat_matches[0]}" >&2
        printf '%s\n' "${flat_matches[0]}"
        return 0
    fi

    if (( flat_count > 1 )); then
        printf 'error: multiple legacy-flat story files matched key %s — resolve ambiguity\n' "$story_key" >&2
        local m
        for m in "${flat_matches[@]}"; do
            printf '  %s\n' "$m" >&2
        done
        return 2
    fi

    # Zero matches at either layer
    printf 'error: story file not found for key %s — searched %s/epic-*/stories/%s-*.md and %s/%s-*.md\n' \
        "$story_key" "$impl_root" "$story_key" "$impl_root" "$story_key" >&2
    return 1
}

# CLI entry: when sourced, only the function is exposed; when executed directly,
# invoke the function with the first positional argument.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    resolve_story_file "$@"
fi
