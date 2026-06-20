#!/usr/bin/env bats
# meeting-mode-b-pilot.bats — Mode B meeting pilot migration tests.
#
# Covers the meeting Mode B migration:
#   AC1 — meeting participants spawn via spawn_teammate (substrate-gated)
#   AC2 — Mode B transcript is a SUPERSET of Mode A transcript
#   AC3 — action-items artifact structurally identical between modes
#   AC4 — dispatch-agent-turn.sh is a thin shim delegating to dispatch-teammate
#   AC5 — human interjection routes to correct active teammate (substrate-gated)

load 'test_helper.bash'

setup() {
  common_setup

  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
  LIB_DIR="$SCRIPTS_DIR/lib"
  DT_LIB="$LIB_DIR/dispatch-teammate.sh"
  TF_LIB="$LIB_DIR/transcript-fidelity.sh"

  MEETING_DIR="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-meeting" && pwd)"
  MEETING_SCRIPTS="$MEETING_DIR/scripts"
  DISPATCH_AGENT="$MEETING_SCRIPTS/dispatch-agent-turn.sh"
  MEETING_BRIDGE="$MEETING_SCRIPTS/meeting-mode-b-bridge.sh"

  # Session dirs for dispatch-teammate.
  export GAIA_SESSION_DIR="$TEST_TMP/session"
  export GAIA_PROVENANCE_LOG="$TEST_TMP/session/provenance.log"
  export GAIA_SESSION_TRANSCRIPT="$TEST_TMP/session/transcript.md"
  mkdir -p "$GAIA_SESSION_DIR"

  # Force substrate unavailable — tests exercise plumbing + fallback.
  export GAIA_MODE_B_SUBSTRATE="${GAIA_MODE_B_SUBSTRATE:-unavailable}"
}

teardown() { common_teardown; }

# ============================================================
# AC1 — meeting spawn path calls spawn_teammate (substrate-gated)
# ============================================================

@test "meeting bridge sources dispatch-teammate library (AC1)" {
  [ -f "$MEETING_BRIDGE" ]
  grep -qF "dispatch-teammate.sh" "$MEETING_BRIDGE"
}

@test "meeting bridge exposes meeting_spawn_participant function (AC1)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  declare -F meeting_spawn_participant
}

@test "meeting_spawn_participant calls spawn_teammate and returns a handle (AC1)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  local handle
  handle="$(meeting_spawn_participant "gaia:architect" "test-session" 2>/dev/null)"
  [ -n "$handle" ]
}

@test "meeting_spawn_participant registers in dispatch-teammate registry (AC1)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  meeting_spawn_participant "gaia:analyst" "test-session" >/dev/null 2>&1
  local count
  count="$(_dt_active_count)"
  [ "$count" -ge 1 ]
}

@test "meeting_spawn_participant emits MODE_B_FALLBACK when substrate absent — substrate-gated (AC1)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  export GAIA_MODE_B_SUBSTRATE=unavailable
  local stderr_out="$TEST_TMP/stderr.txt"
  meeting_spawn_participant "gaia:architect" "test-session" >"$TEST_TMP/handle.txt" 2>"$stderr_out"
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

@test "meeting_spawn_participant rejects reviewer persona via clean-room gate (AC1)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  run meeting_spawn_participant "validator" "test-session"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "clean-room" ]] || [[ "$output" =~ "clean room" ]]
}

# ============================================================
# AC2 — Mode B transcript is superset of Mode A (AC2)
# ============================================================

@test "Mode B transcript from bridge relay contains Mode A content lines (AC2)" {
  source "$DT_LIB"
  source "$TF_LIB"
  source "$MEETING_BRIDGE"

  # Simulate Mode A transcript with bare content.
  local mode_a="$TEST_TMP/mode-a.md"
  printf 'Architecture review: auth module needs refactoring\n' > "$mode_a"
  printf 'Recommendation: adopt OIDC standard flow\n' >> "$mode_a"

  # Mode B: spawn, drive, relay.
  local handle
  handle="$(meeting_spawn_participant "gaia:architect" "sess-001" 2>/dev/null)"
  drive_turn "$handle" "review auth" 2>/dev/null
  local payload
  payload="$(printf 'Architecture review: auth module needs refactoring\nRecommendation: adopt OIDC standard flow')"
  relay_to_team_lead "$handle" "$payload" 2>/dev/null

  # Superset check.
  run verify_transcript_superset "$mode_a" "$GAIA_SESSION_TRANSCRIPT"
  [ "$status" -eq 0 ]
}

