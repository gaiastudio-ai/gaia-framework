#!/usr/bin/env bats
# dispatch-agent-turn.bats — gaia-meeting subagent-dispatch wrapper unit tests (E76-S10)
#
# Covers AC2, AC3, AC6 / TC-MTG-DISPATCH-2, TC-MTG-DISPATCH-4.

setup() {
  SKILL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS_DIR="$SKILL_DIR/scripts"
  HELPER="$SCRIPTS_DIR/dispatch-agent-turn.sh"
  TURN_HEADER="$SCRIPTS_DIR/turn-header.sh"
  RESEARCH_DISPATCH="$SCRIPTS_DIR/research-phase-dispatch.sh"
  SESSION_STATE="$SCRIPTS_DIR/session-state.sh"
  TMP_DIR="$(mktemp -d)"
  CHARTER_REF="$TMP_DIR/charter.md"
  printf 'Charter goal: ship a thing.\n' > "$CHARTER_REF"
  STATE_FILE="$TMP_DIR/state.yaml"
  "$SESSION_STATE" create --file "$STATE_FILE" --session-id sess-001
  # Stub Agent-tool dispatcher: emits a known ADR-037 payload to stdout. The
  # wrapper resolves it via the GAIA_DISPATCH_AGENT_STUB env var (test seam).
  export GAIA_DISPATCH_AGENT_STUB="$TMP_DIR/agent-stub.sh"
  cat > "$GAIA_DISPATCH_AGENT_STUB" <<'STUB'
#!/usr/bin/env bash
# Default ADR-037 stub return — INFO finding only, body line on stdout.
cat <<'JSON'
{"status":"done","summary":"Prelude complete.","artifacts":[],"findings":[{"severity":"INFO","summary":"All sources read.","turn_id":"t1"}],"next":"yield","body":"[Prelude] Theo (Architect) — 100 tokens\nSources consulted:\n  docs/charter.md\nWhat I know:\n  - The plan is fine."}
JSON
STUB
  chmod +x "$GAIA_DISPATCH_AGENT_STUB"
}

teardown() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}

@test "Pre-flight: dispatch-agent-turn.sh exists and is executable" {
  [ -x "$HELPER" ]
}

# AC2: Argument validation
@test "AC2: dispatch-agent-turn.sh rejects missing --agent" {
  run "$HELPER" --phase research --charter-ref "$CHARTER_REF" --session-id sess-001
  [ "$status" -ne 0 ]
  [[ "$output" == *"--agent"* ]]
}

@test "AC2: dispatch-agent-turn.sh rejects missing --phase" {
  run "$HELPER" --agent Theo --charter-ref "$CHARTER_REF" --session-id sess-001
  [ "$status" -ne 0 ]
  [[ "$output" == *"--phase"* ]]
}

@test "AC2: dispatch-agent-turn.sh rejects invalid --phase value" {
  run "$HELPER" --agent Theo --phase invalid --charter-ref "$CHARTER_REF" --session-id sess-001
  [ "$status" -ne 0 ]
  [[ "$output" == *"phase"* ]]
}

@test "AC2: dispatch-agent-turn.sh rejects missing --charter-ref" {
  run "$HELPER" --agent Theo --phase research --session-id sess-001
  [ "$status" -ne 0 ]
  [[ "$output" == *"--charter-ref"* ]]
}

@test "AC2: dispatch-agent-turn.sh rejects missing --session-id" {
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--session-id"* ]]
}

@test "AC2: dispatch-agent-turn.sh rejects unreadable --charter-ref" {
  run "$HELPER" --agent Theo --phase research --charter-ref "$TMP_DIR/missing.md" --session-id sess-001
  [ "$status" -ne 0 ]
  [[ "$output" == *"charter-ref"* ]]
}

# AC2: Research dispatch happy path -- header carries dispatched_via: subagent
@test "AC2: --phase research dispatch emits header with 'dispatched_via: subagent'" {
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: subagent"* ]]
}

# AC2: Research dispatch resolves the canonical RESEARCH allowlist
@test "AC2: --phase research records the research allowlist from research-phase-dispatch.sh" {
  RESEARCH_ALLOWLIST="$("$RESEARCH_DISPATCH" --print-allowlist)"
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE" --debug-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"$RESEARCH_ALLOWLIST"* ]]
}

