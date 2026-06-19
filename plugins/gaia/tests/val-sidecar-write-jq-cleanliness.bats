#!/usr/bin/env bats
# val-sidecar-write-jq-cleanliness.bats — E63-S14 / AI-2026-05-15-2.
#
# Asserts that val-sidecar-write.sh's stderr contains no `jq: error` noise
# when the write succeeds. The error fired on every Step 7 invocation of
# /gaia-triage-findings, /gaia-retro, and /gaia-add-feature when the
# decision payload's `findings` array contained STRINGS rather than
# objects (e.g., `["F1", "F2"]` from triage). The jq filter at L261 used
# `sort_by((.id // tostring))` which indexed a string with `.id` —
# throwing `Cannot index string with string "id"`. The fix wraps the
# sort key in a type-guard.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

WRITER="$BATS_TEST_DIRNAME/../scripts/val-sidecar-write.sh"

setup() {
  common_setup
  cd "$TEST_TMP"
  export CLAUDE_PROJECT_ROOT="$TEST_TMP"
  mkdir -p "$TEST_TMP/_memory/validator-sidecar"
}
teardown() { common_teardown; }

@test "object-shape findings payload writes cleanly (no jq error)" {
  PAYLOAD='{"artifact_path":"docs/x.md","verdict":"PASSED","findings":[{"id":"F1","severity":"INFO","detail":"ok"}]}'
  run --separate-stderr "$WRITER" \
    --command-name "/gaia-test" \
    --input-id "E99-S99-tc1" \
    --decision-payload "$PAYLOAD"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"jq: error"* ]]
  [[ "$output" == *"status=written"* ]] || [[ "$output" == *"status=skipped"* ]]
}

@test "string-shape findings payload writes cleanly (regression — original bug shape)" {
  # The original bug: triage passes findings as an array of STRINGS, not
  # objects. The pre-fix jq filter exploded with `Cannot index string with
  # string "id"`. Post-fix the type-guard sorts strings via tostring.
  PAYLOAD='{"artifact_path":"docs/x.md","verdict":"PASSED","findings":["F1","F2"]}'
  run --separate-stderr "$WRITER" \
    --command-name "/gaia-test" \
    --input-id "E99-S99-tc2" \
    --decision-payload "$PAYLOAD"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"jq: error"* ]]
  [[ "$stderr" != *"Cannot index string"* ]]
}

@test "heterogeneous findings list (mixed strings + objects) sorts cleanly" {
  # E63-S14 AC2 type-guard handles mixed inputs without error. The sort
  # key path is `if type == \"object\" then (.id // tostring) else tostring end`
  # which never throws on a per-element type change.
  PAYLOAD='{"artifact_path":"docs/x.md","verdict":"PASSED","findings":[{"id":"F2","detail":"obj"},"F1"]}'
  run --separate-stderr "$WRITER" \
    --command-name "/gaia-test" \
    --input-id "E99-S99-tc3" \
    --decision-payload "$PAYLOAD"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"jq: error"* ]]
  [[ "$stderr" != *"Cannot index string"* ]]
}

@test "fallback path (canonicalize_payload via _VS_HASH_BACKEND=shasum) cleans string-shape findings" {
  # When openssl is unavailable, compute_dedup_key routes through
  # canonicalize_payload (L213-L224) which has its own jq sort_by filter.
  # Same fix applied; this test exercises the formerly-uncovered path.
  PAYLOAD='{"artifact_path":"docs/x.md","verdict":"PASSED","findings":["F1","F2"]}'
  _VS_HASH_BACKEND=shasum run --separate-stderr "$WRITER" \
    --command-name "/gaia-test" \
    --input-id "E99-S99-tc4" \
    --decision-payload "$PAYLOAD"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"jq: error"* ]]
  [[ "$stderr" != *"Cannot index string"* ]]
}
