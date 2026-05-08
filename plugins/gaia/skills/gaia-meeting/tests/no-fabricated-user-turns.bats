#!/usr/bin/env bats
# no-fabricated-user-turns.bats — gaia-meeting speaker-label invariant (E76-S8)
#
# AC2 / TC-MTG-NOFAB-2 — static check that scans a saved transcript fixture and
# fails when any turn whose `Speaker:` field matches the resolved user name
# carries an `origin:` (or `dispatched_via:` per E76-S10) that is NOT
# `interject`. Two cases: regression fixture FAILS, clean fixture PASSES.
#
# AC3 — fixtures live alongside this test under `tests/fixtures/`. The user-name
# placeholder in the regression fixture is the literal token `${USER_NAME}` —
# expanded at test time via `scripts/resolve-user-name.sh` so the test works on
# any CI runner.
#
# AC1 / TC-MTG-NOFAB-1 — also asserts the SKILL.md hard-rule prose is present,
# and that the §Phase 3 / §Phase 4 reinforcement sentences are character-
# identical (single source-of-truth wording).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  RESOLVE_USER="$SKILL_DIR/scripts/resolve-user-name.sh"
  FIXTURE_FAB="$SKILL_DIR/tests/fixtures/transcript-fabricated-user-turn.md"
  FIXTURE_CLEAN="$SKILL_DIR/tests/fixtures/transcript-no-fabricated-user-turn.md"
  SKILL_MD="$SKILL_DIR/SKILL.md"

  # Pin LC_ALL=C per gaia-meeting framework convention (NFR-MTG-1; see
  # "Determinism + locale" note in the story technical-notes).
  export LC_ALL=C

  TMP="$(mktemp -d)"
  TMP_FAB="$TMP/transcript-fabricated.md"
  TMP_CLEAN="$TMP/transcript-clean.md"

  # Resolve user name (settings.json override > git config). Tests rely on at
  # least one of those resolving — a fresh git workdir without git config
  # user.name will skip below.
  if USER_NAME="$("$RESOLVE_USER" 2>/dev/null)"; then
    export USER_NAME
  else
    USER_NAME=""
  fi
}

teardown() {
  rm -rf "$TMP"
}

# expand_placeholder <src> <dst>
# Replaces every literal `${USER_NAME}` in <src> with $USER_NAME and writes to
# <dst>. Uses awk so we don't depend on sed -E flag semantics across BSD/GNU.
expand_placeholder() {
  local src="$1" dst="$2"
  awk -v u="$USER_NAME" '{
    while (match($0, /\$\{USER_NAME\}/)) {
      $0 = substr($0, 1, RSTART-1) u substr($0, RSTART+RLENGTH)
    }
    print
  }' "$src" > "$dst"
}

# scan_for_fabricated <expanded-fixture>
# Returns 0 when the fixture contains NO fabricated user turn; non-zero
# otherwise. A "fabricated user turn" is a per-turn header block whose
# `Speaker:` line equals the resolved user name AND whose `origin:` (or
# `dispatched_via:`) is not the literal token `interject`.
#
# Implementation: parse line-by-line, tracking the current per-turn-header
# block. A header block starts at a `Speaker:` line and ends at the first
# blank line. Within the block, we capture `origin:` and `dispatched_via:`.
scan_for_fabricated() {
  local fixture="$1"
  awk -v u="$USER_NAME" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN { in_block = 0; speaker = ""; origin = ""; via = ""; found = 0 }
    /^Speaker:/ {
      # close any prior block first
      if (in_block) {
        if (speaker == u && origin != "interject" && via != "interject") { found = 1; exit }
      }
      in_block = 1
      sub(/^Speaker:[[:space:]]*/, "", $0); speaker = trim($0); origin = ""; via = ""
      next
    }
    in_block && /^origin:/    { sub(/^origin:[[:space:]]*/, "", $0);    origin = trim($0); next }
    in_block && /^dispatched_via:/ { sub(/^dispatched_via:[[:space:]]*/, "", $0); via = trim($0); next }
    in_block && /^[[:space:]]*$/ {
      if (speaker == u && origin != "interject" && via != "interject") { found = 1; exit }
      in_block = 0; speaker = ""; origin = ""; via = ""
      next
    }
    END {
      if (in_block && speaker == u && origin != "interject" && via != "interject") { found = 1 }
      exit (found ? 1 : 0)
    }
  ' "$fixture"
}

@test "Pre-flight: regression fixture exists" {
  [ -f "$FIXTURE_FAB" ]
}

@test "Pre-flight: clean fixture exists" {
  [ -f "$FIXTURE_CLEAN" ]
}

@test "Pre-flight: resolve-user-name.sh resolves a name on this runner" {
  [ -n "$USER_NAME" ]
}

@test "AC2 / AC3 / TC-MTG-NOFAB-2: regression fixture FAILS the no-fabricated-user-turn check" {
  [ -n "$USER_NAME" ]
  expand_placeholder "$FIXTURE_FAB" "$TMP_FAB"
  run scan_for_fabricated "$TMP_FAB"
  [ "$status" -ne 0 ]
}

@test "AC2 / AC3 / TC-MTG-NOFAB-2: clean fixture PASSES the no-fabricated-user-turn check" {
  [ -n "$USER_NAME" ]
  expand_placeholder "$FIXTURE_CLEAN" "$TMP_CLEAN"
  run scan_for_fabricated "$TMP_CLEAN"
  [ "$status" -eq 0 ]
}

@test "AC2: interject-origin user turn does NOT fail the check (legitimate user content)" {
  [ -n "$USER_NAME" ]
  cat > "$TMP/interject-ok.md" <<EOF
Speaker: $USER_NAME
Role: User
Phase: DISCUSS
origin: interject

[i]nterject "I want to add one more thing".
EOF
  run scan_for_fabricated "$TMP/interject-ok.md"
  [ "$status" -eq 0 ]
}

@test "AC2: dispatched_via=interject user turn does NOT fail (E76-S10 forward-compat)" {
  [ -n "$USER_NAME" ]
  cat > "$TMP/dispatched-ok.md" <<EOF
Speaker: $USER_NAME
Role: User
Phase: DISCUSS
origin: user
dispatched_via: interject

[i]nterject "Wrap up please".
EOF
  run scan_for_fabricated "$TMP/dispatched-ok.md"
  [ "$status" -eq 0 ]
}

@test "AC1 / TC-MTG-NOFAB-1: SKILL.md §Critical Rules contains the 'No fabricated user turns' hard-rule subsection" {
  [ -f "$SKILL_MD" ]
  run grep -F 'No fabricated user turns' "$SKILL_MD"
  [ "$status" -eq 0 ]
}

@test "AC5 / TC-MTG-NOFAB-1: §Phase 3 and §Phase 4 reinforcement sentences are character-identical" {
  [ -f "$SKILL_MD" ]
  # Pull the canonical sentence — the literal text from AC5.
  run grep -F 'Only invited agents post preludes and DISCUSS turns. The user does not appear as a turn author in either phase.' "$SKILL_MD"
  [ "$status" -eq 0 ]
  # Must appear at least twice (once under each section).
  count="$(grep -cF 'Only invited agents post preludes and DISCUSS turns. The user does not appear as a turn author in either phase.' "$SKILL_MD")"
  [ "$count" -ge 2 ]
}
