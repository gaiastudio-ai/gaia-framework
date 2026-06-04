#!/usr/bin/env bats
# AF-2026-06-03-3 / E87-S11: adversarial-reviewer JSON sidecar emission.
#
# Covers:
#   - resolve-write-path.sh --paired: .md + .json collision-increment together
#   - write-adversarial-sidecar.sh: emit a deterministic ADR-037-derived sidecar
#       with review_type:"adversarial", NO timestamp, NO persona_sig,
#       NO sentinel_envelope, jq -S sorted keys, findings sorted (severity_rank,id)
#   - emitter rejects malformed input
#   - byte-identical determinism on repeated runs (NFR-96)
#   - default .md-only resolve-write-path behavior unchanged (regression)
#
# PLUGIN_ROOT is derived from $BATS_TEST_DIRNAME so the suite is resilient to a
# repo-rename flipping the CI checkout dir name.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVE="$PLUGIN_ROOT/skills/gaia-adversarial/scripts/resolve-write-path.sh"
  EMIT="$PLUGIN_ROOT/skills/gaia-adversarial/scripts/write-adversarial-sidecar.sh"
}

teardown() { common_teardown; }

# A representative ADR-037 adversarial envelope (out-of-order findings + keys).
_sample_envelope() {
  cat <<'JSON'
{
  "summary": "PRD is structurally sound but carries 1 critical assumption gap and 2 warnings.",
  "status": "CRITICAL",
  "artifacts": ["/abs/adversarial-review-prd-2026-06-03.md"],
  "findings": [
    {"severity": "WARNING", "id": "F-W2", "title": "Unstated rollback", "location": "§7.1"},
    {"severity": "INFO", "id": "F-I1", "title": "Naming nit", "location": "§2"},
    {"severity": "CRITICAL", "id": "F-C1", "title": "Auth assumption", "location": "§3.2"},
    {"severity": "WARNING", "id": "F-W1", "title": "Scope creep", "location": "§4"}
  ],
  "next": "Incorporate F-C1 into PRD §3.2 before /gaia-create-arch.",
  "timestamp": "2026-06-03T12:00:00Z",
  "sentinel_envelope": {"agent": "sage", "verdict": "CRITICAL"},
  "persona_sig": "sage-bogus"
}
JSON
}

# ===========================================================================
# AC3 — paired path resolution
# ===========================================================================

@test "E87-S11: --paired emits .md and .json for index 0 on fresh dir" {
  cd "$TEST_TMP"
  run env PROJECT_ROOT="$TEST_TMP" bash "$RESOLVE" --target prd --date 2026-06-03 --paired
  [ "$status" -eq 0 ]
  md="$(echo "$output" | sed -n '1p')"
  json="$(echo "$output" | sed -n '2p')"
  [[ "$md" =~ adversarial-review-prd-2026-06-03\.md$ ]]
  [[ "$json" =~ adversarial-review-prd-2026-06-03\.json$ ]]
}

@test "E87-S11: --paired increments .md and .json together on collision" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/planning-artifacts/adversarial
  touch .gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-2026-06-03.md
  run env PROJECT_ROOT="$TEST_TMP" bash "$RESOLVE" --target prd --date 2026-06-03 --paired
  [ "$status" -eq 0 ]
  md="$(echo "$output" | sed -n '1p')"
  json="$(echo "$output" | sed -n '2p')"
  [[ "$md" =~ adversarial-review-prd-2026-06-03-2\.md$ ]]
  [[ "$json" =~ adversarial-review-prd-2026-06-03-2\.json$ ]]
}

@test "E87-S11: --paired keeps .md and .json at the SAME index when only .md exists" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/planning-artifacts/adversarial
  touch .gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-2026-06-03.md
  touch .gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-2026-06-03-2.md
  run env PROJECT_ROOT="$TEST_TMP" bash "$RESOLVE" --target prd --date 2026-06-03 --paired
  [ "$status" -eq 0 ]
  md="$(echo "$output" | sed -n '1p')"
  json="$(echo "$output" | sed -n '2p')"
  [[ "$md" =~ adversarial-review-prd-2026-06-03-3\.md$ ]]
  [[ "$json" =~ adversarial-review-prd-2026-06-03-3\.json$ ]]
}

# ===========================================================================
# AC3 regression — default .md-only behavior unchanged
# ===========================================================================

@test "E87-S11 regression: default mode still emits a single .md path" {
  cd "$TEST_TMP"
  run env PROJECT_ROOT="$TEST_TMP" bash "$RESOLVE" --target prd --date 2026-06-03
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$output" =~ adversarial-review-prd-2026-06-03\.md$ ]]
  [[ ! "$output" =~ \.json ]]
}

