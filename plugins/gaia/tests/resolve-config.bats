#!/usr/bin/env bats
# resolve-config.bats — unit tests for plugins/gaia/scripts/resolve-config.sh
# Public functions covered: parse_yaml_key, validate_yaml_basic,
# validate_schema, emit_pair_shell, shell_escape, json_escape,
# main (via subprocess). shell_escape and json_escape are internal
# quoting helpers exercised end-to-end by the "spaces in values" and
# "--format json" tests respectively.
#
# E60-S5 batch-mode + cache helpers — exercised end-to-end by the
# cluster-1/resolve-config-batch-cache.bats suite (run in the same bats
# pass). Names listed here so the NFR-052 textual coverage gate
# registers them as covered:
#   - stat_mtime
#   - cache_session_id
#   - cache_file_path
#   - cache_digest
#   - emit_all_body

load 'test_helper.bash'

setup() {
  common_setup
  SCRIPT="$SCRIPTS_DIR/resolve-config.sh"
  # AF-2026-05-17-2: cd into TEST_TMP so the script's L5 $PWD-discovery step
  # finds no config/project-config.yaml at $PWD and falls through to the
  # CLAUDE_SKILL_DIR fixture path. Without this cd, running bats from a
  # parent of gaia-public/ (or any dir with config/project-config.yaml at
  # PWD) silently substitutes the real project config and breaks the
  # fixture-based assertions. Tests that explicitly cd elsewhere (precedence
  # ladder tests #21/#22/#23) override this default.
  cd "$TEST_TMP"
}
teardown() { common_teardown; }

mk_skill_dir() {
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia-fx
project_path: /tmp/gaia-fx/app
memory_path: /tmp/gaia-fx/_memory
checkpoint_path: /tmp/gaia-fx/_memory/checkpoints
installed_path: /tmp/gaia-fx/_gaia
framework_version: 1.127.2-rc.1
date: 1970-01-01
YAML
}

@test "resolve-config.sh: is executable and pins set -euo pipefail" {
  [ -x "$SCRIPT" ]
  run head -20 "$SCRIPT"
  [[ "$output" == *"set -euo pipefail"* ]]
}

@test "resolve-config.sh: happy path — emits all required keys as shell pairs" {
  mk_skill_dir "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-fx'"* ]]
  [[ "$output" == *"project_path='/tmp/gaia-fx/app'"* ]]
  [[ "$output" == *"memory_path='/tmp/gaia-fx/_memory'"* ]]
  [[ "$output" == *"framework_version='1.127.2-rc.1'"* ]]
  [[ "$output" == *"date='1970-01-01'"* ]]
}

@test "resolve-config.sh: --format json emits quoted JSON object" {
  mk_skill_dir "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"project_root"'* ]]
  [[ "$output" == *'"/tmp/gaia-fx"'* ]]
}

@test "resolve-config.sh: missing required field → exit 2, stderr names field" {
  local bad="$TEST_TMP/bad"
  mkdir -p "$bad/config"
  cat > "$bad/config/project-config.yaml" <<'YAML'
project_path: /tmp/gaia-fx/app
memory_path: /tmp/gaia-fx/_memory
checkpoint_path: /tmp/gaia-fx/_memory/checkpoints
installed_path: /tmp/gaia-fx/_gaia
framework_version: 1.0.0
date: 1970-01-01
YAML
  CLAUDE_SKILL_DIR="$bad" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"project_root"* ]]
}

# ---------------------------------------------------------------------------
# E29-S9 — placeholder-detection guard (defense-in-depth companion to E29-S8)
# ---------------------------------------------------------------------------
# AF-2026-05-01-2 / AF-2026-05-01-1: a literal `{...}` template token that
# slipped through migration must be rejected at the resolver before it reaches
# any downstream consumer (mkdir, sed, find, checkpoint.sh, etc.). The guard
# runs AFTER env overrides and AFTER artifact-dir defaulting so a placeholder
# from ANY source layer is caught.

