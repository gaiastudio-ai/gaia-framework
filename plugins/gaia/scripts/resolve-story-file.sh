#!/usr/bin/env bash
# resolve-story-file.sh — canonical story-file resolver
#
# Resolves a {story_key} to its on-disk path using a THREE-tier precedence rule
# (extends the two-tier rule):
#   0. New per-story nested layout: epic-{slug}/{story_key}-{story-slug}/story.md
#      (highest precedence; the directory name carries the key). New writes use
#      this form. Two guards keep tier-0 strictly the new layout: (a) any
#      candidate path containing a `/stories/` segment is excluded (that is the
#      legacy tier-1 layer — and since `find -path` lets `*` match `/`, the glob
#      alone would otherwise also traverse `epic-*/stories/E*-S*-*/` evidence
#      dirs), and (b) the directory basename is post-filtered on the
#      `{story_key}-` prefix BOUNDARY so requesting E28-S2 never matches
#      E28-S21-*.
#   1. Legacy nested: .gaia/artifacts/implementation-artifacts/epic-*/stories/{story_key}-*.md
#   2. Legacy flat fallback:  docs/implementation-artifacts/{story_key}-*.md (read-only,
#      with stderr WARNING "legacy-flat path — {flat_path} (migrate to the nested layout)")
#
# Precedence: per-story (0) > legacy-nested (1) > flat (2). When a higher tier
# resolves, lower-tier siblings for the same key are logged as ignored shadows
# (WARNING) and NOT returned. Existing files are NEVER migrated — read-compat only.
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
    # Prefer .gaia/artifacts/implementation-artifacts/ when present on disk;
    # fall back to legacy docs/ during the deprecation window.
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

    # 0. New per-story nested layout: the story's directory name carries the key —
    #    epic-{slug}/{key}-{story-slug}/story.md. This is the HIGHEST-precedence
    #    tier; new writes always use this form.
    #    Two guards keep tier-0 strictly the new layout:
    #      (a) the candidate path MUST NOT contain a `/stories/` segment — that is
    #          the legacy tier-1 layer, and since `find -path` lets `*` match `/`,
    #          the `epic-*/E*-S*-*/story.md` glob would otherwise also traverse
    #          `epic-*/stories/E*-S*-*/` evidence dirs;
    #      (b) the directory basename MUST begin with the `{story_key}-` PREFIX
    #          BOUNDARY so requesting E28-S2 never matches E28-S21-*.
    local perstory_matches=()
    while IFS= read -r -d '' path; do
        # (a) exclude any legacy stories/ segment — tier-0 is the new layout only.
        case "$path" in
            */stories/*) continue ;;
        esac
        # (b) {dir} basename must begin with exactly "{story_key}-" (boundary).
        local sdir
        sdir="$(basename "$(dirname "$path")")"
        case "$sdir" in
            "${story_key}-"*) perstory_matches+=("$path") ;;
        esac
    done < <(find "$impl_root" -type f -path "${impl_root%/}/epic-*/E*-S*-*/story.md" -print0 2>/dev/null)

    # 1. Canonical nested search: epic-*/stories/{key}-*.md — DIRECT children of
    #    a `stories/` dir only. The parent-basename guard prevents the glob (whose
    #    `*` spans `/`) from matching a deeper file such as
    #    `stories/{key}-evidence/story.md` (a per-story evidence dir), which is a
    #    tier-0 concern, not a legacy tier-1 story.
    local nested_matches=()
    while IFS= read -r -d '' path; do
        [[ "$(basename "$(dirname "$path")")" == "stories" ]] || continue
        nested_matches+=("$path")
    done < <(find "$impl_root" -type f -path "*/stories/${story_key}-*.md" -print0 2>/dev/null)

    # 2. Legacy flat search (non-recursive, immediate children only): {key}-*.md
    local flat_matches=()
    local f
    for f in "$impl_root"/"${story_key}"-*.md; do
        [[ -f "$f" ]] && flat_matches+=("$f")
    done

    local perstory_count=${#perstory_matches[@]}
    local nested_count=${#nested_matches[@]}
    local flat_count=${#flat_matches[@]}

    # New per-story layout takes precedence over BOTH legacy layers. Multi-match
    # is a misconfiguration the operator must resolve.
    if (( perstory_count > 1 )); then
        printf 'error: multiple per-story story files matched key %s — resolve ambiguity\n' "$story_key" >&2
        local m
        for m in "${perstory_matches[@]}"; do
            printf '  %s\n' "$m" >&2
        done
        return 2
    fi
    if (( perstory_count == 1 )); then
        if (( nested_count > 0 )); then
            local np
            for np in "${nested_matches[@]}"; do
                printf 'WARNING: legacy epic-*/stories shadow ignored — %s\n' "$np" >&2
            done
        fi
        if (( flat_count > 0 )); then
            local fp
            for fp in "${flat_matches[@]}"; do
                printf 'WARNING: legacy-flat shadow ignored — %s\n' "$fp" >&2
            done
        fi
        printf '%s\n' "${perstory_matches[0]}"
        return 0
    fi

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
        printf 'WARNING: legacy-flat path — %s (migrate to the nested layout)\n' "${flat_matches[0]}" >&2
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
