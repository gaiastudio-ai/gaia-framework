#!/usr/bin/env bats
# e76-s24-meeting-notes-subdir.bats — TC-MNOTE-1..4.
# Meeting notes write under creative-artifacts/meeting-notes/; the subpath
# passes write-boundary; pre-existing flat-location notes migrate; the SKILL.md
# dispatch sections carry the surface contract.

setup() {
  PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WRITER="$PLUGIN/skills/gaia-meeting/scripts/meeting-notes-writer.sh"
  BOUNDARY="$PLUGIN/skills/gaia-meeting/scripts/write-boundary.sh"
  SKILL="$PLUGIN/skills/gaia-meeting/SKILL.md"
  ROOT="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$ROOT/.gaia/artifacts/creative-artifacts"
  PAYLOAD="$BATS_TEST_TMPDIR/payload.yaml"
  cat > "$PAYLOAD" <<'EOF'
charter: "Test charter"
mode: clarify
total_tokens: 100
summary: "A test summary."
transcript: |
  some transcript
preludes: |
  some prelude
EOF
}

# TC-MNOTE-1 — writer emits the notes file under meeting-notes/ (not flat).
@test "TC-MNOTE-1: meeting notes write under creative-artifacts/meeting-notes/" {
  run "$WRITER" --root "$ROOT" --payload "$PAYLOAD" --date 2026-06-11 --slug test-meeting
  [ "$status" -eq 0 ]
  [ -f "$ROOT/.gaia/artifacts/creative-artifacts/meeting-notes/meeting-2026-06-11-test-meeting.md" ]
  # NOT at the old flat location.
  [ ! -f "$ROOT/.gaia/artifacts/creative-artifacts/meeting-2026-06-11-test-meeting.md" ]
}

# TC-MNOTE-2 — the meeting-notes/ subpath passes write-boundary.sh (exit 0).
@test "TC-MNOTE-2: meeting-notes/ subpath passes write-boundary" {
  run "$BOUNDARY" ".gaia/artifacts/creative-artifacts/meeting-notes/meeting-2026-06-11-x.md"
  [ "$status" -eq 0 ]
}

# TC-MNOTE-3 — a pre-existing flat-location note is migrated into meeting-notes/.
@test "TC-MNOTE-3: back-compat migrates a pre-existing flat note into the subdir" {
  # Simulate an old flat-layout note for the same meeting.
  old="$ROOT/.gaia/artifacts/creative-artifacts/meeting-2026-06-11-legacy.md"
  printf 'OLD_FLAT_NOTE_SENTINEL\n' > "$old"
  run "$WRITER" --root "$ROOT" --payload "$PAYLOAD" --date 2026-06-11 --slug legacy
  [ "$status" -eq 0 ]
  # The new write lands in the subdir...
  [ -f "$ROOT/.gaia/artifacts/creative-artifacts/meeting-notes/meeting-2026-06-11-legacy.md" ]
  # ...and the old flat file is gone (migrated, not orphaned).
  [ ! -f "$old" ]
}

# TC-MNOTE-4 — SKILL.md carries the NEW per-turn surface contracts for both
# RESEARCH and DISCUSS (distinct from the pre-existing Mode-A warning relay).
@test "TC-MNOTE-4: SKILL.md mandates surfacing research/discuss output to the user" {
  # Both the RESEARCH and the DISCUSS surface contracts must be present.
  grep -qF "Surface contract (RESEARCH output to the user)" "$SKILL"
  grep -qF "Surface contract (DISCUSS output to the user)" "$SKILL"
  # Each must mandate relaying the subagent body to the user (not just the
  # Mode-A warning, which is a separate, pre-existing contract).
  grep -qiE "RELAY each invitee's returned prelude body to the user" "$SKILL"
  grep -qiE "RELAY every DISCUSS turn body to the user" "$SKILL"
}
