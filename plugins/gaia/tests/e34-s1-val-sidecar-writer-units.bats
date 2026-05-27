#!/usr/bin/env bats
# e34-s1-val-sidecar-writer-units.bats
#
# Public-function unit coverage for val-sidecar-write.sh (NFR-052 gate).
# These tests source the helper functions directly so individual units —
# resolve_real, allowlist_match, canonicalize_payload, compute_dedup_key,
# ensure_header, sha256 — can be exercised in isolation. Behavioural /
# integration coverage lives in e34-s1-val-sidecar-writer.bats.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/val-sidecar-write.sh"

_load_helpers() {
  # Pull just the function definitions into the current shell. The script's
  # top-level pipeline must NOT execute when sourced for unit tests.
  local tmp
  tmp="$(mktemp -t val-sidecar-helpers.XXXXXX)"
  awk '
    /^_init_backends\(\) \{/,/^\}/ { print; next }
    /^resolve_real\(\) \{/,/^\}/ { print; next }
    /^allowlist_match\(\) \{/,/^\}/ { print; next }
    /^canonicalize_payload\(\) \{/,/^\}/ { print; next }
    /^compute_dedup_key\(\) \{/,/^\}/ { print; next }
    /^ensure_header\(\) \{/,/^\}/ { print; next }
    /^sha256\(\) \{/,/^\}/ { print; next }
  ' "$SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# resolve_real
# ---------------------------------------------------------------------------

@test "resolve_real: resolves existing directory to canonical absolute path" {
  _load_helpers
  local root="$TEST_TMP/real"; mkdir -p "$root"
  local got; got="$(resolve_real "$root")"
  [[ "$got" == /* ]]
  [ -d "$got" ]
}

@test "resolve_real: resolves non-existent target under existing root" {
  _load_helpers
  local root="$TEST_TMP/real"; mkdir -p "$root"
  local got; got="$(resolve_real "$root/a/b/file.md")"
  [[ "$got" == */a/b/file.md ]]
}

# ---------------------------------------------------------------------------
# allowlist_match
# ---------------------------------------------------------------------------

@test "allowlist_match: accepts validator-sidecar/decision-log.md" {
  _load_helpers
  local root="/tmp/gaia-vs-root"
  allowlist_match "$root" "$root/.gaia/memory/validator-sidecar/decision-log.md"
}

@test "allowlist_match: accepts validator-sidecar/conversation-context.md" {
  _load_helpers
  local root="/tmp/gaia-vs-root"
  allowlist_match "$root" "$root/.gaia/memory/validator-sidecar/conversation-context.md"
}

@test "allowlist_match: rejects other sidecar directories" {
  _load_helpers
  local root="/tmp/gaia-vs-root"
  run allowlist_match "$root" "$root/.gaia/memory/sm-sidecar/decision-log.md"
  [ "$status" -ne 0 ]
}

@test "allowlist_match: rejects arbitrary path outside _memory" {
  _load_helpers
  local root="/tmp/gaia-vs-root"
  run allowlist_match "$root" "$root/docs/implementation-artifacts/story.md"
  [ "$status" -ne 0 ]
}

@test "allowlist_match: rejects other filename under validator-sidecar" {
  _load_helpers
  local root="/tmp/gaia-vs-root"
  run allowlist_match "$root" "$root/.gaia/memory/validator-sidecar/ground-truth.md"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# sha256
# ---------------------------------------------------------------------------

@test "sha256: returns hex digest of stdin with no path suffix" {
  _load_helpers
  local got; got="$(printf 'hello' | sha256)"
  [ "$got" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

# ---------------------------------------------------------------------------
# canonicalize_payload
# ---------------------------------------------------------------------------

@test "canonicalize_payload: sorts findings[] by id for hash-stability" {
  _load_helpers
  local p1='{"verdict":"passed","findings":[{"id":"F1"},{"id":"F2"}],"artifact_path":"x.md"}'
  local p2='{"verdict":"passed","findings":[{"id":"F2"},{"id":"F1"}],"artifact_path":"x.md"}'
  [ "$(canonicalize_payload "$p1")" = "$(canonicalize_payload "$p2")" ]
}

@test "canonicalize_payload: excludes timestamp and session_id from canonical form" {
  _load_helpers
  local p1='{"verdict":"passed","findings":[],"artifact_path":"x.md","timestamp":"2026-04-22T10:00:00Z","session_id":"sess-1"}'
  local p2='{"verdict":"passed","findings":[],"artifact_path":"x.md","timestamp":"2026-04-22T11:00:00Z","session_id":"sess-2"}'
  [ "$(canonicalize_payload "$p1")" = "$(canonicalize_payload "$p2")" ]
}

@test "canonicalize_payload: emits sorted-key minified JSON" {
  _load_helpers
  local p='{"findings":[],"verdict":"passed","artifact_path":"x.md"}'
  local got; got="$(canonicalize_payload "$p")"
  # Sorted-key order: artifact_path, findings, verdict
  [[ "$got" == '{"artifact_path":"x.md","findings":[],"verdict":"passed"}' ]]
}

# ---------------------------------------------------------------------------
# compute_dedup_key
# ---------------------------------------------------------------------------

@test "compute_dedup_key: emits a 64-char hex SHA-256" {
  _load_helpers
  local key; key="$(compute_dedup_key "/gaia-create-story" "E1-S1" '{"verdict":"x","findings":[],"artifact_path":"a"}')"
  [ "${#key}" -eq 64 ]
  [[ "$key" =~ ^[0-9a-f]{64}$ ]]
}

@test "compute_dedup_key: deterministic for identical inputs" {
  _load_helpers
  local a b
  a="$(compute_dedup_key "/cmd" "ID-1" '{"verdict":"p","findings":[],"artifact_path":"x"}')"
  b="$(compute_dedup_key "/cmd" "ID-1" '{"verdict":"p","findings":[],"artifact_path":"x"}')"
  [ "$a" = "$b" ]
}

@test "compute_dedup_key: different command_name changes key" {
  _load_helpers
  local a b
  a="$(compute_dedup_key "/cmd-a" "ID-1" '{"verdict":"p","findings":[],"artifact_path":"x"}')"
  b="$(compute_dedup_key "/cmd-b" "ID-1" '{"verdict":"p","findings":[],"artifact_path":"x"}')"
  [ "$a" != "$b" ]
}

@test "compute_dedup_key: different input_id changes key" {
  _load_helpers
  local a b
  a="$(compute_dedup_key "/cmd" "ID-1" '{"verdict":"p","findings":[],"artifact_path":"x"}')"
  b="$(compute_dedup_key "/cmd" "ID-2" '{"verdict":"p","findings":[],"artifact_path":"x"}')"
  [ "$a" != "$b" ]
}

# ---------------------------------------------------------------------------
# ensure_header
# ---------------------------------------------------------------------------

@test "ensure_header: seeds decision-log header when file missing" {
  _load_helpers
  local tgt="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  mkdir -p "$(dirname "$tgt")"
  ensure_header "$tgt"
  [ -f "$tgt" ]
  grep -q "Decision Log" "$tgt"
}

@test "ensure_header: seeds conversation-context header when file missing" {
  _load_helpers
  local tgt="$TEST_TMP/.gaia/memory/validator-sidecar/conversation-context.md"
  mkdir -p "$(dirname "$tgt")"
  ensure_header "$tgt"
  [ -f "$tgt" ]
  grep -q "Conversation Context" "$tgt"
}

@test "ensure_header: leaves existing file untouched" {
  _load_helpers
  local tgt="$TEST_TMP/.gaia/memory/validator-sidecar/decision-log.md"
  mkdir -p "$(dirname "$tgt")"
  printf 'PRESERVED\n' > "$tgt"
  ensure_header "$tgt"
  local got; got="$(cat "$tgt")"
  [ "$got" = "PRESERVED" ]
}