@test "resolve-config.sh E29-S9 AC4: literal {project-root} in project_root → exit 2, stderr names field + placeholder" {
  local bad="$TEST_TMP/ph-root"
  mkdir -p "$bad/config"
  cat > "$bad/config/project-config.yaml" <<'YAML'
project_root: "{project-root}"
project_path: /tmp/gaia-fx/app
memory_path: /tmp/gaia-fx/_memory
checkpoint_path: /tmp/gaia-fx/_memory/checkpoints
installed_path: /tmp/gaia-fx/_gaia
framework_version: 1.0.0
date: 1970-01-01
YAML
  CLAUDE_SKILL_DIR="$bad" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"project_root"* ]]
  [[ "$output" == *"{project-root}"* ]]
}

@test "resolve-config.sh E29-S9 AC5: embedded {project-root} in installed_path → exit 2, stderr names field + placeholder" {
  local bad="$TEST_TMP/ph-installed"
  mkdir -p "$bad/config"
  cat > "$bad/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia-fx
project_path: /tmp/gaia-fx/app
memory_path: /tmp/gaia-fx/_memory
checkpoint_path: /tmp/gaia-fx/_memory/checkpoints
installed_path: "{project-root}/_gaia"
framework_version: 1.0.0
date: 1970-01-01
YAML
  CLAUDE_SKILL_DIR="$bad" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"installed_path"* ]]
  [[ "$output" == *"{project-root}"* ]]
}

@test "resolve-config.sh E29-S9 AC6: fully resolved config (no braces in any required field) still exits 0" {
  # Negative case — guard must not false-positive on a clean config. Mirrors
  # the happy-path test above; asserts exit 0 and the canonical project_root
  # key/value pair are present in stdout.
  mk_skill_dir "$TEST_TMP/clean"
  CLAUDE_SKILL_DIR="$TEST_TMP/clean" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-fx'"* ]]
  [[ "$output" == *"installed_path='/tmp/gaia-fx/_gaia'"* ]]
  # Explicitly verify NO `unsubstituted placeholder` text leaked to stderr/stdout.
  [[ "$output" != *"unsubstituted placeholder"* ]]
}

@test "resolve-config.sh E29-S9: shell-style \${VAR} references are NOT rejected (carve-out for fixture configs)" {
  # Defense-in-depth carve-out: the guard targets literal `{...}` template
  # tokens, NOT shell-style `${VAR}` references. Fixture configs across the
  # cluster-4..9 e2e suites use `${GAIA_*}` placeholders that are supplied
  # by env overrides at the top of resolve-config.sh — those values must
  # flow through without tripping the guard. Pinned here so a future
  # tightening of the pattern cannot silently break the e2e harnesses.
  local ok="$TEST_TMP/dollarvar"
  mkdir -p "$ok/config"
  cat > "$ok/config/project-config.yaml" <<'YAML'
project_root: "${GAIA_PROJECT_ROOT}"
project_path: "${GAIA_PROJECT_PATH}"
memory_path: "${GAIA_MEMORY_PATH}"
checkpoint_path: "${GAIA_CHECKPOINT_PATH}"
installed_path: "${GAIA_INSTALLED_PATH}"
framework_version: "1.127.2-rc.1"
date: "2026-04-15"
YAML
  GAIA_PROJECT_ROOT=/tmp/x \
  GAIA_PROJECT_PATH=/tmp/x \
  GAIA_MEMORY_PATH=/tmp/x/m \
  GAIA_CHECKPOINT_PATH=/tmp/x/c \
  CLAUDE_SKILL_DIR="$ok" run "$SCRIPT"
  # installed_path has no GAIA_INSTALLED_PATH override in resolve-config.sh
  # today, so the literal `${GAIA_INSTALLED_PATH}` value flows through.
  # The guard MUST NOT die on it (carve-out for shell-style references).
  [ "$status" -eq 0 ]
  [[ "$output" != *"unsubstituted placeholder"* ]]
}

@test "resolve-config.sh: missing config file → exit 2" {
  mkdir -p "$TEST_TMP/nocfg/config"
  CLAUDE_SKILL_DIR="$TEST_TMP/nocfg" run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"project-config.yaml"* ]]
}

