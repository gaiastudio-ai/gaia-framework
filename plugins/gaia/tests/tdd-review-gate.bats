#!/usr/bin/env bats
# tdd-review-gate.bats — bats coverage for E57-S2
#
# Story: E57-S2 — tdd-review-gate.sh script — SKIP/PROMPT/QA_AUTO decision
#
# Acceptance Criteria covered:
#   AC1 — threshold=medium, phases=[red], risk=medium, phase=red, non-YOLO
#         -> PROMPT  (TC-TDR-01)
#   AC2 — threshold=high, risk=medium -> SKIP at any phase  (TC-TDR-03)
#   AC3 — threshold=medium, phases=[red,green], phase=refactor -> SKIP
#   AC4 — threshold=medium, risk=high, phase in phases, YOLO active,
#         qa_auto_in_yolo=true -> QA_AUTO  (TC-TDR-02)
#   AC5 — missing risk_level frontmatter -> safe default high; PROMPT
#         (or QA_AUTO under YOLO) + stderr warning  (TC-TDR-03, NFR-TDR-1)
#   AC6 — malicious story_key (path traversal) -> non-zero exit, no read.
#
# Decision matrix (in order):
#   1. threshold == off            -> SKIP
#   2. <phase> not in phases       -> SKIP
#   3. risk-rank < threshold-rank  -> SKIP   (rank: off=0,low=1,medium=2,high=3)
#   4. YOLO active AND qa_auto_in_yolo -> QA_AUTO
#   5. else                        -> PROMPT
#
# Per-test fixtures live under $TEST_TMP — never mutate committed config.
#
# Refs: FR-TDR-2, NFR-TDR-1, AF-2026-04-28-6.

load 'test_helper.bash'

# The script under test lives in the gaia-dev-story skill's scripts/ dir.
GATE_SCRIPT_REL="../skills/gaia-dev-story/scripts/tdd-review-gate.sh"

setup() {
  common_setup
  GATE="$(cd "$BATS_TEST_DIRNAME/$(dirname "$GATE_SCRIPT_REL")" && pwd)/$(basename "$GATE_SCRIPT_REL")"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REAL_SCHEMA="$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml"

  # Per-test fixture: minimal project-config.yaml + schema + a story file.
  cd "$TEST_TMP"
  mkdir -p config docs/implementation-artifacts

  cp "$REAL_SCHEMA" "$TEST_TMP/config/project-config.schema.yaml"

  cat > "$TEST_TMP/config/project-config.yaml" <<EOF
project_root: $TEST_TMP
project_path: $TEST_TMP
memory_path: $TEST_TMP/_memory
checkpoint_path: $TEST_TMP/_memory/checkpoints
installed_path: $TEST_TMP/_gaia
framework_version: 1.131.0
date: 2026-04-28
EOF

  # Point resolve-config.sh at our temp config (no relying on PWD chasing).
  export GAIA_SHARED_CONFIG="$TEST_TMP/config/project-config.yaml"

  # Default story file: E99-S1 with risk: medium.
  STORY_KEY="E99-S1"
  STORY_FILE="$TEST_TMP/docs/implementation-artifacts/${STORY_KEY}-test.md"
  cat > "$STORY_FILE" <<'EOF'
---
template: 'story'
key: "E99-S1"
status: in-progress
risk: "medium"
epic: "E99"
---

# Story: test fixture
EOF

  # Clear any inherited YOLO state.
  unset GAIA_YOLO_FLAG
  unset GAIA_YOLO_MODE
  unset GAIA_YOLO_OVERRIDE
  unset GAIA_CONTEXT
}

teardown() { common_teardown; }

# Helper — write a story file with a custom risk frontmatter (or no risk
# field at all when $2 is the literal string "NORISK").
write_story() {
  local key="$1" risk="$2"
  local f="$TEST_TMP/docs/implementation-artifacts/${key}-test.md"
  if [ "$risk" = "NORISK" ]; then
    cat > "$f" <<EOF
---
template: 'story'
key: "$key"
status: in-progress
epic: "${key%-S*}"
---

# Story: missing risk fixture
EOF
  else
    cat > "$f" <<EOF
---
template: 'story'
key: "$key"
status: in-progress
risk: "$risk"
epic: "${key%-S*}"
---

# Story: $risk risk fixture
EOF
  fi
}

