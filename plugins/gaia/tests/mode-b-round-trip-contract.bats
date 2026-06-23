#!/usr/bin/env bats
# mode-b-round-trip-contract.bats — pins the shared Mode B teammate round-trip
# contract and the references to it from the four cohort bridges and the
# non-meeting Mode-B-ready SKILL.md files.
#
# Background: only /gaia-meeting carried the orchestrator-driven SendMessage
# round-trip inline; the other Mode-B-ready commands declared readiness through
# their bridge but their procedures never told the orchestrator to drive the
# per-turn round-trip. The fix introduces ONE canonical contract doc and points
# every bridge + every non-meeting Mode-B-ready SKILL.md at it.
#
# The LIVE round-trip (background Agent + the team message primitive) is
# orchestrator-runtime and is NOT bats-coverable — this suite asserts the
# static contract text and references only.

bats_require_minimum_version 1.5.0

setup() {
  PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CONTRACT="$PLUGIN_DIR/knowledge/mode-b-round-trip-contract.md"
  SKILLS_DIR="$PLUGIN_DIR/skills"
  LIB_DIR="$PLUGIN_DIR/scripts/lib"

  BRIDGES=(
    "$LIB_DIR/conversational-mode-b-bridge.sh"
    "$LIB_DIR/planning-mode-b-bridge.sh"
    "$LIB_DIR/execution-mode-b-bridge.sh"
    "$LIB_DIR/research-mode-b-bridge.sh"
  )
}

# The set of non-meeting Mode-B-ready skills: every skill whose SKILL.md has a
# Mode B Readiness section, minus gaia-meeting (which carries the full round-trip
# inline and is exempt by design).
_non_meeting_ready_skills() {
  grep -rl "Mode B Readiness" "$SKILLS_DIR" \
    | grep -v "/gaia-meeting/" \
    | sort -u
}

# --- AC1: the canonical contract doc exists and states the loop -------------

@test "canonical round-trip contract doc exists (AC1)" {
  [ -f "$CONTRACT" ]
}

@test "contract doc states the SEND step uses a real SendMessage (AC1)" {
  grep -qF "SendMessage(to:" "$CONTRACT"
}

@test "contract doc mandates the reply-routing reminder (AC1)" {
  grep -qiF "reply-routing reminder" "$CONTRACT"
  grep -qF "SendMessage(to: \"team-lead\")" "$CONTRACT"
}

@test "contract doc states the RECEIVE step is not a bash poll (AC1)" {
  grep -qiF "relay-pending state query" "$CONTRACT"
  grep -qiF "never fabricate" "$CONTRACT"
}

@test "contract doc states MODE_B_FALLBACK is the only legitimate fall-through (AC1)" {
  grep -qF "MODE_B_FALLBACK" "$CONTRACT"
  grep -qiF "only legitimate" "$CONTRACT"
}

@test "contract doc carries the cross-turn-boundary note (AC1)" {
  grep -qiF "turn boundary" "$CONTRACT"
}

# --- AC2: the four bridges reference the contract ---------------------------

@test "each of the four cohort bridges references the contract doc (AC2)" {
  for b in "${BRIDGES[@]}"; do
    [ -f "$b" ] || { echo "missing bridge: $b"; return 1; }
    grep -qF "mode-b-round-trip-contract.md" "$b" \
      || { echo "no contract ref in $b"; return 1; }
  done
}

@test "each bridge states it is bookkeeping-only (AC2)" {
  for b in "${BRIDGES[@]}"; do
    grep -qiF "bookkeeping only" "$b" || grep -qiF "bookkeeping ONLY" "$b" \
      || { echo "no bookkeeping-only statement in $b"; return 1; }
  done
}

# --- AC3: every non-meeting Mode-B-ready SKILL.md references the contract ----

@test "every non-meeting Mode-B-ready SKILL.md points at the contract doc (AC3)" {
  local missing=""
  while read -r md; do
    [ -n "$md" ] || continue
    grep -qF "mode-b-round-trip-contract.md" "$md" || missing+="$md"$'\n'
  done < <(_non_meeting_ready_skills)
  [ -z "$missing" ] || { echo "missing contract ref:"$'\n'"$missing"; return 1; }
}

@test "the non-meeting Mode-B-ready cohort is non-trivial (AC3)" {
  local n
  n="$(_non_meeting_ready_skills | wc -l | tr -d ' ')"
  [ "$n" -ge 40 ]
}

# --- AC4: MANDATORY team-mode + no discretionary fallback -------------------

@test "every cohort SKILL.md states the team-mode round-trip is MANDATORY (AC4)" {
  local missing=""
  while read -r md; do
    [ -n "$md" ] || continue
    grep -qiF "MANDATORY under team orchestration" "$md" || missing+="$md"$'\n'
  done < <(_non_meeting_ready_skills)
  [ -z "$missing" ] || { echo "missing MANDATORY language:"$'\n'"$missing"; return 1; }
}

@test "every cohort SKILL.md forbids discretionary Mode A fall-through (AC4)" {
  local missing=""
  while read -r md; do
    [ -n "$md" ] || continue
    grep -qiF "No discretionary Mode A fall-through" "$md" || missing+="$md"$'\n'
  done < <(_non_meeting_ready_skills)
  [ -z "$missing" ] || { echo "missing no-discretionary-fallback language:"$'\n'"$missing"; return 1; }
}

@test "every cohort SKILL.md ties fall-through to a real MODE_B_FALLBACK token (AC4)" {
  local missing=""
  while read -r md; do
    [ -n "$md" ] || continue
    grep -qF "MODE_B_FALLBACK" "$md" || missing+="$md"$'\n'
  done < <(_non_meeting_ready_skills)
  [ -z "$missing" ] || { echo "missing MODE_B_FALLBACK reference:"$'\n'"$missing"; return 1; }
}

# --- AC5/AC6: no leaked internal IDs in the new doc -------------------------

@test "contract doc contains no leaked internal traceability IDs (AC5)" {
  run grep -cE '(FR|NFR|SR|ADR|TC)-[0-9]' "$CONTRACT"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$CONTRACT"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'AF-[0-9]{4}-[0-9]{2}-[0-9]{2}' "$CONTRACT"
  [ "${output:-0}" -eq 0 ]
}