# AC2: Research dispatch with --no-web routes the no-web allowlist
@test "AC2: --phase research --no-web records the no-web allowlist" {
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE" --no-web --debug-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read,Grep,Glob,Bash"* ]]
  [[ "$output" != *"WebSearch"* ]]
}

# AC2: Discuss dispatch happy path -- header carries dispatched_via: subagent
@test "AC2: --phase discuss dispatch emits header with 'dispatched_via: subagent'" {
  run "$HELPER" --agent Theo --phase discuss --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatched_via: subagent"* ]]
}

# AC2: Discuss allowlist returns canonical [Read, Grep, Glob, Bash]
@test "AC2: --print-discuss-allowlist returns Read,Grep,Glob,Bash" {
  run "$HELPER" --print-discuss-allowlist
  [ "$status" -eq 0 ]
  [ "$output" = "Read,Grep,Glob,Bash" ]
}

# AC2: Discuss dispatch resolves the canonical DISCUSS allowlist
@test "AC2: --phase discuss records the discuss allowlist via --print-discuss-allowlist" {
  DISCUSS_ALLOWLIST="$("$HELPER" --print-discuss-allowlist)"
  run "$HELPER" --agent Theo --phase discuss --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE" --debug-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" == *"$DISCUSS_ALLOWLIST"* ]]
}

# AC2: Allowlist must NEVER carry write-capable tools
@test "AC2: discuss allowlist NEVER contains Write/Edit/NotebookEdit" {
  run "$HELPER" --print-discuss-allowlist
  [ "$status" -eq 0 ]
  [[ "$output" != *"Write"* ]]
  [[ "$output" != *"Edit"* ]]
  [[ "$output" != *"NotebookEdit"* ]]
}

# AC2: Body of the dispatched turn appears on stdout after the header
@test "AC2: dispatched turn body lands on stdout after the header" {
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[Prelude] Theo (Architect)"* ]]
  [[ "$output" == *"Sources consulted"* ]]
}

# AC2: Malformed ADR-037 return -- non-zero exit, raw passthrough
@test "AC2: malformed ADR-037 return fails non-zero with raw passthrough" {
  cat > "$GAIA_DISPATCH_AGENT_STUB" <<'STUB'
#!/usr/bin/env bash
echo "this is not valid json"
STUB
  chmod +x "$GAIA_DISPATCH_AGENT_STUB"
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"this is not valid json"* ]]
}

# AC6: INFO finding is appended to agent_dispatch_findings via session-state
@test "AC6: INFO finding appended to session-state agent_dispatch_findings" {
  run "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -eq 0 ]
  found="$("$SESSION_STATE" read --file "$STATE_FILE" --field agent_dispatch_findings)"
  [[ "$found" == *"All sources read."* ]] || [[ "$found" == *"INFO"* ]]
}

# AC6: WARNING finding is surfaced on stderr in canonical format BEFORE turn body
@test "AC6: WARNING finding surfaces canonical stderr line before turn body" {
  cat > "$GAIA_DISPATCH_AGENT_STUB" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"warn","artifacts":[],"findings":[{"severity":"WARNING","summary":"missing source","turn_id":"t1"}],"next":"yield","body":"[body]"}
JSON
STUB
  chmod +x "$GAIA_DISPATCH_AGENT_STUB"
  run --separate-stderr "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[gaia-meeting] WARNING:"* ]]
  [[ "$stderr" == *"Theo"* ]]
  [[ "$stderr" == *"missing source"* ]]
}

# AC6: CRITICAL finding is surfaced on stderr in canonical format
@test "AC6: CRITICAL finding surfaces canonical stderr line" {
  cat > "$GAIA_DISPATCH_AGENT_STUB" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"status":"done","summary":"crit","artifacts":[],"findings":[{"severity":"CRITICAL","summary":"forbidden write","turn_id":"t2"}],"next":"yield","body":"[body]"}
JSON
STUB
  chmod +x "$GAIA_DISPATCH_AGENT_STUB"
  run --separate-stderr "$HELPER" --agent Theo --phase research --charter-ref "$CHARTER_REF" --session-id sess-001 \
                --round 1 --turn 1 --speaker Theo --role Architect --turn-cost 100 --running-total 100 \
                --state-file "$STATE_FILE"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[gaia-meeting] CRITICAL:"* ]]
  [[ "$stderr" == *"forbidden write"* ]]
}
