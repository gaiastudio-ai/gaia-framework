#!/usr/bin/env bats
# discovery-graduate.bats -- graduation track auto-detect, per-track bars,
# AI-id fail-closed validation, --from-discovery hydration bridge, and
# graduate side-effect ordering tests for discovery-board.sh graduate
# subcommand.
#
# Test case families:
#   TC-DISCTRACK-1..6  — track detection + per-track minimum bar
#   TC-DISCFROM-1..4   — --from-discovery bridge behaviour
#
# Public functions covered: cmd_graduate, _detect_track, _validate_track_bar,
# _validate_ai_id, _sanitize_field, _confine_path, main.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/discovery-board.sh"
  export PROJECT_ROOT="$TEST_TMP"
  BOARD_DIR="$TEST_TMP/.gaia/state"
  BOARD_FILE="$BOARD_DIR/discovery-board.yaml"
  AI_FILE="$TEST_TMP/.gaia/state/action-items.yaml"
  mkdir -p "$BOARD_DIR"
  TESTDATE="2099-01-01"
}
teardown() { common_teardown; }

# ---------- helpers ----------

# seed_board_full — seed a board item with all graduation-relevant fields.
# Usage: seed_board_full <id> <status> <priority> <horizon> <title> <source> <artifacts> <decision_link>
seed_board_full() {
  local id="$1" status="${2-Evaluated}" priority="${3-High}" horizon="${4-Now}"
  local title="${5-Test idea}" source="${6-manual}" artifacts="${7-[]}" decision_link="${8-}"
  printf 'items:\n' > "$BOARD_FILE"
  printf '  - id: "%s"\n' "$id" >> "$BOARD_FILE"
  printf '    title: "%s"\n' "$title" >> "$BOARD_FILE"
  printf '    source: "%s"\n' "$source" >> "$BOARD_FILE"
  printf '    status: "%s"\n' "$status" >> "$BOARD_FILE"
  printf '    research_type: []\n' >> "$BOARD_FILE"
  printf '    artifacts: %s\n' "$artifacts" >> "$BOARD_FILE"
  printf '    value_signal: ""\n' >> "$BOARD_FILE"
  printf '    effort_signal: ""\n' >> "$BOARD_FILE"
  printf '    priority: "%s"\n' "$priority" >> "$BOARD_FILE"
  printf '    horizon: "%s"\n' "$horizon" >> "$BOARD_FILE"
  printf '    decision_link: "%s"\n' "$decision_link" >> "$BOARD_FILE"
  printf '    graduated_feature_id: ""\n' >> "$BOARD_FILE"
  printf '    created_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    last_activity: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
  printf '    status_changed_at: "%sT00:00:00Z"\n' "$TESTDATE" >> "$BOARD_FILE"
}

# seed_action_items — write a minimal action-items.yaml with given entries.
# Usage: seed_action_items <id> <status>
seed_action_items() {
  printf 'schema_version: 2\nitems:\n' > "$AI_FILE"
  while [ $# -ge 2 ]; do
    local ai_id="$1" ai_status="$2"
    shift 2
    printf '%s' "- id: ${ai_id}" >> "$AI_FILE"
    printf '\n  status: %s\n  text: "test"\n  classification: implementation\n' \
      "$ai_status" >> "$AI_FILE"
  done
}

# seed_artifact — create a fake artifact file relative to PROJECT_ROOT.
seed_artifact() {
  local relpath="$1"
  mkdir -p "$TEST_TMP/$(dirname "$relpath")"
  printf 'artifact content\n' > "$TEST_TMP/$relpath"
}

# =====================================================================
# TC-DISCTRACK-1: fast-track — accept at minimum bar (AC1)
# =====================================================================

@test "graduate auto-detects fast track and accepts item meeting minimum bar (AC1)" {
  # Fast track: no artifacts, no decision_link, has title+source+priority+horizon.
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Quick win" "user-feedback" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"fast"* ]] || [[ "$output" == *"Graduated"* ]]
}

# =====================================================================
# TC-DISCTRACK-2: fast-track — reject below bar (AC1)
# =====================================================================

@test "graduate rejects fast-track item missing priority (AC1)" {
  seed_board_full "ITEM-1" "Evaluated" "" "Now" "Idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"priority"* ]]
}

@test "graduate rejects fast-track item missing horizon (AC1)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "" "Idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"horizon"* ]]
}

@test "graduate rejects item missing title (AC1)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"title"* ]]
}

@test "graduate rejects item missing source (AC1)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"source"* ]]
}

# =====================================================================
# TC-DISCTRACK-3: research-track — accept with resolvable artifact (AC1)
# =====================================================================

