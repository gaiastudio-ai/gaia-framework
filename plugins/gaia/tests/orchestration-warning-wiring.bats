#!/usr/bin/env bats
# orchestration-warning-wiring.bats — E84-S6 / ADR-093 / FR-446.
#
# Coverage:
#   TC-WIRE-1..4  — production-tree assertions: every heavy-procedural and
#                   conversational SKILL.md invokes both helper scripts.
#   TC-WIRE-5..7  — invocation-shape assertions on production tree.
#   TC-WIRE-8..9  — production-tree negative assertions: light-procedural and
#                   reviewer SKILL.md files MUST NOT invoke either script.
#   TC-WIRE-10..13 — synthetic-fixture assertions on check script behavior.

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/check-orchestration-warning-wired.sh"
  FAKE_SKILLS="$TEST_TMP/skills"
  mkdir -p "$FAKE_SKILLS"
  PRODUCTION_SKILLS="$(cd "$BATS_TEST_DIRNAME/../skills" && pwd)"
  export PRODUCTION_SKILLS
}
teardown() { common_teardown; }

# ---- helpers ------------------------------------------------------------

# make_fixture <name> <orchestration_class> <with-invocation?>
# Builds a synthetic SKILL.md under $FAKE_SKILLS. When the third argument is
# "yes", the body contains the canonical invocation pattern.
make_fixture() {
  local name="$1" cls="$2" wired="${3:-no}"
  local dir="$FAKE_SKILLS/$name"
  mkdir -p "$dir"
  if [ "$wired" = "yes" ]; then
    cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: test fixture
orchestration_class: $cls
---

## Orchestration Mode

\`\`\`bash
SESSION_MODE=\$(bash "\${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
bash "\${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class $cls --mode "\$SESSION_MODE"
\`\`\`

## Mission

stub body
EOF
  else
    cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: test fixture
orchestration_class: $cls
---

## Mission

stub body
EOF
  fi
}

# Collect every SKILL.md in the production tree whose orchestration_class
# matches the supplied value. Prints one absolute path per line.
production_skills_for_class() {
  local cls="$1" f
  for f in "$PRODUCTION_SKILLS"/*/SKILL.md; do
    [ -f "$f" ] || continue
    local found
    found="$(awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^orchestration_class:/{sub(/^orchestration_class:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$f")"
    if [ "$found" = "$cls" ]; then
      printf '%s\n' "$f"
    fi
  done
}

# ---- TC-WIRE-1..4: production-tree invocation presence ------------------

@test "every heavy-procedural SKILL.md invokes detect-orchestration-mode.sh" {
  files="$(production_skills_for_class heavy-procedural)"
  [ -n "$files" ]
  missing=""
  while IFS= read -r f; do
    if ! grep -q 'detect-orchestration-mode\.sh' "$f"; then
      missing="${missing}${f}\n"
    fi
  done <<< "$files"
  [ -z "$missing" ] || { printf 'missing detect-orchestration-mode.sh:\n%b' "$missing" >&2; false; }
}

@test "every heavy-procedural SKILL.md invokes orchestration-warning.sh" {
  files="$(production_skills_for_class heavy-procedural)"
  [ -n "$files" ]
  missing=""
  while IFS= read -r f; do
    if ! grep -q 'orchestration-warning\.sh' "$f"; then
      missing="${missing}${f}\n"
    fi
  done <<< "$files"
  [ -z "$missing" ] || { printf 'missing orchestration-warning.sh:\n%b' "$missing" >&2; false; }
}

@test "every conversational SKILL.md invokes detect-orchestration-mode.sh" {
  files="$(production_skills_for_class conversational)"
  [ -n "$files" ]
  missing=""
  while IFS= read -r f; do
    if ! grep -q 'detect-orchestration-mode\.sh' "$f"; then
      missing="${missing}${f}\n"
    fi
  done <<< "$files"
  [ -z "$missing" ] || { printf 'missing detect-orchestration-mode.sh:\n%b' "$missing" >&2; false; }
}

@test "every conversational SKILL.md invokes orchestration-warning.sh" {
  files="$(production_skills_for_class conversational)"
  [ -n "$files" ]
  missing=""
  while IFS= read -r f; do
    if ! grep -q 'orchestration-warning\.sh' "$f"; then
      missing="${missing}${f}\n"
    fi
  done <<< "$files"
  [ -z "$missing" ] || { printf 'missing orchestration-warning.sh:\n%b' "$missing" >&2; false; }
}

# ---- TC-WIRE-5..7: invocation-shape assertions --------------------------

@test "invocation appears in a fenced bash block (no HTML comment, no prose)" {
  files="$(production_skills_for_class heavy-procedural)
$(production_skills_for_class conversational)"
  [ -n "$files" ]
  bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Find line numbers for fence boundaries and the invocation. The
    # invocation line must fall between an opening ```bash fence and its
    # closing ``` fence (or be a !-bang inline directive).
    line=$(grep -nE 'orchestration-warning\.sh' "$f" | head -1 | cut -d: -f1)
    [ -n "$line" ] || { bad="${bad}${f}: no invocation line\n"; continue; }
    # Walk upward to find the nearest fence-or-section boundary.
    above=$(awk -v lineno="$line" 'NR<lineno && /^```/{l=NR; t=$0} END{print l "|" t}' "$f")
    above_line="${above%%|*}"
    above_tag="${above#*|}"
    if [ -z "$above_line" ] || [ "$above_line" = "0" ]; then
      # No fence above; must be a !-bang or unfenced bash line. Accept !-bang.
      if ! grep -qE '^!.*orchestration-warning\.sh' "$f"; then
        bad="${bad}${f}: invocation not inside fenced bash block and not !-bang\n"
      fi
      continue
    fi
    # The nearest opening fence must be a ```bash fence (or ``` followed by
    # bash on the same line is forbidden — only ```bash is accepted).
    case "$above_tag" in
      '```bash') ;;
      *) bad="${bad}${f}: invocation not inside \`\`\`bash fence (saw '$above_tag' at line $above_line)\n" ;;
    esac
  done <<< "$files"
  [ -z "$bad" ] || { printf '%b' "$bad" >&2; false; }
}

