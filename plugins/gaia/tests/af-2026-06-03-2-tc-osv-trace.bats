#!/usr/bin/env bats
# af-2026-06-03-2-tc-osv-trace.bats — E87-S10 / AF-2026-06-03-2 / ADR-130
#
# Traceability + wiring regression for the additive envelope `original_status`
# field (FR-566 / FR-567 / NFR-95). The behavioral assertions for TC-OSV-1..5
# live in write-val-envelope.bats (TC-OSV-1/2/5) and assert-agent-envelope.bats
# (TC-OSV-3/4/5); the compose-verdict provenance half lives in
# af-2026-06-02-6-test17-sweep.bats. This file pins the field to its in-tree
# source surfaces and proves the TC-OSV behavioral assertions stay wired, so a
# regression of the documentation/test contract fails CI deterministically.
#
# Scope: this is a gaia-public-only bats. It asserts ONLY in-tree
# (CI-checked-out) artifacts — the writer/asserter/persona/reducer sources and
# the sibling bats. It deliberately does NOT assert project-root `.gaia/` docs
# (ADR-130 / PRD / test-plan live in the non-git workspace and are absent from
# the gaia-public CI checkout — per feedback_no_project_root_artifact_assert_in_gaia_public_bats).
# PLUGIN is derived from $BATS_TEST_DIRNAME (dir-rename-resilient).

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# FR-566 — writer emits original_status (additive)
# ---------------------------------------------------------------------------

@test "TC-OSV trace: FR-566 — write-val-envelope.sh source carries original_status" {
  grep -q 'original_status' "$PLUGIN/scripts/lib/write-val-envelope.sh"
}

@test "TC-OSV trace: TC-OSV-1 behavioral assertion is wired in write-val-envelope.bats" {
  grep -q 'TC-OSV-1' "$PLUGIN/tests/write-val-envelope.bats"
  grep -q 'writer preserves original_status' "$PLUGIN/tests/write-val-envelope.bats"
}

@test "TC-OSV trace: TC-OSV-2 (writer-absent) behavioral assertion is wired" {
  grep -q 'TC-OSV-2' "$PLUGIN/tests/write-val-envelope.bats"
  grep -q 'has("original_status")' "$PLUGIN/tests/write-val-envelope.bats"
}

# ---------------------------------------------------------------------------
# FR-567 — asserter accepts original_status as OPTIONAL
# ---------------------------------------------------------------------------

@test "TC-OSV trace: FR-567 — assert-agent-envelope.sh source carries original_status" {
  grep -q 'original_status' "$PLUGIN/scripts/lib/assert-agent-envelope.sh"
}

@test "TC-OSV trace: TC-OSV-3 (asserter-passes-with) behavioral assertion is wired" {
  grep -q 'TC-OSV-3' "$PLUGIN/tests/assert-agent-envelope.bats"
}

@test "TC-OSV trace: TC-OSV-4 (asserter-passes-without, back-compat) behavioral assertion is wired" {
  grep -q 'TC-OSV-4' "$PLUGIN/tests/assert-agent-envelope.bats"
}

# ---------------------------------------------------------------------------
# NFR-95 — original_status MUST NOT be required (golden invariant)
# ---------------------------------------------------------------------------

@test "TC-OSV trace: NFR-95 — TC-OSV-5 (with-and-without both exit 0) is wired on both writer + asserter bats" {
  grep -q 'TC-OSV-5' "$PLUGIN/tests/write-val-envelope.bats"
  grep -q 'TC-OSV-5' "$PLUGIN/tests/assert-agent-envelope.bats"
}

@test "TC-OSV trace: NFR-95 scope fence — validate-adr037-envelope.sh does NOT require original_status (publish-adapter envelope out of scope)" {
  # The ADR-113 publish-adapter envelope {verdict,evidence,summary,adapter_metadata}
  # is OUT OF SCOPE; original_status must not have leaked into its validator.
  local validator
  validator="$(find "$PLUGIN/scripts" "$PLUGIN/skills" -name 'validate-adr037-envelope.sh' 2>/dev/null | head -1)"
  if [ -n "$validator" ]; then
    run grep -c 'original_status' "$validator"
    [ "$output" = "0" ]
  else
    skip "validate-adr037-envelope.sh not present in this tree"
  fi
}

# ---------------------------------------------------------------------------
# Persona Sentinel-Write Contract documents the field
# ---------------------------------------------------------------------------

@test "TC-OSV trace: validator.md persona documents original_status semantics" {
  grep -q 'original_status' "$PLUGIN/agents/validator.md"
}

# ---------------------------------------------------------------------------
# E87-S9 compose-verdict provenance bookkeeping (cross-anchor)
# ---------------------------------------------------------------------------

@test "TC-OSV trace: compose-verdict.sh carries original_status provenance bookkeeping" {
  grep -q 'original_status' "$PLUGIN/skills/gaia-sprint-review/scripts/compose-verdict.sh"
}

@test "TC-OSV trace: compose-verdict provenance behavioral assertions are wired in test17-sweep.bats" {
  grep -q 'with-provenance' "$PLUGIN/tests/af-2026-06-02-6-test17-sweep.bats"
  grep -q 'original_status=track_a=WARNING' "$PLUGIN/tests/af-2026-06-02-6-test17-sweep.bats"
}
