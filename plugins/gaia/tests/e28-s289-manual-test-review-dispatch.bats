#!/usr/bin/env bats
# e28-s289-manual-test-review-dispatch.bats — per-story manual-test dispatch in
# the run-all-reviews flow (#1751 D1).
#
# The manual-test gate machinery (surface dispatch + ledger + advisory/gating
# consumer) all existed, but NOTHING in the per-story review dispatched a
# surface to produce a verdict. This helper closes the gap: for a
# manual_verification:true story it resolves a real functional target
# (sprint_review.manual_test.api_command for the api surface), dispatches the
# surface (REUSING dispatch-surface.sh), and records the verdict to the
# review-gate manual-test ledger gate.
#
# CRITICAL fail-CLOSED contract (the heart of the story): a story that REQUIRES
# manual verification must NEVER record a green gate without verification having
# actually run + passed. No target / SKIPPED / adapter-error / absent →
# UNVERIFIED (blocking), only a real PASSED surface → PASSED. These tests drive
# the REAL dispatch-surface.sh (not a mock) for the opt-in cases so the
# fail-open / wrong-target defects cannot hide.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/plugins/gaia"
  HELPER="$PLUGIN_DIR/scripts/manual-test-review-dispatch.sh"

  TMP="$(mktemp -d)"
  export REVIEW_GATE_LEDGER="$TMP/.review-gate-ledger"
  mkdir -p "$TMP/docs/implementation-artifacts" "$TMP/.gaia/config"
  cd "$TMP"
}

teardown() { rm -rf "$TMP"; }

have_yq() { command -v yq >/dev/null 2>&1; }

_story() {
  # $1 = key, $2 = manual_verification value
  local f="$TMP/docs/implementation-artifacts/$1-x.md"
  cat > "$f" <<EOF
---
template: 'story'
key: "$1"
manual_verification: $2
status: review
---
# story $1
EOF
  printf '%s' "$f"
}

_config() {
  # write a project-config with the given body under .gaia/config
  printf '%s\n' "$1" > "$TMP/.gaia/config/project-config.yaml"
  printf '%s' "$TMP/.gaia/config/project-config.yaml"
}

_ledger_verdict() {
  local key="$1" v=""
  [ -f "$REVIEW_GATE_LEDGER" ] || { printf ''; return; }
  while IFS=$'\t' read -r sk g p verdict; do
    [ "$sk" = "$key" ] && [ "$g" = "manual-test" ] && v="$verdict"
  done < "$REVIEW_GATE_LEDGER"
  printf '%s' "$v"
}

# ---------- AC3: zero-regression — non-opt-in is a clean no-op ----------

@test "a story without manual_verification:true is a no-op (no ledger entry) (AC3)" {
  f="$(_story E99-S2 false)"
  run bash "$HELPER" --story E99-S2 --story-file "$f"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 0 ]
  [ -z "$(_ledger_verdict E99-S2)" ]
}

@test "an absent manual_verification field is a no-op (AC3)" {
  f="$TMP/docs/implementation-artifacts/E99-S3-x.md"
  cat > "$f" <<'EOF'
---
template: 'story'
key: "E99-S3"
status: review
---
EOF
  run bash "$HELPER" --story E99-S3 --story-file "$f"
  [ "$status" -eq 0 ]
  [ -z "$(_ledger_verdict E99-S3)" ]
}

@test "a substring field (manual_verification_notes) does not false-match (AC3)" {
  f="$TMP/docs/implementation-artifacts/E99-S8-x.md"
  cat > "$f" <<'EOF'
---
template: 'story'
key: "E99-S8"
manual_verification_notes: true
status: review
---
EOF
  run bash "$HELPER" --story E99-S8 --story-file "$f"
  [ "$status" -eq 0 ]
  [ -z "$(_ledger_verdict E99-S8)" ]
}

# ---------- C1 fail-CLOSED: no real verification → UNVERIFIED, never PASSED ----------