# Helper — write extra config keys under dev_story.tdd_review.
configure_tdd_review() {
  local threshold="$1" phases="$2" qa_auto="$3"
  cat >> "$TEST_TMP/config/project-config.yaml" <<EOF
dev_story:
  tdd_review:
    threshold: $threshold
    phases: $phases
    qa_auto_in_yolo: $qa_auto
EOF
}

# ---------------------------------------------------------------------------
# AC1 — default config (threshold=medium, phases=[red]) + risk=medium + red
#       phase + non-YOLO -> PROMPT.
# ---------------------------------------------------------------------------

@test "AC1: threshold=medium + risk=medium + phase=red + non-YOLO -> PROMPT" {
  run "$GATE" E99-S1 red
  [ "$status" -eq 0 ]
  [ "$output" = "PROMPT" ]
}

# ---------------------------------------------------------------------------
# AC2 — risk below threshold -> SKIP (any phase).
# ---------------------------------------------------------------------------

@test "AC2: threshold=high + risk=medium + phase=red -> SKIP" {
  configure_tdd_review high "[red]" true
  run "$GATE" E99-S1 red
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

@test "AC2: threshold=high + risk=medium + phase=green -> SKIP" {
  configure_tdd_review high "[red, green]" true
  run "$GATE" E99-S1 green
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

@test "AC2: threshold=high + risk=medium + phase=refactor -> SKIP" {
  configure_tdd_review high "[red, green, refactor]" true
  run "$GATE" E99-S1 refactor
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

# ---------------------------------------------------------------------------
# AC3 — phase not in configured phases -> SKIP.
# ---------------------------------------------------------------------------

@test "AC3: phases=[red,green] + phase=refactor -> SKIP" {
  configure_tdd_review medium "[red, green]" true
  run "$GATE" E99-S1 refactor
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

@test "AC3: phases=[red] + phase=green -> SKIP" {
  # Default config (medium / [red] / true).
  run "$GATE" E99-S1 green
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

# ---------------------------------------------------------------------------
# AC4 — YOLO active + qa_auto_in_yolo=true -> QA_AUTO.
# ---------------------------------------------------------------------------

@test "AC4: YOLO + qa_auto_in_yolo=true + risk>=threshold -> QA_AUTO" {
  write_story E99-S2 high
  configure_tdd_review medium "[red]" true
  GAIA_YOLO_FLAG=1 run "$GATE" E99-S2 red
  [ "$status" -eq 0 ]
  [ "$output" = "QA_AUTO" ]
}

@test "AC4: YOLO + qa_auto_in_yolo=false -> PROMPT (not QA_AUTO)" {
  write_story E99-S2 high
  configure_tdd_review medium "[red]" false
  GAIA_YOLO_FLAG=1 run "$GATE" E99-S2 red
  [ "$status" -eq 0 ]
  [ "$output" = "PROMPT" ]
}

# ---------------------------------------------------------------------------
# Threshold matrix corners — off rank.
# ---------------------------------------------------------------------------

@test "threshold=off -> SKIP regardless of risk/phase/YOLO" {
  configure_tdd_review off "[red, green, refactor]" true
  run "$GATE" E99-S1 red
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

@test "threshold=low + risk=low -> PROMPT" {
  write_story E99-S3 low
  configure_tdd_review low "[red]" true
  run "$GATE" E99-S3 red
  [ "$status" -eq 0 ]
  [ "$output" = "PROMPT" ]
}

@test "threshold=low + risk=high -> PROMPT (high >= low)" {
  write_story E99-S4 high
  configure_tdd_review low "[red]" true
  run "$GATE" E99-S4 red
  [ "$status" -eq 0 ]
  [ "$output" = "PROMPT" ]
}

@test "threshold=high + risk=high -> PROMPT (boundary)" {
  write_story E99-S5 high
  configure_tdd_review high "[red]" true
  run "$GATE" E99-S5 red
  [ "$status" -eq 0 ]
  [ "$output" = "PROMPT" ]
}

# ---------------------------------------------------------------------------
# AC5 — missing/unrecognized risk_level -> safe default high; gate fires
# (PROMPT or QA_AUTO depending on YOLO branch). Stderr names the missing field.
# ---------------------------------------------------------------------------

@test "AC5: missing risk_level -> PROMPT + stderr warning" {
  write_story E99-S6 NORISK
  run "$GATE" E99-S6 red
  [ "$status" -eq 0 ]
  # Stdout: PROMPT (high risk treated as >= medium threshold).
  [[ "$output" == *"PROMPT"* ]]
  # Stderr is merged into output by `run`. Look for the warning naming the
  # offending field — we accept either 'risk' or 'risk_level' phrasing.
  [[ "$output" == *"risk"* ]]
}

@test "AC5: unrecognized risk value -> PROMPT + stderr warning" {
  write_story E99-S7 banana
  run "$GATE" E99-S7 red
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMPT"* ]]
  [[ "$output" == *"risk"* ]]
}

@test "AC5: missing risk_level under YOLO + qa_auto_in_yolo=true -> QA_AUTO" {
  write_story E99-S8 NORISK
  configure_tdd_review medium "[red]" true
  GAIA_YOLO_FLAG=1 run "$GATE" E99-S8 red
  [ "$status" -eq 0 ]
  [[ "$output" == *"QA_AUTO"* ]]
}

# ---------------------------------------------------------------------------
# AC6 — malicious story_key rejected before any read.
# ---------------------------------------------------------------------------

@test "AC6: path-traversal story_key -> non-zero exit" {
  run "$GATE" "../etc/passwd" red
  [ "$status" -ne 0 ]
}

@test "AC6: empty story_key -> non-zero exit" {
  run "$GATE" "" red
  [ "$status" -ne 0 ]
}

@test "AC6: lowercase story_key -> non-zero exit (must match ^E[0-9]+-S[0-9]+\$)" {
  run "$GATE" "e99-s1" red
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Usage / arg validation.
# ---------------------------------------------------------------------------

@test "no args -> non-zero exit (usage)" {
  run "$GATE"
  [ "$status" -ne 0 ]
}

@test "missing phase arg -> non-zero exit (usage)" {
  run "$GATE" E99-S1
  [ "$status" -ne 0 ]
}

@test "unknown phase value -> SKIP (phase not in any configured phases list)" {
  run "$GATE" E99-S1 not-a-phase
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

# E55-S13 D3 (TC-DSF-3): tdd-review-gate.sh MUST source resolve-story-file.sh
# (E79-S7 shared helper) instead of using a private IMPL_DIR/${STORY_KEY}-*.md
# glob. Reduces drift between dev-story scripts that all need the same
# canonical resolution semantics.
@test "TC-DSF-3: tdd-review-gate.sh sources the shared resolve-story-file.sh helper" {
  # Accept either a direct `source ...resolve-story-file.sh` or an
  # assignment-then-source pattern (the script uses the latter form).
  run grep -E 'resolve-story-file\.sh' "$GATE"
  [ "$status" -eq 0 ]
  run grep -E '^[[:space:]]*(source|\.)[[:space:]]+("?\$RESOLVE_STORY_FILE"?|.*resolve-story-file\.sh)' "$GATE"
  [ "$status" -eq 0 ]
}

# TC-DSF-3b: the legacy private nullglob for story matches MUST be gone.
@test "TC-DSF-3b: tdd-review-gate.sh no longer uses the private STORY_MATCHES nullglob" {
  run grep -E 'STORY_MATCHES=\(.*"\$\{STORY_KEY\}-"' "$GATE"
  [ "$status" -ne 0 ]
}