@test "Mode B transcript additionally contains persona metadata absent from Mode A (AC2)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"

  local handle
  handle="$(meeting_spawn_participant "gaia:analyst" "sess-002" 2>/dev/null)"
  drive_turn "$handle" "analyse risk" 2>/dev/null
  relay_to_team_lead "$handle" "Risk assessment: low" 2>/dev/null

  # Mode B transcript must carry persona/spawn_ts/turn metadata.
  grep -qE 'persona:' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'spawn_ts:' "$GAIA_SESSION_TRANSCRIPT"
  grep -qE 'turn:' "$GAIA_SESSION_TRANSCRIPT"
}

@test "superset check fails when Mode B transcript drops a Mode A line (AC2)" {
  source "$DT_LIB"
  source "$TF_LIB"
  source "$MEETING_BRIDGE"

  local mode_a="$TEST_TMP/mode-a.md"
  printf 'Line alpha\nLine beta\nLine gamma\n' > "$mode_a"

  # Mode B transcript intentionally missing Line beta.
  local handle
  handle="$(meeting_spawn_participant "gaia:pm" "sess-003" 2>/dev/null)"
  drive_turn "$handle" "prompt" 2>/dev/null
  relay_to_team_lead "$handle" "$(printf 'Line alpha\nLine gamma')" 2>/dev/null

  run verify_transcript_superset "$mode_a" "$GAIA_SESSION_TRANSCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Line beta" ]]
}

# ============================================================
# AC3 — action-items structural parity (AC3)
# ============================================================

@test "meeting bridge exposes meeting_format_action_items function (AC3)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  declare -F meeting_format_action_items
}

@test "action-items from Mode B match Mode A structural format (AC3)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"

  # Generate action items via bridge.
  local items
  items="$(meeting_format_action_items \
    "Implement OIDC flow" "architect" "2026-07-01" \
    "Review threat model" "security" "2026-07-15")"

  # Structural assertions — same shape as Mode A action items.
  # Each item has description, assignee, due_date fields.
  [[ "$items" =~ "Implement OIDC flow" ]]
  [[ "$items" =~ "architect" ]]
  [[ "$items" =~ "Review threat model" ]]
  [[ "$items" =~ "security" ]]
  # YAML-parseable lines.
  echo "$items" | grep -qE '^\s*- description:'
  echo "$items" | grep -qE '^\s*assignee:'
  echo "$items" | grep -qE '^\s*due_date:'
}

@test "action-items format is identical between Mode A and Mode B for same input (AC3)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"

  local mode_a_items mode_b_items

  # Mode A format (the canonical shape from action-items-writer.sh).
  mode_a_items="$(printf '  - description: Fix auth bug\n    assignee: architect\n    due_date: 2026-07-01')"

  # Mode B format via bridge.
  mode_b_items="$(meeting_format_action_items \
    "Fix auth bug" "architect" "2026-07-01")"

  # Structural diff — ignore leading/trailing whitespace differences.
  local a_norm b_norm
  a_norm="$(printf '%s' "$mode_a_items" | sed 's/^[[:space:]]*//' | sort)"
  b_norm="$(printf '%s' "$mode_b_items" | sed 's/^[[:space:]]*//' | sort)"
  [ "$a_norm" = "$b_norm" ]
}

# ============================================================
# AC4 — dispatch-agent-turn.sh is a thin shim (AC4)
# ============================================================

@test "dispatch-agent-turn.sh exists and is executable (AC4)" {
  [ -x "$DISPATCH_AGENT" ]
}

@test "dispatch-agent-turn.sh references dispatch-teammate for delegation (AC4)" {
  grep -qF "dispatch-teammate" "$DISPATCH_AGENT"
}

@test "dispatch-agent-turn.sh shim is under 400 lines — thin contract (AC4)" {
  local lines
  lines="$(wc -l < "$DISPATCH_AGENT")"
  [ "$lines" -le 400 ]
}

@test "dispatch-agent-turn.sh --print-discuss-allowlist still works (AC4)" {
  run "$DISPATCH_AGENT" --print-discuss-allowlist
  [ "$status" -eq 0 ]
  [ "$output" = "Read,Grep,Glob,Bash" ]
}

@test "dispatch-agent-turn.sh rejects missing --agent — CLI contract preserved (AC4)" {
  run "$DISPATCH_AGENT" --phase research --charter-ref /dev/null --session-id s1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--agent"* ]]
}

@test "dispatch-agent-turn.sh rejects missing --phase — CLI contract preserved (AC4)" {
  run "$DISPATCH_AGENT" --agent Theo --charter-ref /dev/null --session-id s1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--phase"* ]]
}

