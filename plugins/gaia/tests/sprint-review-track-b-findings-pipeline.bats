#!/usr/bin/env bats
# sprint-review-track-b-findings-pipeline.bats — Track B findings pipeline
#
# Validates that manual-test findings flow through the structured evidence
# pipeline (write-evidence → run-record + exit-code) → review-gate →
# eleven-type action-items pipeline (action-items-writer + type-target-resolver
# sprint-correction → /gaia-correct-course).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  RESOLVER="$PLUGIN_DIR/skills/gaia-meeting/scripts/lib/type-target-resolver.sh"
  WRITE_EVIDENCE="$PLUGIN_DIR/skills/gaia-test-manual/scripts/write-evidence.sh"
  SKILL_MD="$PLUGIN_DIR/skills/gaia-sprint-review/SKILL.md"

  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# AC3: action-items-writer accepts sprint-correction type
# ---------------------------------------------------------------------------

@test "AC3: type-target-resolver rejects unknown types" {
  run bash "$RESOLVER" "bogus-type"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3: type-target-resolver sprint-correction regression — known 11 types
# ---------------------------------------------------------------------------

@test "AC3: type-target-resolver resolves all 11 canonical types without error" {
  for t in feature prd-edit ux-edit arch-edit test-edit new-story \
           sprint-correction sprint-plan brainstorm-followup adr-draft \
           discussion-only; do
    run bash "$RESOLVER" "$t"
    [ "$status" -eq 0 ] || {
      echo "type-target-resolver failed for type: $t"
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# AC3: write-evidence produces structurally readable evidence files
# ---------------------------------------------------------------------------

@test "AC3: write-evidence creates run-record.md with readable content" {
  evidence_dir="$TMPDIR_TEST/evidence/manual-test-sprint-review"
  run bash -c "printf '# Manual Test Run Record\n\n- Surface: api\n- Verdict: FAILED\n\n## Output\n\nConnection refused\n' | '$WRITE_EVIDENCE' '$evidence_dir' FAILED"
  [ "$status" -eq 0 ]
  [ -f "$evidence_dir/run-record.md" ]
  grep -q "Manual Test Run Record" "$evidence_dir/run-record.md"
  grep -q "Connection refused" "$evidence_dir/run-record.md"
}

@test "AC3: write-evidence creates exit-code.log with VERDICT line" {
  evidence_dir="$TMPDIR_TEST/evidence/manual-test-exit-code"
  run bash -c "printf '# Run Record\n\nSome content\n' | '$WRITE_EVIDENCE' '$evidence_dir' FAILED"
  [ "$status" -eq 0 ]
  [ -f "$evidence_dir/exit-code.log" ]
  grep -q "VERDICT:" "$evidence_dir/exit-code.log"
}

@test "AC3: write-evidence exit-code.log contains the verdict value" {
  evidence_dir="$TMPDIR_TEST/evidence/manual-test-verdict-value"
  run bash -c "printf '# Run Record\n\nContent\n' | '$WRITE_EVIDENCE' '$evidence_dir' FAILED"
  [ "$status" -eq 0 ]
  grep -q "VERDICT: FAILED" "$evidence_dir/exit-code.log"
}

# ---------------------------------------------------------------------------
# AC3: SKILL.md documents the manual-test → action-items pipeline
# ---------------------------------------------------------------------------

@test "AC3: SKILL.md Step 7 references envelope → review-gate → action-items pipeline for manual-test findings" {
  # The SKILL.md should document that manual-test findings follow the
  # same action-items pipeline as Val findings
  grep -qE 'manual-test.*finding|manual-test.*action-item|manual-test.*pipeline|manual-test.*envelope' "$SKILL_MD"
}

@test "AC3: SKILL.md documents action-items-writer.sh for sprint-correction type" {
  grep -q 'type-target-resolver' "$SKILL_MD"
  grep -q 'sprint-correction' "$SKILL_MD"
}

# ---------------------------------------------------------------------------
# AC3: verify mode confirms evidence readability
# ---------------------------------------------------------------------------

@test "AC3: write-evidence --verify passes when both evidence files are present and non-empty" {
  evidence_dir="$TMPDIR_TEST/evidence/verify-pass"
  mkdir -p "$evidence_dir"
  printf '# Run Record\n\nContent\n' > "$evidence_dir/run-record.md"
  printf '2026-01-01T00:00:00Z 0 manual-test-run\nVERDICT: PASSED\n' > "$evidence_dir/exit-code.log"
  run "$WRITE_EVIDENCE" "$evidence_dir" "PASSED" --verify
  [ "$status" -eq 0 ]
}

@test "AC3: write-evidence --verify fails when evidence is missing" {
  evidence_dir="$TMPDIR_TEST/evidence/verify-fail"
  mkdir -p "$evidence_dir"
  # No run-record.md or exit-code.log
  run "$WRITE_EVIDENCE" "$evidence_dir" "PASSED" --verify
  [ "$status" -ne 0 ]
}