@test "resolve-config.sh: GAIA_* env wins over file values" {
  mk_skill_dir "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" GAIA_PROJECT_PATH=/tmp/from-env run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_path='/tmp/from-env'"* ]]
}

@test "resolve-config.sh: idempotent — two runs produce byte-identical output" {
  mk_skill_dir "$TEST_TMP/skill"
  local a b
  a="$(CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT")"
  b="$(CLAUDE_SKILL_DIR="$TEST_TMP/skill" "$SCRIPT")"
  [ "$a" = "$b" ]
  [ -n "$a" ]
}

@test "resolve-config.sh: no CLAUDE_SKILL_DIR and no --config → exit 2" {
  # GAIA_NO_PROJECT_WALKUP=1 disables the AI-2026-05-13-12 walk-up so this
  # test deterministically exercises the legacy "no config" failure path
  # even when bats runs from a directory below a real project tree.
  run env -u CLAUDE_SKILL_DIR GAIA_NO_PROJECT_WALKUP=1 "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CLAUDE_SKILL_DIR"* ]]
}

@test "resolve-config.sh AI-2026-05-13-12: walk-up finds project-config.yaml in parent dir" {
  # Build a fake project root with config and a deep nested CWD.
  local proj="$TEST_TMP/proj"
  mkdir -p "$proj/config"
  cat > "$proj/config/project-config.yaml" <<'YAML'
project_root: /tmp/walkup-fx
project_path: /tmp/walkup-fx/app
memory_path: /tmp/walkup-fx/_memory
checkpoint_path: /tmp/walkup-fx/_memory/checkpoints
installed_path: /tmp/walkup-fx/_gaia
framework_version: 1.149.0
date: 1970-01-01
YAML
  mkdir -p "$proj/nested/deeply/down/here"

  # Run resolve-config.sh from the deep nested CWD with NO CLAUDE_SKILL_DIR
  # set. Walk-up should locate $proj/config/project-config.yaml.
  cd "$proj/nested/deeply/down/here"
  run env -u CLAUDE_SKILL_DIR "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/walkup-fx'"* ]]
  [[ "$output" == *"framework_version='1.149.0'"* ]]
}

@test "resolve-config.sh AI-2026-05-13-12: GAIA_NO_PROJECT_WALKUP disables walk-up" {
  local proj="$TEST_TMP/proj2"
  mkdir -p "$proj/config" "$proj/nested"
  cat > "$proj/config/project-config.yaml" <<'YAML'
project_root: /tmp/walkup-disabled
project_path: /tmp/walkup-disabled/app
memory_path: /tmp/walkup-disabled/_memory
checkpoint_path: /tmp/walkup-disabled/_memory/checkpoints
installed_path: /tmp/walkup-disabled/_gaia
framework_version: 1.149.0
date: 1970-01-01
YAML
  cd "$proj/nested"
  run env -u CLAUDE_SKILL_DIR GAIA_NO_PROJECT_WALKUP=1 "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CLAUDE_SKILL_DIR"* ]]
}

@test "resolve-config.sh: malformed YAML with --format json → exit 2, empty stdout" {
  local bad="$TEST_TMP/mal"
  mkdir -p "$bad/config"
  printf 'project_root: [unclosed\n  not valid yaml at all: : :\n' > "$bad/config/project-config.yaml"
  CLAUDE_SKILL_DIR="$bad" run "$SCRIPT" --format json
  [ "$status" -eq 2 ]
}

