#!/usr/bin/env bats
# user-as-attendee.bats — gaia-meeting user-as-first-class-attendee path (E76-S21)
#
# AF-2026-05-10-2 / AI-2026-05-09-9 / FR-MTG-10 (amended).
#
# Verifies the resolve-invitees.sh user-token carve-out:
#   - When --invitees CSV contains `me` / `user` (case-insensitive) or a token
#     equal to the resolved user name, the token is PRESERVED in the resolved
#     CSV (not dropped) AND no WARNING is emitted to stderr AND session-state
#     `user_attendance: true` is set.
#   - When --invitees CSV contains no user-token, session-state
#     `user_attendance: false` is set AND existing turn-arbitration regression
#     behavior (E76-S8 / TC-MTG-NOFAB-3b) continues to apply.
#
# Tests:
#   - TC-MTG-USER-1: `me` token preserved, no WARNING, user_attendance=true
#   - TC-MTG-USER-2: `USER` token (case-insensitive) preserved, user_attendance=true
#   - TC-MTG-USER-3: resolved-user-name token (case-insensitive) preserved, user_attendance=true
#   - TC-MTG-USER-4: no user-token → user_attendance=false; regression E76-S8 invariant active
#   - TC-MTG-USER-6: session-state schema contains user_attendance field
#   - TC-MTG-NOFAB-3a (PRIMARY E76-S21): no WARNING when user explicitly invited
#
# TC-MTG-USER-5 is manual transcript inspection — see manual-fixtures/.
# TC-MTG-USER-7 (SKILL.md prose verification) is owned by the
# gaia-meeting-user-as-attendee-carve-out.bats file (E76-S20).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills/gaia-meeting"
  RESOLVE_INVITEES="$SKILL_DIR/scripts/resolve-invitees.sh"
  SESSION_STATE="$SKILL_DIR/scripts/session-state.sh"
  RESOLVE_USER="$SKILL_DIR/scripts/resolve-user-name.sh"

  export LC_ALL=C

  TMP="$(mktemp -d)"
  INSTALLED="$TMP/installed.txt"
  SESSION_FILE="$TMP/session.yaml"
  SETTINGS_FILE="$TMP/settings.json"

  # Minimal installed list — only matters for default-invitee resolution which
  # we don't exercise here; the user-token branch is upstream of the installed
  # check.
  : > "$INSTALLED"

  # Seed a session-state file via the canonical create path (so the schema
  # lines we expect already exist, including user_attendance once added).
  "$SESSION_STATE" create --file "$SESSION_FILE" --session-id "test-session-1"

  # Resolve user name (settings.json override > git config). Tests that depend
  # on a resolvable name skip cleanly on CI runners without git config
  # user.name and without a discoverable settings.json — same pattern as
  # `no-fabricated-user-turns.bats` so this suite stays portable.
  if USER_NAME="$("$RESOLVE_USER" 2>/dev/null)"; then
    export USER_NAME
  else
    USER_NAME=""
  fi
}

teardown() {
  rm -rf "$TMP"
}

# Helper: invoke resolve-invitees.sh with the user-token carve-out plumbing.
# Always passes --session-file so the script knows where to update the
# user_attendance flag.
run_resolver() {
  run "$RESOLVE_INVITEES" \
    --mode "decide" \
    --invitees "$1" \
    --installed "$INSTALLED" \
    --session-file "$SESSION_FILE"
}

# ----- TC-MTG-USER-1 — `me` token preserved + user_attendance=true ------------

@test "TC-MTG-USER-1: --invitees alice,me,bob preserves 'me' and sets user_attendance=true" {
  run_resolver "alice,me,bob"
  [ "$status" -eq 0 ]
  # 'me' MUST appear in resolved= line.
  echo "$output" | grep -E "^resolved=.*\bme\b" >/dev/null
  # No WARNING about user-token.
  ! echo "$output" | grep -q "resolves to the user"
  # session-state user_attendance=true.
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "true" ]
}

# ----- TC-MTG-USER-2 — case-insensitive `USER` token --------------------------

@test "TC-MTG-USER-2: --invitees Theo,USER,Lyra preserves 'USER' (case-insensitive) and sets user_attendance=true" {
  run_resolver "Theo,USER,Lyra"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E "^resolved=.*USER" >/dev/null
  ! echo "$output" | grep -q "resolves to the user"
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "true" ]
}

# ----- TC-MTG-USER-3 — resolved-user-name token (case-insensitive) ------------

@test "TC-MTG-USER-3: --invitees containing case-insensitive resolved-user-name preserves token and sets user_attendance=true" {
  # CI runners without git config user.name + without a discoverable
  # settings.json cannot resolve a name — skip cleanly so this row never
  # blocks the build (TC-MTG-USER-1/2 already cover the literal-token paths
  # and do not depend on a resolved name). Mirrors the
  # `no-fabricated-user-turns.bats` skip-when-no-name pattern.
  if [ -z "$USER_NAME" ]; then
    skip "resolve-user-name.sh did not resolve a name on this runner"
  fi
  # Lowercase the resolved user name to verify case-insensitive matching.
  # The resolver trims surrounding whitespace from each CSV token but does
  # not split on internal whitespace, so a multi-word resolved name (e.g.,
  # "Julien Louage") round-trips as a single token.
  lower_name="$(printf '%s' "$USER_NAME" | tr '[:upper:]' '[:lower:]')"
  run_resolver "${lower_name},christy"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E "^resolved=.*${lower_name}" >/dev/null
  ! echo "$output" | grep -q "resolves to the user"
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "true" ]
}

# ----- TC-MTG-USER-4 — no user-token → user_attendance=false ------------------

@test "TC-MTG-USER-4: --invitees alice,bob (no user-token) sets user_attendance=false and emits no carve-out WARNING" {
  run_resolver "alice,bob"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "resolves to the user"
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "false" ]
}

# ----- TC-MTG-USER-6 — session-state schema field -----------------------------

@test "TC-MTG-USER-6: session-state.sh schema contains user_attendance field" {
  # The schema field MUST be present in the FIELDS array and round-trip via
  # update/read.
  "$SESSION_STATE" update --file "$SESSION_FILE" --field user_attendance --value "true"
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "true" ]
  "$SESSION_STATE" update --file "$SESSION_FILE" --field user_attendance --value "false"
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "false" ]
}

# ----- TC-MTG-NOFAB-3a (PRIMARY E76-S21) — no WARNING when user invited -------

@test "TC-MTG-NOFAB-3a: --invitees me,alice emits NO WARNING and preserves 'me'" {
  run_resolver "me,alice"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "resolves to the user"
  echo "$output" | grep -E "^resolved=.*\bme\b" >/dev/null
}

# ----- Backward-compat: resolver still works without --session-file -----------

@test "Resolver still works without --session-file (backward compatibility)" {
  run "$RESOLVE_INVITEES" \
    --mode "decide" \
    --invitees "alice,bob" \
    --installed "$INSTALLED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E "^resolved=.*alice" >/dev/null
}

# ----- Forward-compat: --session-file with no user-token sets false -----------

@test "User-token absent + --session-file present sets user_attendance=false explicitly" {
  # Pre-set to true to verify the false branch overwrites it.
  "$SESSION_STATE" update --file "$SESSION_FILE" --field user_attendance --value "true"
  run_resolver "alice,bob"
  [ "$status" -eq 0 ]
  flag="$("$SESSION_STATE" read --file "$SESSION_FILE" --field user_attendance)"
  [ "$flag" = "false" ]
}
