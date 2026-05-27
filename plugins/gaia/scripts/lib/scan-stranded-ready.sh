#!/usr/bin/env bash
# scan-stranded-ready.sh — E81-S4
#
# Stranded-ready scanner. Walks story files under IMPLEMENTATION_ARTIFACTS and
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
#   IMPLEMENTATION_ARTIFACTS — story root (default "$PROJECT_PATH/.gaia/artifacts/implementation-artifacts")
#   VALIDATOR_DECISION_LOG   — decision log path (default "$PROJECT_PATH/_memory/validator-sidecar/decision-log.md")
#
# Exit codes:
#   0 — scan completed (with or without matches)
#   1 — fatal scan error (rare; e.g., IMPLEMENTATION_ARTIFACTS missing)
#
# Refs: AC1, AC4 (union heading matcher + most-recent wins), AC3 (read-only).

set -euo pipefail
LC_ALL=C
export LC_ALL

PROJECT_PATH="${PROJECT_PATH:-.}"
# E96-S7 partial-4b: smart-fallback
if [ -z "${IMPLEMENTATION_ARTIFACTS:-}" ]; then
  if [ -d "$PROJECT_PATH/.gaia/artifacts/implementation-artifacts" ]; then
    IMPLEMENTATION_ARTIFACTS="$PROJECT_PATH/.gaia/artifacts/implementation-artifacts"
  else
    IMPLEMENTATION_ARTIFACTS="$PROJECT_PATH/docs/implementation-artifacts"
  fi
fi
if [ -z "${VALIDATOR_DECISION_LOG:-}" ]; then
  # AF-2026-05-27-3 (ADR-111): canonical .gaia/memory only; legacy _memory removed.
  VALIDATOR_DECISION_LOG="$PROJECT_PATH/.gaia/memory/validator-sidecar/decision-log.md"
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

# Determine the most-recent verdict for a story key from the decision log.
# The log appends newest at the top — first match in document order is the
# canonical most-recent (per AC4 + Dev Notes).
#
# AC4 heading patterns matched (case-sensitive) for `<key>`:
#   ### [DATE] Story Validation: <key>
#   ### [DATE] Story Validation (re-run): <key>
#   ### [DATE] /gaia-<anything>: <key>
#
# The pattern allows trailing content after `<key>` (e.g., " (story title)")
# so log entries that append a human-readable suffix still match.
#
# After locating a heading, read forward up to a configurable window (default
# 30 lines or until the next `### ` heading, whichever comes first) and look
# for either:
#   verdict":"PASSED"   (canonical JSON-style payload)
#   verdict: PASSED     (prose convention)
#   Status: recorded    (older "recorded" prose — treated as PASSED only if
#                        no explicit FAILED/UNVERIFIED verdict is present)
#
# Echoes one of: PASSED, FAILED, UNVERIFIED, NONE
most_recent_verdict() {
  local key="$1"
  local log="$VALIDATOR_DECISION_LOG"
  # `awk` walks top-to-bottom (== newest-to-oldest). On first matching heading,
  # collect the body until the next `### ` heading, classify the verdict, and
  # exit.
  awk -v key="$key" '
    BEGIN {
      in_match = 0
      done = 0
      body = ""
    }
    done { next }
    /^### / {
      if (in_match) {
        # We just finished collecting the first matching block — classify
        # and freeze. END will print the captured result.
        done = 1
        next
      }
      heading = $0
      # Three union heading forms (case-sensitive, per AC4):
      #   ### [DATE] Story Validation: <key>
      #   ### [DATE] Story Validation (re-run): <key>
      #   ### [DATE] /gaia-<cmd>: <key>
      # Trailing content after <key> is allowed (e.g., " (story title)").
      if (match(heading, "(Story Validation: |Story Validation \\(re-run\\): |/gaia-[A-Za-z0-9_-]+: )" key "([^A-Za-z0-9_-]|$)")) {
        in_match = 1
        body = heading "\n"
        next
      }
    }
    in_match { body = body $0 "\n" }
    END {
      if (in_match) {
        print classify(body)
      } else {
        print "NONE"
      }
    }
    function classify(b,    has_passed, has_failed, has_unverified, has_recorded) {
      has_passed = 0; has_failed = 0; has_unverified = 0; has_recorded = 0
      # Canonical JSON-style verdict payload (written by val-sidecar-write.sh).
      if (index(b, "verdict\":\"PASSED\"") > 0) has_passed = 1
      else if (b ~ /verdict:[[:space:]]*PASSED/) has_passed = 1
      if (index(b, "verdict\":\"FAILED\"") > 0) has_failed = 1
      else if (b ~ /verdict:[[:space:]]*FAILED/) has_failed = 1
      if (index(b, "verdict\":\"UNVERIFIED\"") > 0) has_unverified = 1
      else if (b ~ /verdict:[[:space:]]*UNVERIFIED/) has_unverified = 1
      # Older prose convention from /gaia-validate-story:
      #   - **Status:** recorded
      #   - Status: recorded
      # The bold markup variant (**Status:**) requires tolerating arbitrary
      # markdown between `Status:` and `recorded`. We accept either plain or
      # markdown-decorated forms.
      if (b ~ /\*?\*?Status:\*?\*?[[:space:]]+recorded/) has_recorded = 1
      # Older "Result: PASS" / "Result: FAIL" prose convention (pre-canonical
      # verdict-line entries — common in early-2026 sprint logs).
      if (b ~ /Result:[[:space:]]+PASS([^A-Z]|$)/) has_passed = 1
      if (b ~ /Result:[[:space:]]+FAIL/) has_failed = 1
      # Explicit verdict wins. FAILED/UNVERIFIED dominate PASSED if both
      # appear in the same block (defensive; should not happen in
      # well-formed logs).
      if (has_failed) return "FAILED"
      if (has_unverified) return "UNVERIFIED"
      if (has_passed) return "PASSED"
      if (has_recorded) return "PASSED"
      return "NONE"
    }
  ' "$log"
}

# Collect candidate story files: ready-for-dev + sprint_id null.
matches=()
while IFS= read -r -d '' story_file; do
  # parse frontmatter -> 4 lines: status, sprint_id, title, key
  fm=$(parse_story_fm "$story_file") || continue
  status=$(printf '%s\n' "$fm" | sed -n '1p')
  sprint_id=$(printf '%s\n' "$fm" | sed -n '2p')
  title=$(printf '%s\n' "$fm" | sed -n '3p')
  key=$(printf '%s\n' "$fm" | sed -n '4p')

  [[ "$status" == "ready-for-dev" ]] || continue
  [[ "$sprint_id" == "null" ]] || continue
  [[ -n "$key" ]] || continue

  # Cross-reference verdict.
  verdict=$(most_recent_verdict "$key")
  [[ "$verdict" == "PASSED" ]] || continue

  matches+=("$(printf '%s\t%s\t%s' "$key" "$title" "$story_file")")
done < <(find "$IMPLEMENTATION_ARTIFACTS" -type f -name '*.md' -print0 2>/dev/null)

# Sort by key ascending and emit.
if [[ ${#matches[@]} -gt 0 ]]; then
  printf '%s\n' "${matches[@]}" | LC_ALL=C sort -t$'\t' -k1,1
fi

exit 0
