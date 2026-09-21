#!/usr/bin/env bats
# yield-gate-auq.bats — the substrate user-question yield contract.
#
# The five yield boundaries halt the LLM turn via the substrate
# AskUserQuestion primitive rather than a stdout sentinel. The
# substrate-halt behaviour itself is only observable in a live
# `/gaia-meeting` run and is verified manually; what is checkable here is the
# static surface that makes it work:
#
#   - yield-gate.sh emits no yield-stop sentinel lines and no stdout at all
#   - yield-gate.sh still writes its session-state side effects
#   - yield-gate.sh accepts --side-effect-only (the default behaviour)
#   - the SKILL.md procedure documents an AskUserQuestion call at each of the
#     five yield boundaries, with no yield-stop tokens left behind

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  HELPER="$SKILL_DIR/scripts/yield-gate.sh"
  SESSION_HELPER="$SKILL_DIR/scripts/session-state.sh"
  SCANNER="$SKILL_DIR/scripts/stdout-sentinel-scan.sh"
  SKILL_MD="$SKILL_DIR/SKILL.md"

  TMP="$(mktemp -d)"
  SESSION_FILE="$TMP/2026-05-10-test.yaml"
}

teardown() {
  rm -rf "$TMP"
}

# --- AC7 — yield-gate.sh sentinel-emission removed ---------------------------

@test "the yield gate source contains no yield-stop sentinel literals" {
  count="$(grep -c '<<YIELD-STOP' "$HELPER" || true)"
  [ "$count" -eq 0 ]
}

@test "the yield gate produces no stdout on a default invocation" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-001" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-charter --session-id sess-auq-001
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the yield gate still writes the checkpoint phase and last-yield timestamp to session state" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-002" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-save --session-id sess-auq-002
  [ "$status" -eq 0 ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "pre-save" ]
  iso_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  [[ "$iso_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "the yield gate accepts --side-effect-only and behaves identically to the default" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-003" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase post-research --session-id sess-auq-003 --side-effect-only
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  phase_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)"
  [ "$phase_val" = "post-research" ]
}

@test "the yield gate writes the boundary, the re-entry phase and the timestamp" {
  "$SESSION_HELPER" create --file "$SESSION_FILE" --session-id "sess-auq-004" >/dev/null
  run env GAIA_MEETING_SESSION_FILE="$SESSION_FILE" "$HELPER" --phase pre-close --session-id sess-auq-004
  [ "$status" -eq 0 ]
  [ "$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_boundary)" = "pre-close" ]
  [ "$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_checkpoint_phase)" = "CLOSE" ]
  iso_val="$("$SESSION_HELPER" read --file "$SESSION_FILE" --field last_yield_emitted_at)"
  [[ "$iso_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# --- AC8 — SKILL.md procedure prose contains AskUserQuestion at 5 boundaries

# The SKILL.md §Procedure subsections at the 5 yield boundaries MUST each
# contain a documented AskUserQuestion call. We assert this by counting the
# number of yield-boundary subsection headers that have an AskUserQuestion
# reference within their body.

@test "the post-charter yield procedure references the user-question prompt" {
  # Match anywhere from "Post-CHARTER checkpoint yield" until the next ##/###
  # heading. Use awk for the subsection extraction.
  body="$(awk '
    /^### .*[Pp]ost-CHARTER/ || /[Pp]ost-CHARTER (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / && !/[Pp]ost-CHARTER/ { in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "the post-research yield procedure references the user-question prompt" {
  body="$(awk '
    /[Pp]ost-RESEARCH (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "the discuss-cadence yield procedure references the user-question prompt" {
  body="$(awk '
    /[Dd]iscuss-cadence|[Ee]very-N DISCUSS/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "the pre-close yield procedure references the user-question prompt" {
  body="$(awk '
    /[Pp]re-CLOSE (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "the pre-save yield procedure references the user-question prompt" {
  body="$(awk '
    /[Pp]re-SAVE (checkpoint )?yield/ { in_sect=1 }
    in_sect && /^### / { c++; if (c>1) in_sect=0 }
    in_sect { print }
  ' "$SKILL_MD")"
  echo "$body" | grep -F "AskUserQuestion"
}

@test "the procedure subsections contain no yield-stop tokens" {
  run "$SCANNER" "$SKILL_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
