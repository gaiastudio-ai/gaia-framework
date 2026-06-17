#!/usr/bin/env bats
# e36-s2-retro-sidecar-write-units.bats
#
# Public-function unit coverage for retro-sidecar-write.sh (NFR-052 gate).
# These tests source the script as a library (BATS_TEST_SOURCE) so the
# individual helper functions — resolve_real, allowlist_match,
# normalize_payload, canonical_header — can be exercised directly. The
# behavioural / integration coverage lives in
# e36-s2-memory-velocity-persistence.bats; this file keeps the coverage
# gate satisfied without polluting the authoritative ATDD fixture.

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/retro-sidecar-write.sh"

# Source the script as a library: set BATS_TEST_SOURCE=1 so the script's
# top-level argument-parsing and pipeline do not execute when sourced.
# Because retro-sidecar-write.sh runs its pipeline unconditionally, we
# instead extract its helper definitions by eval-ing the function blocks.
_load_helpers() {
  # Pull just the function definitions into the current shell. This is
  # safer than sourcing the full script (which would execute the pipeline).
  local tmp
  tmp="$(mktemp -t retro-sidecar-helpers.XXXXXX)"
  awk '
    /^resolve_real\(\) \{/,/^\}/ { print; next }
    /^allowlist_match\(\) \{/,/^\}/ { print; next }
    /^normalize_payload\(\) \{/,/^\}/ { print; next }
    /^sha256\(\) \{/,/^\}/ { print; next }
    /^canonical_header\(\) \{/,/^\}/ { print; next }
  ' "$SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# resolve_real — deepest-existing-ancestor realpath
# ---------------------------------------------------------------------------

@test "resolve_real resolves an existing directory to its canonical path" {
  _load_helpers
  local root="$TEST_TMP/real"; mkdir -p "$root"
  local got; got="$(resolve_real "$root")"
  # On macOS /tmp -> /private/tmp, so the canonical form should be absolute.
  [[ "$got" == /* ]]
  [ -d "$got" ]
}

@test "resolve_real handles a non-existent deep subtree under an existing root" {
  _load_helpers
  local root="$TEST_TMP/real"; mkdir -p "$root"
  local target="$root/a/b/c/d/file.md"
  local got; got="$(resolve_real "$target")"
  # Ancestor portion (root) is realpath'd; tail is re-appended verbatim.
  [[ "$got" == */a/b/c/d/file.md ]]
}

@test "resolve_real tolerates a symlinked ancestor" {
  _load_helpers
  local real_root="$TEST_TMP/real"; mkdir -p "$real_root"
  local link_root="$TEST_TMP/link"; ln -s "$real_root" "$link_root"
  local got; got="$(resolve_real "$link_root/x/y.md")"
  # Link is resolved: got should contain the real prefix, not the link.
  [[ "$got" == *"/real/x/y.md" ]]
}

# ---------------------------------------------------------------------------
# allowlist_match — NFR-RIM-2 path classification
# ---------------------------------------------------------------------------

@test "allowlist_match accepts a sidecar decision-log under .gaia/memory/{agent}-sidecar/" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/.gaia/memory/architect-sidecar/decision-log.md"
}

@test "allowlist_match REJECTS the legacy _memory/{agent}-sidecar/ path" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  ! allowlist_match "$root" "$root/_memory/architect-sidecar/decision-log.md"
}

@test "allowlist_match accepts a retrospective artifact" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/docs/implementation-artifacts/retrospective-sprint-99.md"
}

@test "allowlist_match accepts action-items.yaml" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/docs/planning-artifacts/action-items.yaml"
}

# issue-1168: the retro skill writes action-items to the canonical
# .gaia/artifacts/planning-artifacts/ home (per the retro SKILL.md Step 5
# invocation), so the writer allowlist MUST accept that path — otherwise the
# writer rejects its own canonical target as unauthorized and retro-emitted
# items vanish.
@test "allowlist_match accepts canonical .gaia/artifacts/planning-artifacts/action-items.yaml (issue-1168)" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/.gaia/artifacts/planning-artifacts/action-items.yaml"
}

@test "allowlist_match accepts custom/skills/*.md" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/custom/skills/proposal.md"
}

@test "allowlist_match accepts .customize.yaml at the root" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  allowlist_match "$root" "$root/.customize.yaml"
}

@test "allowlist_match rejects arbitrary paths outside the allowlist" {
  _load_helpers
  local root="/tmp/gaia-al-root"
  run allowlist_match "$root" "$root/gaia-public/plugins/gaia/skills/foo.md"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# sha256 — thin wrapper over shasum -a 256 returning the hex digest only
# ---------------------------------------------------------------------------

@test "sha256 returns the hex digest of stdin (no path suffix)" {
  _load_helpers
  local got; got="$(printf 'hello' | sha256)"
  # Known digest of "hello".
  [ "$got" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

# ---------------------------------------------------------------------------
# normalize_payload — strip BOM, normalize CRLF, trim trailing whitespace
# ---------------------------------------------------------------------------

@test "normalize_payload strips UTF-8 BOM prefix" {
  _load_helpers
  local bom_input
  bom_input="$(printf '\xEF\xBB\xBFhello')"
  local got; got="$(normalize_payload "$bom_input")"
  [ "$got" = "hello" ]
}

@test "normalize_payload converts CRLF to LF" {
  _load_helpers
  local got; got="$(normalize_payload "$(printf 'a\r\nb')")"
  [ "$got" = "$(printf 'a\nb')" ]
}

@test "normalize_payload trims trailing whitespace per line" {
  _load_helpers
  local got; got="$(normalize_payload "$(printf 'alpha   \nbeta\t')")"
  [ "$got" = "$(printf 'alpha\nbeta')" ]
}

# ---------------------------------------------------------------------------
# canonical_header — per-target canonical seed
# ---------------------------------------------------------------------------

@test "canonical_header for decision-log.md emits Decision Log header" {
  _load_helpers
  local got; got="$(canonical_header "/x/_memory/sm-sidecar/decision-log.md")"
  [[ "$got" == *"Decision Log"* ]]
}

@test "canonical_header for velocity-data.md emits SM Velocity Data header" {
  _load_helpers
  local got; got="$(canonical_header "/x/_memory/sm-sidecar/velocity-data.md")"
  [[ "$got" == *"SM Velocity Data"* ]]
  [[ "$got" == *"sprint_id"* ]]
}

@test "canonical_header for action-items.yaml emits schema comment and items:" {
  _load_helpers
  local got; got="$(canonical_header "/x/docs/planning-artifacts/action-items.yaml")"
  [[ "$got" == *"Action Items"* ]]
  [[ "$got" == *"items:"* ]]
  [[ "$got" == *"classification"* ]]
}

@test "canonical_header for conversation-context.md emits rolling context header" {
  _load_helpers
  local got; got="$(canonical_header "/x/_memory/validator-sidecar/conversation-context.md")"
  [[ "$got" == *"Conversation Context"* ]]
}