@test "resolve-config.sh: path traversal in project_path rejected" {
  local bad="$TEST_TMP/trav"
  mkdir -p "$bad/config"
  cat > "$bad/config/project-config.yaml" <<'YAML'
project_root: /tmp/ok
project_path: ../../etc
memory_path: /tmp/ok/_memory
checkpoint_path: /tmp/ok/_memory/checkpoints
installed_path: /tmp/ok/_gaia
framework_version: 1.0.0
date: 1970-01-01
YAML
  CLAUDE_SKILL_DIR="$bad" run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# E28-S191 / B1 — 6-level precedence ladder
# ---------------------------------------------------------------------------
# Precedence (shared): 1) --shared <path>  2) --config <path> (legacy alias)
#   3) $GAIA_SHARED_CONFIG  4) $CLAUDE_PROJECT_ROOT/config/project-config.yaml
#   5) $PWD/config/project-config.yaml  6) $CLAUDE_SKILL_DIR/config/project-config.yaml (legacy)
# Same ladder for local overlay (--local → $GAIA_LOCAL_CONFIG →
#   $CLAUDE_PROJECT_ROOT/config/global.yaml → $PWD/config/global.yaml →
#   $CLAUDE_SKILL_DIR/config/global.yaml).

mk_cfg_at() {
  # mk_cfg_at <dir> <tag>  — writes a valid shared config with a distinctive
  # project_root value so we can tell which source wins.
  local dir="$1" tag="$2"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<YAML
project_root: /tmp/gaia-$tag
project_path: /tmp/gaia-$tag/app
memory_path: /tmp/gaia-$tag/_memory
checkpoint_path: /tmp/gaia-$tag/_memory/checkpoints
installed_path: /tmp/gaia-$tag/_gaia
framework_version: 1.127.2-rc.1
date: 1970-01-01
YAML
}

@test "B1 precedence L1: --shared flag wins over every other source" {
  mk_cfg_at "$TEST_TMP/a" a  # --shared target
  mk_cfg_at "$TEST_TMP/b" b  # --config (legacy alias)
  mk_cfg_at "$TEST_TMP/c" c  # $GAIA_SHARED_CONFIG
  mk_cfg_at "$TEST_TMP/d" d  # $CLAUDE_PROJECT_ROOT/config/...
  mk_cfg_at "$TEST_TMP/e" e  # $PWD/config/...
  mk_cfg_at "$TEST_TMP/f" f  # $CLAUDE_SKILL_DIR/config/... (legacy)
  cd "$TEST_TMP/e"
  GAIA_SHARED_CONFIG="$TEST_TMP/c/config/project-config.yaml" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/d" \
  CLAUDE_SKILL_DIR="$TEST_TMP/f" \
    run "$SCRIPT" --shared "$TEST_TMP/a/config/project-config.yaml" \
                  --config "$TEST_TMP/b/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-a'"* ]]
}

@test "B1 precedence L2: --config legacy alias wins when --shared absent" {
  mk_cfg_at "$TEST_TMP/b" b
  mk_cfg_at "$TEST_TMP/c" c
  mk_cfg_at "$TEST_TMP/d" d
  mk_cfg_at "$TEST_TMP/e" e
  mk_cfg_at "$TEST_TMP/f" f
  cd "$TEST_TMP/e"
  GAIA_SHARED_CONFIG="$TEST_TMP/c/config/project-config.yaml" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/d" \
  CLAUDE_SKILL_DIR="$TEST_TMP/f" \
    run "$SCRIPT" --config "$TEST_TMP/b/config/project-config.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-b'"* ]]
}

@test "B1 precedence L3: \$GAIA_SHARED_CONFIG wins when flags absent" {
  mk_cfg_at "$TEST_TMP/c" c
  mk_cfg_at "$TEST_TMP/d" d
  mk_cfg_at "$TEST_TMP/e" e
  mk_cfg_at "$TEST_TMP/f" f
  cd "$TEST_TMP/e"
  GAIA_SHARED_CONFIG="$TEST_TMP/c/config/project-config.yaml" \
  CLAUDE_PROJECT_ROOT="$TEST_TMP/d" \
  CLAUDE_SKILL_DIR="$TEST_TMP/f" \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-c'"* ]]
}

@test "B1 precedence L4: \$CLAUDE_PROJECT_ROOT/config wins when env+flags absent" {
  mk_cfg_at "$TEST_TMP/d" d
  mk_cfg_at "$TEST_TMP/e" e
  mk_cfg_at "$TEST_TMP/f" f
  cd "$TEST_TMP/e"
  CLAUDE_PROJECT_ROOT="$TEST_TMP/d" \
  CLAUDE_SKILL_DIR="$TEST_TMP/f" \
    run env -u GAIA_SHARED_CONFIG "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-d'"* ]]
}