@test "graduate auto-detects research track and accepts when cited artifact resolves (AC1)" {
  # Research track: artifacts non-empty, no decision_link.
  seed_artifact ".gaia/artifacts/research-artifacts/market-scan.md"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Research idea" "analyst" \
    '["'.gaia/artifacts/research-artifacts/market-scan.md'"]' ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"research"* ]] || [[ "$output" == *"Graduated"* ]]
}

# =====================================================================
# TC-DISCTRACK-4: research-track — reject when cited artifact is dangling (AC1)
# =====================================================================

@test "graduate rejects research-track item when cited artifact does not resolve on disk (AC1)" {
  # Artifact path does not exist.
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Research idea" "analyst" \
    '["'.gaia/artifacts/research-artifacts/phantom.md'"]' ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolve"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"artifact"* ]]
}

# =====================================================================
# TC-DISCTRACK-5: decision-track — accept with valid AI-id (AC1, AC2)
# =====================================================================

@test "graduate auto-detects decision track and accepts with valid active AI-id (AC1, AC2)" {
  # Decision track: decision_link is a non-null AI-id.
  seed_action_items "AI-2099-01-01-1" "open"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Decision follow-up" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"decision"* ]] || [[ "$output" == *"Graduated"* ]]
}

@test "graduate accepts decision track with legacy short-form AI-id (AC2)" {
  seed_action_items "AI-42" "open"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Legacy item" "retro" "[]" "AI-42"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -eq 0 ]
}

# =====================================================================
# TC-DISCTRACK-6: decision-track — reject on degenerate AI-id inputs (AC2)
# =====================================================================

@test "graduate rejects decision-track when AI-id is absent from action-items (AC2)" {
  seed_action_items "AI-2099-01-01-1" "open"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-99"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"absent"* ]]
}

@test "graduate rejects decision-track when AI-id is soft-deleted (status=invalid) (AC2)" {
  seed_action_items "AI-2099-01-01-1" "invalid"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"soft-deleted"* ]] || [[ "$output" == *"invalid"* ]] || [[ "$output" == *"not graduatable"* ]]
}

@test "graduate rejects decision-track when AI-id is soft-deleted (status=resolved) (AC2)" {
  seed_action_items "AI-2099-01-01-1" "resolved"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"soft-deleted"* ]] || [[ "$output" == *"resolved"* ]] || [[ "$output" == *"not graduatable"* ]]
}

@test "graduate rejects decision-track when AI-id is soft-deleted (status=deleted) (AC2)" {
  seed_action_items "AI-2099-01-01-1" "deleted"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
}

@test "graduate fails closed when action-items.yaml is missing (AC2)" {
  # No AI_FILE created.
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"action-items"* ]] || [[ "$output" == *"missing"* ]]
}

@test "graduate fails closed when action-items.yaml is empty (AC2)" {
  printf '' > "$AI_FILE"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
}

@test "graduate fails closed when action-items.yaml is unparseable (AC2)" {
  printf '{{{{bad yaml\n' > "$AI_FILE"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-2099-01-01-1"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
}

@test "graduate rejects decision-track with substring match — exact key required (AC2)" {
  # AI-1 exists, but item links to AI-10 — substring match must NOT pass.
  seed_action_items "AI-1" "open"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "meeting" "[]" "AI-10"
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
}

# =====================================================================
# Track bar composes AND with priority+horizon gate
# =====================================================================

@test "graduate enforces priority+horizon gate even when track bar passes (AC1)" {
  # Research track with resolvable artifact but missing priority.
  seed_artifact ".gaia/artifacts/research-artifacts/scan.md"
  seed_board_full "ITEM-1" "Evaluated" "" "Now" "Research" "analyst" \
    '["'.gaia/artifacts/research-artifacts/scan.md'"]' ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"priority"* ]]
}

# =====================================================================
# Graduate must only work from legal source states
# =====================================================================

@test "graduate rejects an item in Captured state — must be Evaluated first (AC1)" {
  seed_board_full "ITEM-1" "Captured" "High" "Now" "Raw idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Evaluated"* ]] || [[ "$output" == *"Captured"* ]]
}

@test "graduate rejects an already-Graduated item (AC1)" {
  seed_board_full "ITEM-1" "Graduated" "High" "Now" "Done idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]] || [[ "$output" == *"already"* ]] || [[ "$output" == *"Graduated"* ]]
}

# =====================================================================
# TC-DISCFROM-1: --from-discovery hydrator emits hydrated intake (AC3)
# =====================================================================