@test "skill-class flag value matches orchestration_class frontmatter verbatim" {
  files="$(production_skills_for_class heavy-procedural)
$(production_skills_for_class conversational)"
  [ -n "$files" ]
  bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cls="$(awk '/^---$/{c++; if (c==1) {in_fm=1; next} else if (c==2) {exit}} in_fm && /^orchestration_class:/{sub(/^orchestration_class:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$f")"
    if ! grep -q -- "--skill-class $cls" "$f"; then
      bad="${bad}${f}: missing --skill-class $cls\n"
    fi
  done <<< "$files"
  [ -z "$bad" ] || { printf '%b' "$bad" >&2; false; }
}

@test "mode flag value is captured stdout of detect-orchestration-mode.sh (SESSION_MODE pattern)" {
  files="$(production_skills_for_class heavy-procedural)
$(production_skills_for_class conversational)"
  [ -n "$files" ]
  bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Must contain the SESSION_MODE capture and the --mode "$SESSION_MODE" reference.
    if ! grep -q 'SESSION_MODE=' "$f"; then
      bad="${bad}${f}: missing SESSION_MODE capture\n"
      continue
    fi
    if ! grep -qE -- '--mode[[:space:]]+"\$SESSION_MODE"' "$f"; then
      bad="${bad}${f}: missing --mode \"\$SESSION_MODE\"\n"
    fi
  done <<< "$files"
  [ -z "$bad" ] || { printf '%b' "$bad" >&2; false; }
}

# ---- TC-WIRE-8..9: production-tree out-of-scope class assertions --------

@test "light-procedural SKILL.md files do NOT invoke either helper" {
  files="$(production_skills_for_class light-procedural)"
  [ -n "$files" ]
  bad=""
  while IFS= read -r f; do
    if grep -qE 'orchestration-warning\.sh|detect-orchestration-mode\.sh' "$f"; then
      bad="${bad}${f}: unexpected invocation in light-procedural\n"
    fi
  done <<< "$files"
  [ -z "$bad" ] || { printf '%b' "$bad" >&2; false; }
}

@test "reviewer SKILL.md files do NOT invoke either helper" {
  # AC9 intent: reviewer skills MUST NOT execute the one-shot warning at
  # startup. "Invocation" means the canonical --skill-class call site, not
  # mere prose mention of the script name. gaia-validate-framework is the
  # framework validator and references check-orchestration-warning-wired.sh
  # (which in turn references the helper names) — that is delegation prose,
  # not an invocation.
  files="$(production_skills_for_class reviewer)"
  [ -n "$files" ]
  bad=""
  while IFS= read -r f; do
    if grep -qE -- '--skill-class[[:space:]]+(heavy-procedural|conversational)[[:space:]]+--mode' "$f"; then
      bad="${bad}${f}: unexpected canonical invocation in reviewer\n"
    fi
  done <<< "$files"
  [ -z "$bad" ] || { printf '%b' "$bad" >&2; false; }
}

# ---- TC-WIRE-10: positive check on production tree ----------------------

@test "check-orchestration-warning-wired.sh against production exits 0 with PASS" {
  run "$SCRIPT" --skills-dir "$PRODUCTION_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---- TC-WIRE-11: synthetic heavy-procedural missing invocation -------

@test "heavy-procedural fixture missing invocation -> CRITICAL" {
  make_fixture alpha heavy-procedural no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"alpha"* ]]
}

@test "conversational fixture missing invocation -> CRITICAL" {
  make_fixture beta conversational no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRITICAL"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "heavy-procedural fixture WITH invocation -> PASS" {
  make_fixture gamma heavy-procedural yes
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

# ---- TC-WIRE-12: light-procedural without invocation is silent ---------

@test "light-procedural fixture without invocation exits 0 with no CRITICAL" {
  make_fixture delta light-procedural no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CRITICAL"* ]]
}

# ---- TC-WIRE-13: reviewer without invocation is silent (NFR-060) -------

@test "reviewer fixture without invocation exits 0 with no CRITICAL" {
  make_fixture epsilon reviewer no
  run "$SCRIPT" --skills-dir "$FAKE_SKILLS"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CRITICAL"* ]]
}

# ---- bonus: idempotency invariant from Technical Notes -----------------

@test "INVARIANT: --skills-dir validation rejects missing directory" {
  run "$SCRIPT" --skills-dir "$TEST_TMP/does-not-exist"
  [ "$status" -ne 0 ]
}
