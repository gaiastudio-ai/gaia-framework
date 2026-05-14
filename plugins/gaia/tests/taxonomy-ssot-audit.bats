#!/usr/bin/env bats
# taxonomy-ssot-audit.bats — SSOT discipline guard for closed-list taxonomies (E88-S1)
#
# Per ADR-107: the v1 taxonomy lists must NOT be reproduced (inlined) in other
# files. Individual words from the taxonomies appear naturally throughout the
# framework's prose (e.g., "the orchestrator invokes the agent tool", "this is
# deferred to next sprint") — those occurrences are legitimate and MUST NOT be
# flagged. What we guard against is FILES THAT REPRODUCE THE TAXONOMY LIST
# itself, which constitutes drift from the SSOT.
#
# Drift detection rule: a file outside the allowlist contains >= DRIFT_THRESHOLD
# DISTINCT v1 taxonomy entries with `grep -wF` semantics. The threshold is set
# above the number of entries any single-purpose doc would naturally use in
# prose (a SKILL.md might say "invokes" and "spawns" together when documenting
# orchestration — 2 entries is normal prose; 3+ together strongly suggests an
# inlined list).
#
# Allowlist rationale (per-file):
#   - knowledge/taxonomy/deferral-phrases.txt — SSOT data file (canonical).
#   - knowledge/taxonomy/dispatch-verbs.txt   — SSOT data file (canonical).
#   - scripts/lib/load-taxonomy.sh            — loader.
#   - scripts/lib/dispatch-verb-match.sh      — matcher.
#   - scripts/lib/deferral-phrase-match.sh    — matcher.
#   - tests/load-taxonomy.bats                — unit tests; reference all entries.
#   - tests/dispatch-verb-match.bats          — unit tests; reference all entries.
#   - tests/deferral-phrase-match.bats        — unit tests; reference all entries.
#   - tests/taxonomy-ssot-audit.bats          — this audit (itself).
#   - tests/intake-dispatch-verb-check.bats   — E88-S2 intake helper unit tests;
#                                               positive/negative fixtures reference
#                                               all dispatch verbs to exercise the
#                                               matcher via the shared library.
#   - scripts/lib/intake-dispatch-verb-check.sh — E88-S2 intake helper; sources
#                                                 the matcher library + has
#                                                 dispatch-verb references in
#                                                 header documentation prose.
#   - knowledge/adrs/ADR-107*.md              — ADR-107 prose if/when stored here.

load 'test_helper.bash'

DRIFT_THRESHOLD=3
export DRIFT_THRESHOLD

setup() {
  common_setup
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_DIR
}

teardown() {
  common_teardown
}

_allowed_paths_regex() {
  cat <<'EOF'
^knowledge/taxonomy/deferral-phrases\.txt$
^knowledge/taxonomy/dispatch-verbs\.txt$
^scripts/lib/load-taxonomy\.sh$
^scripts/lib/dispatch-verb-match\.sh$
^scripts/lib/deferral-phrase-match\.sh$
^tests/load-taxonomy\.bats$
^tests/dispatch-verb-match\.bats$
^tests/deferral-phrase-match\.bats$
^tests/taxonomy-ssot-audit\.bats$
^tests/intake-dispatch-verb-check\.bats$
^scripts/lib/intake-dispatch-verb-check\.sh$
^knowledge/adrs/ADR-107.*\.md$
EOF
}

# _is_allowlisted <relative_path> -> 0 if allowed, 1 otherwise.
_is_allowlisted() {
  local path="$1"
  local allowlist
  allowlist="$(_allowed_paths_regex)"
  while IFS= read -r rx; do
    [ -z "$rx" ] && continue
    if printf '%s\n' "$path" | grep -qE "$rx"; then
      return 0
    fi
  done <<<"$allowlist"
  return 1
}