@test "graduate --from-discovery emits hydrated intake fields on stdout (AC3)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Add caching layer" "user-feedback" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  [ "$status" -eq 0 ]
  # Must emit description, urgency, driver as hydrated fields.
  [[ "$output" == *"description:"* ]]
  [[ "$output" == *"urgency:"* ]]
  [[ "$output" == *"driver:"* ]]
  # Must NOT emit classification (classification is RE-DERIVED).
  assert_file_excludes <(printf '%s\n' "$output") "classification:"
}

# =====================================================================
# TC-DISCFROM-2: --from-discovery SKILL.md no-bypass contract (AC3)
# =====================================================================

@test "SKILL.md documents that --from-discovery does NOT bypass scope-confirmation or Step 1c (AC3)" {
  local skill_file
  skill_file="$(cd "$BATS_TEST_DIRNAME/../skills/gaia-add-feature" && pwd)/SKILL.md"
  # The SKILL.md must contain explicit prose stating no bypass.
  grep -qi 'from-discovery' "$skill_file"
  # Must mention scope-confirmation is preserved.
  grep -qi 'scope.confirm' "$skill_file" || grep -qi 'scope confirm' "$skill_file" || \
    grep -qi 'confirmation.*prompt' "$skill_file"
  # Must mention Step 1c re-validation is preserved.
  grep -qi 'Step 1c' "$skill_file"
  # Must explicitly state no bypass / not bypass / preserve.
  grep -qiE '(no bypass|not bypass|preserve|still.*shows|still.*runs)' "$skill_file"
}

# =====================================================================
# TC-DISCFROM-3: --from-discovery rejects invalid/unknown id (AC3)
# =====================================================================

@test "graduate --from-discovery rejects unknown board item id before hydration (AC3)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-MISSING --from-discovery
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"ITEM-MISSING"* ]]
}

# =====================================================================
# TC-DISCFROM-4: --from-discovery rejects terminal non-graduated id (AC3)
# =====================================================================

@test "graduate --from-discovery rejects Archived (terminal non-graduated) item (AC3)" {
  seed_board_full "ITEM-1" "Archived" "High" "Now" "Dead idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]] || [[ "$output" == *"Archived"* ]]
}

@test "graduate --from-discovery rejects already-Graduated item (AC3)" {
  seed_board_full "ITEM-1" "Graduated" "High" "Now" "Already done" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]] || [[ "$output" == *"already"* ]] || [[ "$output" == *"Graduated"* ]]
}

# =====================================================================
# AC4: hydrated fields — sanitization (untrusted data handling)
# =====================================================================

@test "graduate --from-discovery strips control characters from hydrated title (AC4)" {
  # Title with embedded control chars (BEL, ESC).
  local hostile_title
  hostile_title="$(printf 'Hostile\x07title\x1b[31mred')"
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "$hostile_title" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  [ "$status" -eq 0 ]
  # Output must not contain the control characters.
  assert_file_excludes <(printf '%s\n' "$output") $'\x07'
  assert_file_excludes <(printf '%s\n' "$output") $'\x1b'
}

@test "graduate --from-discovery length-caps overly long title (AC4)" {
  # Title longer than 500 chars.
  local long_title
  long_title=$(printf 'A%.0s' $(seq 1 600))
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "$long_title" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  [ "$status" -eq 0 ]
  # Description in output must be capped.
  local desc_line
  desc_line=$(printf '%s\n' "$output" | grep 'description:')
  [ "${#desc_line}" -le 520 ]
}

@test "graduate --from-discovery rejects artifact path with traversal (AC4)" {
  # Artifact with ../ traversal.
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "manual" \
    '["'../../etc/passwd'"]' ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  # Must either reject outright or sanitize the path — not emit the traversal.
  if [ "$status" -eq 0 ]; then
    assert_file_excludes <(printf '%s\n' "$output") "../"
  fi
  # If status is non-zero, that is also acceptable (fail closed on bad path).
  true
}

@test "graduate --from-discovery rejects absolute path outside repo (AC4)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Idea" "manual" \
    '["/etc/passwd"]' ""
  run "$SCRIPT" graduate --id ITEM-1 --from-discovery
  if [ "$status" -eq 0 ]; then
    assert_file_excludes <(printf '%s\n' "$output") "/etc/passwd"
  fi
  true
}

# =====================================================================
# AC5: graduate side-effect ordering — transition AFTER backlog lands
# =====================================================================

@test "graduate transitions to Graduated only after emitting hydrated intake (AC5)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Ordered idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -eq 0 ]
  # Item must now be Graduated.
  grep -qE 'status:.*Graduated' "$BOARD_FILE"
}