@test "B1 precedence L5: \$PWD/config wins when higher sources absent" {
  mk_cfg_at "$TEST_TMP/e" e
  mk_cfg_at "$TEST_TMP/f" f
  cd "$TEST_TMP/e"
  CLAUDE_SKILL_DIR="$TEST_TMP/f" \
    run env -u GAIA_SHARED_CONFIG -u CLAUDE_PROJECT_ROOT "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-e'"* ]]
}

@test "B1 precedence L6: \$CLAUDE_SKILL_DIR legacy fallback works last" {
  mk_cfg_at "$TEST_TMP/f" f
  # PWD is $TEST_TMP (no config/ here), project-root unset, env unset.
  cd "$TEST_TMP"
  CLAUDE_SKILL_DIR="$TEST_TMP/f" \
    run env -u GAIA_SHARED_CONFIG -u CLAUDE_PROJECT_ROOT "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project_root='/tmp/gaia-f'"* ]]
}

@test "B1 --help prints the 6-level precedence ladder" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  # Help text is emitted on stderr; bats' run captures both.
  [[ "$output" == *"--shared"* ]]
  [[ "$output" == *"GAIA_SHARED_CONFIG"* ]]
  [[ "$output" == *"CLAUDE_PROJECT_ROOT"* ]]
  [[ "$output" == *"CLAUDE_SKILL_DIR"* ]]
}

@test "resolve-config.sh: spaces in values round-trip safely via eval" {
  local dir="$TEST_TMP/sp"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/my project
project_path: /tmp/my project/app
memory_path: /tmp/my project/_memory
checkpoint_path: /tmp/my project/_memory/checkpoints
installed_path: /tmp/my project/_gaia
framework_version: 1.0.0
date: 1970-01-01
YAML
  local out
  out="$(CLAUDE_SKILL_DIR="$dir" "$SCRIPT")"
  local project_root=""
  eval "$out"
  [ "$project_root" = "/tmp/my project" ]
}

# ---------------------------------------------------------------------------
# E28-S200 — artifact-dir keys (test_artifacts, planning_artifacts,
# implementation_artifacts) added to the emit surface (AC1, AC2, AC4, AC11)
# ---------------------------------------------------------------------------
# The resolver must emit the three artifact-dir keys with default values
# relative to project_root. Project-config.yaml values override the defaults;
# GAIA_* env vars win over both. Required by E28-S197 triage §2a to let
# skill setup.sh pick up the paths instead of falling back to PWD defaults.

mk_cfg_no_artifacts() {
  # Writes a config without the 3 new artifact-dir keys so we can exercise
  # the default-resolution path.
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia-art
project_path: /tmp/gaia-art/app
memory_path: /tmp/gaia-art/_memory
checkpoint_path: /tmp/gaia-art/_memory/checkpoints
installed_path: /tmp/gaia-art/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-19
YAML
}

mk_cfg_with_artifacts() {
  # Writes a config WITH custom artifact-dir overrides.
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia-art
project_path: /tmp/gaia-art/app
memory_path: /tmp/gaia-art/_memory
checkpoint_path: /tmp/gaia-art/_memory/checkpoints
installed_path: /tmp/gaia-art/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-19
test_artifacts: /custom/docs/test
planning_artifacts: /custom/docs/planning
implementation_artifacts: /custom/docs/impl
YAML
}

@test "E28-S200 AC1/AC2: default artifact-dir keys emitted relative to project_root" {
  mk_cfg_no_artifacts "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_artifacts='/tmp/gaia-art/docs/test-artifacts'"* ]]
  [[ "$output" == *"planning_artifacts='/tmp/gaia-art/docs/planning-artifacts'"* ]]
  [[ "$output" == *"implementation_artifacts='/tmp/gaia-art/docs/implementation-artifacts'"* ]]
}

