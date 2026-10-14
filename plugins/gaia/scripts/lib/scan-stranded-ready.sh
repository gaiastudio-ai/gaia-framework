#!/usr/bin/env bash
# scan-stranded-ready.sh — stranded-ready scanner. Walks story files under IMPLEMENTATION_ARTIFACTS and
# emits one TSV row per story whose frontmatter has `status: ready-for-dev` AND
# `sprint_id: null` AND whose most-recent verdict entry in the validator-sidecar
# decision-log is PASSED.
#
# READ-ONLY: never mutates story files, sprint-status.yaml, decision-log.md, or
# any other artifact. Pure scan-and-print to stdout.
#
# Output (one row per match, sorted by story key ascending):
#   <story_key>\t<story_title>\t<story_path>
#
# Empty stdout = no matches (suppression signal for callers).
#
# Environment:
#   PROJECT_PATH             — project root (default ".")
#   IMPLEMENTATION_ARTIFACTS — story root (default "$PROJECT_ROOT/.gaia/artifacts/implementation-artifacts")
#   VALIDATOR_DECISION_LOG   — decision log path (default "$PROJECT_PATH/_memory/validator-sidecar/decision-log.md")
#
# Exit codes:
#   0 — scan completed (with or without matches)
#   1 — fatal scan error (rare; e.g., IMPLEMENTATION_ARTIFACTS missing)
#

set -euo pipefail
LC_ALL=C
export LC_ALL

PROJECT_PATH="${PROJECT_PATH:-.}"
PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_ROOT:-${PROJECT_PATH:-}}}"
# Smart-fallback for IMPLEMENTATION_ARTIFACTS
if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
  if [ -d "${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts" ]; then
    IMPLEMENTATION_ARTIFACTS="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/artifacts/implementation-artifacts"
  else
    IMPLEMENTATION_ARTIFACTS="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}docs/implementation-artifacts"
  fi
fi
if [ -z "${VALIDATOR_DECISION_LOG:-}" ]; then
  VALIDATOR_DECISION_LOG="${PROJECT_ROOT:+${PROJECT_ROOT%/}/}.gaia/memory/validator-sidecar/decision-log.md"
fi

# Silently degrade when the implementation-artifacts directory or the decision
# log is missing — empty output (no stranded stories) is the correct signal.
[[ -d "$IMPLEMENTATION_ARTIFACTS" ]] || exit 0
[[ -f "$VALIDATOR_DECISION_LOG" ]] || exit 0

# Parse a single story file's frontmatter for {status, sprint_id, title, key}.
# Emits 4 lines on stdout, one per field in fixed order, empty string when
# absent. Bash-only — no yq dependency (per Anti-patterns).
parse_story_fm() {
  local f="$1"
  awk '
    BEGIN { in_fm = 0; seen = 0; status=""; sprint_id=""; title=""; key="" }
    /^---[[:space:]]*$/ {
      if (!in_fm && !seen) { in_fm = 1; seen = 1; next }
      if (in_fm) { exit }
    }
    in_fm {
      if ($0 ~ /^[[:space:]]*status:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*status:[[:space:]]*/, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        status = v
      } else if ($0 ~ /^[[:space:]]*sprint_id:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*sprint_id:[[:space:]]*/, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        sprint_id = v
      } else if ($0 ~ /^[[:space:]]*title:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*title:[[:space:]]*/, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        title = v
      } else if ($0 ~ /^[[:space:]]*key:[[:space:]]*/) {
        v = $0
        sub(/^[[:space:]]*key:[[:space:]]*/, "", v)
        gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", v)
        key = v
      }
    }
    END {
      print status
      print sprint_id
      print title
      print key
    }
  ' "$f"
}