@test "dispatch-agent-turn.sh rejects invalid --phase — CLI contract preserved (AC4)" {
  run "$DISPATCH_AGENT" --agent Theo --phase invalid --charter-ref /dev/null --session-id s1
  [ "$status" -ne 0 ]
  [[ "$output" == *"phase"* ]]
}

@test "dispatch-agent-turn.sh exit codes propagated through shim (AC4)" {
  # Missing charter-ref -> exit 2.
  run "$DISPATCH_AGENT" --agent Theo --phase research --charter-ref /nonexistent --session-id s1
  [ "$status" -eq 2 ]
}

@test "dispatch-agent-turn.sh shim preserves dispatched_via in header (AC4)" {
  local charter="$TEST_TMP/charter.md"
  printf 'Test charter.\n' > "$charter"

  local stub="$TEST_TMP/stub.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"ok","artifacts":[],"findings":[],"next":"yield","body":"Test body output."}
JSON
STUB
  chmod +x "$stub"

  export GAIA_DISPATCH_AGENT_STUB="$stub"
  run "$DISPATCH_AGENT" --agent Theo --phase research --charter-ref "$charter" --session-id s1 \
      --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: subagent"* ]]
}

# ============================================================
# AC5 — human interjection routes to correct teammate (substrate-gated)
# ============================================================

@test "meeting bridge exposes meeting_route_interjection function (AC5)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  declare -F meeting_route_interjection
}

@test "interjection routing selects the last-active teammate handle (AC5)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"

  local h1 h2 h3
  h1="$(meeting_spawn_participant "gaia:architect" "sess-004" 2>/dev/null)"
  h2="$(meeting_spawn_participant "gaia:analyst" "sess-004" 2>/dev/null)"
  h3="$(meeting_spawn_participant "gaia:pm" "sess-004" 2>/dev/null)"

  # Drive turns via meeting_relay_turn (tracks last-active).
  drive_turn "$h1" "prompt 1" 2>/dev/null
  meeting_relay_turn "$h1" "output 1" 2>/dev/null
  drive_turn "$h2" "prompt 2" 2>/dev/null
  meeting_relay_turn "$h2" "output 2" 2>/dev/null

  # Route interjection — should target the last-active (h2).
  local target
  target="$(meeting_route_interjection "I disagree with the analysis")"
  [ "$target" = "$h2" ]
}

@test "interjection routing to a named participant selects correct handle (AC5)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"

  local h1 h2
  h1="$(meeting_spawn_participant "gaia:architect" "sess-005" 2>/dev/null)"
  h2="$(meeting_spawn_participant "gaia:analyst" "sess-005" 2>/dev/null)"

  # Route interjection explicitly to architect.
  local target
  target="$(meeting_route_interjection --to "architect")"
  [ "$target" = "$h1" ]
}

@test "interjection routing with no active teammates returns empty — no crash (AC5)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"

  local target
  target="$(meeting_route_interjection "hello" 2>/dev/null)" || true
  [ -z "$target" ]
}

@test "interjection routing would emit MODE_B_FALLBACK under substrate-absent — substrate-gated (AC5)" {
  source "$DT_LIB"
  source "$MEETING_BRIDGE"
  export GAIA_MODE_B_SUBSTRATE=unavailable

  local h1
  h1="$(meeting_spawn_participant "gaia:architect" "sess-006" 2>/dev/null)"
  drive_turn "$h1" "prompt" 2>/dev/null
  meeting_relay_turn "$h1" "output" 2>/dev/null

  # Routing itself is pure shell logic (no substrate needed), but the
  # downstream drive_turn on the target would emit fallback.
  local target
  target="$(meeting_route_interjection "my comment")"
  [ -n "$target" ]

  local stderr_out="$TEST_TMP/stderr.txt"
  drive_turn "$target" "interjection payload" 2>"$stderr_out" || true
  grep -qF "MODE_B_FALLBACK" "$stderr_out"
}

# ============================================================
# No leaked IDs in new files (regression gate)
# ============================================================

@test "meeting-mode-b-bridge.sh contains no leaked internal IDs (regression)" {
  # Use grep with constructed patterns to avoid the self-match problem.
  local f="$MEETING_BRIDGE"
  run grep -cE '(FR|NFR|ADR|TC)-[0-9]' "$f"
  [ "${output:-0}" -eq 0 ]
  run grep -cE 'E[0-9]+-S[0-9]+' "$f"
  [ "${output:-0}" -eq 0 ]
}