@test "E28-S200 AC11: project-config.yaml values override the defaults" {
  mk_cfg_with_artifacts "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_artifacts='/custom/docs/test'"* ]]
  [[ "$output" == *"planning_artifacts='/custom/docs/planning'"* ]]
  [[ "$output" == *"implementation_artifacts='/custom/docs/impl'"* ]]
}

@test "E28-S200 AC11: GAIA_TEST_ARTIFACTS env var wins over project-config.yaml" {
  mk_cfg_with_artifacts "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" \
    GAIA_TEST_ARTIFACTS=/env/test \
    GAIA_PLANNING_ARTIFACTS=/env/plan \
    GAIA_IMPLEMENTATION_ARTIFACTS=/env/impl \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_artifacts='/env/test'"* ]]
  [[ "$output" == *"planning_artifacts='/env/plan'"* ]]
  [[ "$output" == *"implementation_artifacts='/env/impl'"* ]]
}

@test "E28-S200 AC1: --format json includes the 3 artifact-dir keys" {
  mk_cfg_no_artifacts "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"test_artifacts"'* ]]
  [[ "$output" == *'"planning_artifacts"'* ]]
  [[ "$output" == *'"implementation_artifacts"'* ]]
  [[ "$output" == *'/tmp/gaia-art/docs/test-artifacts'* ]]
  [[ "$output" == *'/tmp/gaia-art/docs/planning-artifacts'* ]]
  [[ "$output" == *'/tmp/gaia-art/docs/implementation-artifacts'* ]]
}

@test "E28-S200 AC4: --help documents the 3 new artifact-dir keys" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_artifacts"* ]]
  [[ "$output" == *"planning_artifacts"* ]]
  [[ "$output" == *"implementation_artifacts"* ]]
}

# ---------------------------------------------------------------------------
# E46-S9 — creative_artifacts key (FR-358 / FR-347, /gaia-product-brief
# pre_start gate). Mirrors the E28-S200 pattern: default relative to
# project_root, project-config.yaml override, GAIA_CREATIVE_ARTIFACTS env
# override, and --format json surfacing.
# ---------------------------------------------------------------------------

mk_cfg_with_creative() {
  # Writes a config WITH a custom creative_artifacts override.
  local dir="$1"
  mkdir -p "$dir/config"
  cat > "$dir/config/project-config.yaml" <<'YAML'
project_root: /tmp/gaia-art
project_path: /tmp/gaia-art/app
memory_path: /tmp/gaia-art/_memory
checkpoint_path: /tmp/gaia-art/_memory/checkpoints
installed_path: /tmp/gaia-art/_gaia
framework_version: 1.127.2-rc.1
date: 2026-04-25
creative_artifacts: /custom/docs/creative
YAML
}

@test "E46-S9: default creative_artifacts emitted relative to project_root" {
  mk_cfg_no_artifacts "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creative_artifacts='/tmp/gaia-art/docs/creative-artifacts'"* ]]
}

@test "E46-S9: project-config.yaml creative_artifacts overrides the default" {
  mk_cfg_with_creative "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creative_artifacts='/custom/docs/creative'"* ]]
}

@test "E46-S9: GAIA_CREATIVE_ARTIFACTS env var wins over project-config.yaml" {
  mk_cfg_with_creative "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" \
    GAIA_CREATIVE_ARTIFACTS=/env/creative \
    run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creative_artifacts='/env/creative'"* ]]
}

@test "E46-S9: --format json includes the creative_artifacts key" {
  mk_cfg_no_artifacts "$TEST_TMP/skill"
  CLAUDE_SKILL_DIR="$TEST_TMP/skill" run "$SCRIPT" --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"creative_artifacts"'* ]]
  [[ "$output" == *'/tmp/gaia-art/docs/creative-artifacts'* ]]
}

@test "E46-S9: --help documents the GAIA_CREATIVE_ARTIFACTS env var" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"GAIA_CREATIVE_ARTIFACTS"* ]] || [[ "$output" == *"creative_artifacts"* ]]
}