# Build a key-to-verdict map from the entire decision log in a single awk pass.
# Outputs lines of "key\tverdict". The log is ordered newest-first so the first
# occurrence of each key is the most-recent verdict; duplicates are suppressed.
_build_verdict_cache() {
  awk '
    BEGIN { current_key = ""; body = "" }
    /^### / {
      if (current_key != "" && !(current_key in seen)) {
        v = classify(body)
        print current_key "\t" v
        seen[current_key] = 1
      }
      current_key = ""
      body = ""
      heading = $0
      tmp = heading
      found = 0
      # Order matters: try re-run first (longer match) before plain validation.
      if (sub(/.*Story Validation \(re-run\): /, "", tmp)) found = 1
      else {
        tmp = heading
        if (sub(/.*Story Validation: /, "", tmp)) found = 1
        else {
          tmp = heading
          if (sub(/.*\/gaia-[A-Za-z0-9_-]+: /, "", tmp)) found = 1
        }
      }
      if (found) {
        sub(/[^A-Za-z0-9_-].*/, "", tmp)
        if (tmp ~ /^E[0-9]+-S[0-9]+$/) {
          current_key = tmp
          body = heading "\n"
        }
      }
      next
    }
    current_key != "" { body = body $0 "\n" }
    END {
      if (current_key != "" && !(current_key in seen)) {
        v = classify(body)
        print current_key "\t" v
        seen[current_key] = 1
      }
    }
    function classify(b,    has_passed, has_failed, has_unverified, has_recorded) {
      has_passed = 0; has_failed = 0; has_unverified = 0; has_recorded = 0
      if (index(b, "verdict\":\"PASSED\"") > 0) has_passed = 1
      else if (b ~ /verdict:[[:space:]]*PASSED/) has_passed = 1
      if (index(b, "verdict\":\"FAILED\"") > 0) has_failed = 1
      else if (b ~ /verdict:[[:space:]]*FAILED/) has_failed = 1
      if (index(b, "verdict\":\"UNVERIFIED\"") > 0) has_unverified = 1
      else if (b ~ /verdict:[[:space:]]*UNVERIFIED/) has_unverified = 1
      if (b ~ /\*?\*?Status:\*?\*?[[:space:]]+recorded/) has_recorded = 1
      if (b ~ /Result:[[:space:]]+PASS([^A-Z]|$)/) has_passed = 1
      if (b ~ /Result:[[:space:]]+FAIL/) has_failed = 1
      if (has_failed) return "FAILED"
      if (has_unverified) return "UNVERIFIED"
      if (has_passed) return "PASSED"
      if (has_recorded) return "PASSED"
      return "NONE"
    }
  ' "$VALIDATOR_DECISION_LOG"
}

# Build the verdict cache once (single awk pass over the entire decision log).
_verdict_cache=$(_build_verdict_cache)

# Two-stage candidate selection:
#   Stage 1 — find narrows to story.md (per-story dirs) and legacy E*-S*-*.md
#   Stage 2 — grep -l pre-selects only files containing 'status: ready-for-dev'
# Non-story markdown (review reports, assessments, etc.) is never opened.
# Collect candidate story files: ready-for-dev + sprint_id null + PASSED verdict.
matches=()
while IFS= read -r -d '' story_file; do
  [[ -n "$story_file" ]] || continue
  # parse frontmatter -> 4 lines: status, sprint_id, title, key
  fm=$(parse_story_fm "$story_file") || continue
  # Single multi-line read replaces four printf|sed fork pipelines.
  # || : on each read prevents set -e from aborting when a trailing field
  # is empty (command substitution strips trailing empty lines from awk output).
  {
    IFS= read -r status || :
    IFS= read -r sprint_id || :
    IFS= read -r title || :
    IFS= read -r key || :
  } <<< "$fm"

  [[ "$status" == "ready-for-dev" ]] || continue
  [[ "$sprint_id" == "null" ]] || continue
  [[ -n "$key" ]] || continue

  # Verdict lookup from pre-built cache (decision log is never re-read).
  # Pure bash string matching — zero forks per candidate.
  verdict=""
  case "$_verdict_cache" in
    "${key}"$'\t'*|*$'\n'"${key}"$'\t'*)
      local_match="${_verdict_cache#*"${key}"$'\t'}"
      verdict="${local_match%%$'\n'*}"
      ;;
  esac
  [[ "$verdict" == "PASSED" ]] || continue

  matches+=("$(printf '%s\t%s\t%s' "$key" "$title" "$story_file")")
done < <(find "$IMPLEMENTATION_ARTIFACTS" -type f \
  \( -name 'story.md' -o -name 'E[0-9]*-S[0-9]*-*.md' \) \
  -exec grep -l --null 'status: ready-for-dev' {} + 2>/dev/null || true)

# Sort by key ascending and emit.
if [[ ${#matches[@]} -gt 0 ]]; then
  printf '%s\n' "${matches[@]}" | LC_ALL=C sort -t$'\t' -k1,1
fi

exit 0