@test "graduate stamps graduated_feature_id after successful graduation (AC5)" {
  seed_board_full "ITEM-1" "Evaluated" "High" "Now" "Ordered idea" "manual" "[]" ""
  run "$SCRIPT" graduate --id ITEM-1 --feature-id "AF-2099-01-01-1"
  [ "$status" -eq 0 ]
  grep -qE 'graduated_feature_id:.*AF-2099-01-01-1' "$BOARD_FILE"
}

@test "graduate failure leaves item in Evaluated state — re-entrancy preserved (AC5)" {
  # Item without priority — graduation will fail; item must stay Evaluated.
  seed_board_full "ITEM-1" "Evaluated" "" "Now" "Idea" "manual" "[]" ""
  local before_sha
  before_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')

  run "$SCRIPT" graduate --id ITEM-1
  [ "$status" -ne 0 ]

  local after_sha
  after_sha=$(shasum -a 256 "$BOARD_FILE" | awk '{print $1}')
  [ "$before_sha" = "$after_sha" ]
}

# =====================================================================
# graduate usage in help
# =====================================================================

# =====================================================================
# YAML multi-line scalar injection — writer-side sanitization (AC2, AC4)
# These tests seed via the REAL capture write path to prove the exploit
# is dead end-to-end.
# =====================================================================

@test "capture sanitizes hostile title with injected newline+field lines — decision_link not forged (AC2)" {
  # Hostile title that, pre-fix, would inject a fake decision_link + priority + horizon.
  local hostile
  hostile="$(printf 'evil\n    decision_link: AI-OPEN\n    priority: High\n    horizon: Now')"
  run "$SCRIPT" capture --title "$hostile" --source "legit-source"
  [ "$status" -eq 0 ]
  # Extract the minted id.
  local item_id
  item_id=$(printf '%s\n' "$output" | grep -oE 'DISC-[0-9-]+')
  [ -n "$item_id" ]

  # The board file must have NO multi-line scalar — the hostile newlines
  # must be stripped, so the title is a single line.  The ACTUAL
  # decision_link field (written by capture as empty) must be empty.
  # Use a precise grep: match only lines starting with exactly "    decision_link:"
  # (the field indent, not inside a quoted value).
  local dl_line
  dl_line=$(grep -E '^[[:space:]]+decision_link:' "$BOARD_FILE" | head -1)
  # The real decision_link field must be empty (the default "").
  [[ "$dl_line" == *'""'* ]] || [[ "$dl_line" == *"''"* ]]

  # The title must be a single line (no embedded newlines in the file).
  local title_lines
  title_lines=$(grep -c 'title:' "$BOARD_FILE")
  [ "$title_lines" -eq 1 ]

  # Transition to Evaluated, then attempt graduation — must NOT graduate
  # via decision track (would require a real decision_link).
  run "$SCRIPT" prioritize --id "$item_id" --priority High --horizon Now
  [ "$status" -eq 0 ]
  run "$SCRIPT" transition --id "$item_id" --to Evaluated
  [ "$status" -eq 0 ]
  run "$SCRIPT" graduate --id "$item_id"
  [ "$status" -eq 0 ]
  # Must graduate via fast track, not decision track.
  [[ "$output" == *"fast"* ]]
}

@test "capture sanitizes hostile source with injected newline+field lines — decision_link not forged (AC4)" {
  # Same injection pattern but through the source field.
  local hostile_src
  hostile_src="$(printf 'legit\n    decision_link: AI-FORGED\n    priority: Critical\n    horizon: Later')"
  run "$SCRIPT" capture --title "Harmless title" --source "$hostile_src"
  [ "$status" -eq 0 ]
  local item_id
  item_id=$(printf '%s\n' "$output" | grep -oE 'DISC-[0-9-]+')
  [ -n "$item_id" ]

  # The real decision_link field must be empty.
  local dl_line
  dl_line=$(grep -E '^[[:space:]]+decision_link:' "$BOARD_FILE" | head -1)
  [[ "$dl_line" == *'""'* ]] || [[ "$dl_line" == *"''"* ]]

  # The source must be a single line (no embedded newlines in the file).
  local source_lines
  source_lines=$(grep -c 'source:' "$BOARD_FILE")
  [ "$source_lines" -eq 1 ]

  # The source value should contain "legit" (sanitized, flattened).
  local source_val
  source_val=$(grep 'source:' "$BOARD_FILE" | head -1)
  [[ "$source_val" == *"legit"* ]]
}

@test "discovery-board.sh --help lists graduate subcommand (AC1)" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"graduate"* ]]
}