# _offenders_for_taxonomy <name> -> prints "path<TAB>distinct_count" per
# non-allowlisted file that reproduces >= DRIFT_THRESHOLD distinct entries.
_offenders_for_taxonomy() {
  local taxonomy="$1"
  local grep_file
  grep_file="$("$PLUGIN_DIR/scripts/lib/load-taxonomy.sh" --taxonomy "$taxonomy" --as-grep-file)"

  # Find every candidate file the taxonomy could appear in.
  local candidates
  candidates="$(cd "$PLUGIN_DIR" && grep -rlwFf "$grep_file" . 2>/dev/null \
    | sed 's|^\./||' \
    | sort -u || true)"

  local offenders=""
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if _is_allowlisted "$path"; then
      continue
    fi
    # Count distinct taxonomy entries in this file.
    local distinct
    distinct="$(grep -wFof "$grep_file" "$PLUGIN_DIR/$path" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    if [ "${distinct:-0}" -ge "$DRIFT_THRESHOLD" ]; then
      offenders+="$path"$'\t'"$distinct"$'\n'
    fi
  done <<<"$candidates"

  rm -f "$grep_file"
  printf '%s' "$offenders"
}

# TC-DPD-6 — Audit detects inlined deferral-phrase drift (>=3 distinct entries
# in a single non-allowlisted file).
@test "TC-DPD-6: no inlined deferral-taxonomy lists outside allowlist" {
  local offenders
  offenders=$(_offenders_for_taxonomy deferral)
  if [ -n "$offenders" ]; then
    printf 'SSOT audit: deferral-phrase drift detected (>=%d distinct entries):\n%s\n' \
      "$DRIFT_THRESHOLD" "$offenders" >&2
    return 1
  fi
}

# TC-DPD-6 — Audit detects inlined dispatch-verb drift.
@test "TC-DPD-6: no inlined dispatch-taxonomy lists outside allowlist" {
  local offenders
  offenders=$(_offenders_for_taxonomy dispatch)
  if [ -n "$offenders" ]; then
    printf 'SSOT audit: dispatch-verb drift detected (>=%d distinct entries):\n%s\n' \
      "$DRIFT_THRESHOLD" "$offenders" >&2
    return 1
  fi
}

# TC-DPD-6 — Induce-then-detect: a synthetic violator must be flagged.
@test "TC-DPD-6: audit flags a synthetic inlined-taxonomy violator" {
  local fixture_dir="$PLUGIN_DIR/tests/fixtures"
  local fixture_path="$fixture_dir/inlined-taxonomy-violator-$$.md"
  mkdir -p "$fixture_dir"
  # Embed 3 distinct deferral entries in a single file — drift.
  cat > "$fixture_path" <<'FIX'
This file inlines the deferral taxonomy:
- not-yet-wired
- production wiring
- stub seam
FIX

  local offenders
  offenders=$(_offenders_for_taxonomy deferral)

  rm -f "$fixture_path"
  rmdir "$fixture_dir" 2>/dev/null || true

  case "$offenders" in
    *"inlined-taxonomy-violator-"*) : ;;  # detected — pass
    *)
      printf 'Expected audit to flag the synthetic violator; offenders were:\n%s\n' "$offenders" >&2
      return 1
      ;;
  esac
}

# Confirm 2 entries in a single file does NOT trigger drift (legitimate prose
# can mention up to DRIFT_THRESHOLD-1 entries naturally).
@test "TC-DPD-6: 2 distinct entries in prose is NOT flagged (under threshold)" {
  local fixture_dir="$PLUGIN_DIR/tests/fixtures"
  local fixture_path="$fixture_dir/legitimate-prose-$$.md"
  mkdir -p "$fixture_dir"
  cat > "$fixture_path" <<'FIX'
The orchestrator invokes and spawns sub-agents during dispatch. This is
normal prose mentioning two dispatch verbs in passing.
FIX

  local offenders
  offenders=$(_offenders_for_taxonomy dispatch)

  rm -f "$fixture_path"
  rmdir "$fixture_dir" 2>/dev/null || true

  case "$offenders" in
    *"legitimate-prose-"*)
      printf 'Audit false-positive: legitimate prose flagged.\nOffenders:\n%s\n' "$offenders" >&2
      return 1
      ;;
    *) : ;;  # not flagged — pass
  esac
}