@test "E87-S11 regression: default mode collision suffix unchanged" {
  cd "$TEST_TMP"
  mkdir -p .gaia/artifacts/planning-artifacts/adversarial
  touch .gaia/artifacts/planning-artifacts/adversarial/adversarial-review-prd-2026-06-03.md
  run env PROJECT_ROOT="$TEST_TMP" bash "$RESOLVE" --target prd --date 2026-06-03
  [ "$status" -eq 0 ]
  [[ "$output" =~ adversarial-review-prd-2026-06-03-2\.md$ ]]
}

# ===========================================================================
# AC2 / AC4 — emitter
# ===========================================================================

@test "E87-S11: emitter writes a sidecar with review_type adversarial" {
  cd "$TEST_TMP"
  sc="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/adversarial-review-prd-2026-06-03.md" --envelope-stdin)"
  [ -f "$sc" ]
  [[ "$sc" =~ adversarial-review-prd-2026-06-03\.json$ ]]
  run jq -r '.review_type' "$sc"
  [ "$status" -eq 0 ]
  [ "$output" = "adversarial" ]
}

@test "E87-S11: sidecar OMITS timestamp, persona_sig, sentinel_envelope" {
  cd "$TEST_TMP"
  sc="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/r.md" --envelope-stdin)"
  run jq -e 'has("timestamp")' "$sc";        [ "$output" = "false" ]
  run jq -e 'has("persona_sig")' "$sc";       [ "$output" = "false" ]
  run jq -e 'has("sentinel_envelope")' "$sc"; [ "$output" = "false" ]
}

@test "E87-S11: sidecar carries the inherited status verdict verbatim" {
  cd "$TEST_TMP"
  sc="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/r.md" --envelope-stdin)"
  run jq -r '.status' "$sc"
  [ "$output" = "CRITICAL" ]
}

@test "E87-S11: sidecar findings sorted by (severity_rank, id) — CRITICAL first" {
  cd "$TEST_TMP"
  sc="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/r.md" --envelope-stdin)"
  run jq -r '[.findings[].id] | @csv' "$sc"
  [ "$output" = '"F-C1","F-W1","F-W2","F-I1"' ]
}

@test "E87-S11: sidecar keys are jq -S sorted (top-level)" {
  cd "$TEST_TMP"
  sc="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/r.md" --envelope-stdin)"
  run jq -r 'keys_unsorted | @csv' "$sc"
  # jq -S yields lexicographically sorted top-level keys.
  [ "$output" = '"findings","next","review_type","status","summary","target"' ]
}

@test "E87-S11: sidecar is byte-identical on repeated runs (NFR-96)" {
  cd "$TEST_TMP"
  sc1="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/a.md" --envelope-stdin)"
  cp "$sc1" "$TEST_TMP/first.json"
  sc2="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/a.md" --envelope-stdin)"
  run diff "$TEST_TMP/first.json" "$sc2"
  [ "$status" -eq 0 ]
}

@test "E87-S11: emitter rejects malformed JSON" {
  cd "$TEST_TMP"
  run bash -c "printf 'not json{' | bash '$EMIT' --md-path '$TEST_TMP/r.md' --envelope-stdin"
  [ "$status" -ne 0 ]
}

@test "E87-S11: emitter rejects envelope missing required status" {
  cd "$TEST_TMP"
  run bash -c "printf '%s' '{\"summary\":\"x\",\"findings\":[],\"next\":\"y\"}' | bash '$EMIT' --md-path '$TEST_TMP/r.md' --envelope-stdin"
  [ "$status" -ne 0 ]
}

@test "E87-S11: emitter rejects an out-of-vocab status (STRONG)" {
  cd "$TEST_TMP"
  run bash -c "printf '%s' '{\"status\":\"STRONG\",\"summary\":\"x\",\"findings\":[],\"next\":\"y\"}' | bash '$EMIT' --md-path '$TEST_TMP/r.md' --envelope-stdin"
  [ "$status" -ne 0 ]
}

@test "E87-S11: emitter derives .json path from the .md path" {
  cd "$TEST_TMP"
  sc="$(_sample_envelope | bash "$EMIT" --md-path "$TEST_TMP/sub/adversarial-review-prd-2026-06-03-2.md" --envelope-stdin)"
  [ "$sc" = "$TEST_TMP/sub/adversarial-review-prd-2026-06-03-2.json" ]
  [ -f "$sc" ]
}

@test "E87-S11: emitter is executable" {
  [ -x "$EMIT" ]
}