@test "opt-in story with NO functional api_command records UNVERIFIED (not a vacuous PASSED) (AC2)" {
  have_yq || skip "yq not available"
  f="$(_story E99-S1 true)"
  cfg="$(_config 'platforms: [server]')"
  run bash "$HELPER" --story E99-S1 --story-file "$f" --config "$cfg"
  echo "status: $status"; echo "out: $output"
  # exit 4 = UNVERIFIED (verification required but did not run).
  [ "$status" -eq 4 ]
  [ "$(_ledger_verdict E99-S1)" = "UNVERIFIED" ]
}

@test "opt-in story with no config at all records UNVERIFIED (AC2)" {
  f="$(_story E99-S10 true)"
  run bash "$HELPER" --story E99-S10 --story-file "$f"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 4 ]
  [ "$(_ledger_verdict E99-S10)" = "UNVERIFIED" ]
}

# ---------- C2 + a real PASSED path (drives the REAL dispatch-surface) ----------

@test "opt-in story with a PASSING api_command records PASSED (real dispatch-surface) (AC1, AC2)" {
  have_yq || skip "yq not available"
  f="$(_story E99-S4 true)"
  cfg="$(_config 'platforms: [server]
sprint_review:
  manual_test:
    api_command: "true"')"
  run bash "$HELPER" --story E99-S4 --story-file "$f" --config "$cfg"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 0 ]
  [ "$(_ledger_verdict E99-S4)" = "PASSED" ]
}

@test "opt-in story with a FAILING api_command records FAILED and exits 3 (real dispatch-surface) (AC2)" {
  have_yq || skip "yq not available"
  f="$(_story E99-S5 true)"
  cfg="$(_config 'platforms: [server]
sprint_review:
  manual_test:
    api_command: "exit 1"')"
  run bash "$HELPER" --story E99-S5 --story-file "$f" --config "$cfg"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 3 ]
  [ "$(_ledger_verdict E99-S5)" = "FAILED" ]
}

@test "the story key is NOT passed as the api command (no bash -c of a bare key) (AC1)" {
  have_yq || skip "yq not available"
  # If the helper wrongly used the story key as the api --target, a key like
  # 'E99-S6' would be bash -c'd → command-not-found → FAILED. With a real
  # passing api_command configured, the verdict must be PASSED, proving the
  # command (not the key) was the target.
  f="$(_story E99-S6 true)"
  cfg="$(_config 'platforms: [server]
sprint_review:
  manual_test:
    api_command: "true"')"
  run bash "$HELPER" --story E99-S6 --story-file "$f" --config "$cfg"
  [ "$status" -eq 0 ]
  [ "$(_ledger_verdict E99-S6)" = "PASSED" ]
}

# ---------- AC1: reuse + wiring ----------

@test "the helper REUSES dispatch-surface.sh (does not reimplement surface logic) (AC1)" {
  grep -q 'dispatch-surface.sh' "$HELPER"
  ! grep -qE 'pixel-diff|read_platforms' "$HELPER"
}

@test "run-all-reviews SKILL.md dispatches the manual-test helper for the story (AC1)" {
  SKILL="$PLUGIN_DIR/skills/gaia-run-all-reviews/SKILL.md"
  grep -qF 'manual-test-review-dispatch.sh --story' "$SKILL"
  grep -qiF 'manual_verification: true' "$SKILL"
}

@test "missing dispatch-surface.sh records UNVERIFIED, not PASSED (fail-closed)" {
  have_yq || skip "yq not available"
  f="$(_story E99-S7 true)"
  cfg="$(_config 'platforms: [server]
sprint_review:
  manual_test:
    api_command: "true"')"
  DISPATCH_SURFACE_BIN="$TMP/does-not-exist.sh" run bash "$HELPER" --story E99-S7 --story-file "$f" --config "$cfg"
  echo "status: $status"; echo "out: $output"
  [ "$status" -eq 4 ]
  [ "$(_ledger_verdict E99-S7)" = "UNVERIFIED" ]
}

# ---------- unit: frontmatter reader ----------

@test "read_frontmatter_field extracts manual_verification from story frontmatter" {
  f="$(_story E99-S9 true)"
  # shellcheck disable=SC1090
  source <(sed -n '/^read_frontmatter_field()/,/^}/p' "$HELPER")
  run read_frontmatter_field "$f" manual_verification
  [ "$output" = "true" ]
  run read_frontmatter_field "$f" nonexistent_field
  [ -z "$output" ]
}
