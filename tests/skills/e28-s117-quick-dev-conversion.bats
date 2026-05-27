#!/usr/bin/env bats
# e28-s117-quick-dev-conversion.bats — E28-S117 acceptance tests
#
# Validates the conversion of the legacy quick-dev workflow
# (_gaia/lifecycle/workflows/quick-flow/quick-dev/) to a native Claude Code
# SKILL.md under plugins/gaia/skills/gaia-quick-dev/ with dev agent
# subagent delegation preserved.
#
# Cluster 16 — Quick Flow (second delivery). Pairs with E28-S116 (quick-spec).
# Unblocks E28-S118 (end-to-end Quick Flow test gate).
#
# Traces to FR-323, FR-324, NFR-048, NFR-053, ADR-041, ADR-042, ADR-045,
# ADR-046, ADR-048.
#
# Dependencies: bats-core 1.10+

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/plugins/gaia/skills"
  AGENTS_DIR="$REPO_ROOT/plugins/gaia/agents"
  LINTER="$REPO_ROOT/.github/scripts/lint-skill-frontmatter.sh"
  QD_DIR="$SKILL_DIR/gaia-quick-dev"
  QD_SKILL="$QD_DIR/SKILL.md"
  QD_SCRIPTS="$QD_DIR/scripts"
}

# ---------- AC1: File exists with required frontmatter ----------

@test "AC1: gaia-quick-dev/SKILL.md exists" {
  [ -f "$QD_SKILL" ]
}

@test "AC1: frontmatter name == gaia-quick-dev" {
  grep -qE '^name:[[:space:]]*gaia-quick-dev[[:space:]]*$' "$QD_SKILL"
}

@test "AC1: frontmatter description is present and non-empty" {
  grep -qE '^description:[[:space:]]*[^[:space:]]+' "$QD_SKILL"
}

@test "AC1: frontmatter argument-hint is present" {
  grep -qE '^argument-hint:' "$QD_SKILL"
}

@test "AC1: frontmatter allowed-tools contains Read Write Edit Bash Grep Glob" {
  grep -qE '^allowed-tools:' "$QD_SKILL"
  local line
  line=$(grep -E '^allowed-tools:' "$QD_SKILL")
  [[ "$line" == *"Read"* ]]
  [[ "$line" == *"Write"* ]]
  [[ "$line" == *"Edit"* ]]
  [[ "$line" == *"Bash"* ]]
  [[ "$line" == *"Grep"* ]]
  [[ "$line" == *"Glob"* ]]
}

# ---------- AC2: Dev agent subagent delegation preserved ----------

@test "AC2: SKILL.md references context: fork for subagent delegation" {
  grep -qE 'context:[[:space:]]*fork' "$QD_SKILL"
}

@test "AC2: SKILL.md references auto-detect stack logic" {
  grep -qiE 'auto-detect.*stack|auto-detected developer' "$QD_SKILL"
}

@test "AC2: SKILL.md lists seven native stack agents for delegation" {
  grep -qE 'typescript-dev' "$QD_SKILL"
  grep -qE 'angular-dev' "$QD_SKILL"
  grep -qE 'flutter-dev' "$QD_SKILL"
  grep -qE 'java-dev' "$QD_SKILL"
  grep -qE 'python-dev' "$QD_SKILL"
  grep -qE 'mobile-dev' "$QD_SKILL"
  grep -qE 'go-dev' "$QD_SKILL"
}

@test "AC2: SKILL.md documents user-select fallback when auto-detect fails" {
  grep -qiE 'fall.?back|ambiguous|ask.*user.*stack' "$QD_SKILL"
}

# ---------- AC3: JIT shared-skill loading ----------

@test "AC3: SKILL.md references JIT-loading of shared skills" {
  grep -qiE 'JIT|just.in.time|load.*at runtime|sectioned.?load' "$QD_SKILL"
}

@test "AC3: SKILL.md references gaia-testing-patterns skill" {
  grep -qE 'gaia-testing-patterns' "$QD_SKILL"
}

@test "AC3: SKILL.md references gaia-git-workflow skill" {
  grep -qE 'gaia-git-workflow' "$QD_SKILL"
}

# ---------- AC4: Frontmatter linter passes ----------

@test "AC4: linter passes on gaia-quick-dev/SKILL.md" {
  [ -x "$LINTER" ]
  cd "$REPO_ROOT"
  run bash "$LINTER"
  [ "$status" -eq 0 ]
}

# ---------- AC5: Functional parity — five-step flow preserved ----------

@test "AC5: SKILL.md contains Load Spec step" {
  grep -qiE '^#+.*Load.*Spec' "$QD_SKILL"
}

@test "AC5: SKILL.md contains WIP Checkpoint resolve step" {
  grep -qiE '^#+.*(WIP|Check.*WIP|Checkpoint)' "$QD_SKILL"
}

@test "AC5: SKILL.md contains Implement step" {
  grep -qiE '^#+.*Implement' "$QD_SKILL"
}

@test "AC5: SKILL.md contains Verify step" {
  grep -qiE '^#+.*Verify' "$QD_SKILL"
}

@test "AC5: SKILL.md contains Complete step" {
  grep -qiE '^#+.*Complete' "$QD_SKILL"
}

@test "AC5: SKILL.md mentions files_touched checkpoint shape" {
  grep -qE 'files_touched' "$QD_SKILL"
}

@test "AC5: SKILL.md mentions sha256 checksum discipline" {
  grep -qiE 'sha256|shasum' "$QD_SKILL"
}

@test "AC5: SKILL.md mentions completed checkpoint archival" {
  grep -qiE 'archiv(e|al).*checkpoint|checkpoint.*completed/' "$QD_SKILL"
}

# ---------- Task 5: Foundation scripts (ADR-042) ----------

@test "Scripts: load-spec.sh exists and is executable" {
  [ -x "$QD_SCRIPTS/load-spec.sh" ]
}

@test "Scripts: wip-checkpoint-resolve.sh exists and is executable" {
  [ -x "$QD_SCRIPTS/wip-checkpoint-resolve.sh" ]
}

@test "Scripts: auto-detect-stack.sh exists and is executable" {
  [ -x "$QD_SCRIPTS/auto-detect-stack.sh" ]
}

@test "Scripts: checkpoint-archive.sh exists and is executable" {
  [ -x "$QD_SCRIPTS/checkpoint-archive.sh" ]
}

# ---------- Script behaviour: load-spec.sh (EC-4) ----------

@test "load-spec.sh: missing spec file exits with code 2 (EC-4)" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  run "$QD_SCRIPTS/load-spec.sh" nonexistent-spec
  [ "$status" -eq 2 ]
  rm -rf "$tmpdir"
}

@test "load-spec.sh: emits spec body on stdout when file exists" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  cat > "$tmpdir/docs/implementation-artifacts/quick-spec-foo.md" <<EOF
# Quick Spec: foo
Body content for foo spec.
EOF
  cd "$tmpdir"
  run "$QD_SCRIPTS/load-spec.sh" foo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Body content for foo spec."* ]]
  rm -rf "$tmpdir"
}

# ---------- Script behaviour: wip-checkpoint-resolve.sh (EC-5) ----------

@test "wip-checkpoint-resolve.sh: no checkpoint exits 0 with NONE status" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  run "$QD_SCRIPTS/wip-checkpoint-resolve.sh" nonexistent
  [ "$status" -eq 0 ]
  [[ "$output" == *"NONE"* ]] || [[ "$output" == *"no checkpoint"* ]]
  rm -rf "$tmpdir"
}

@test "wip-checkpoint-resolve.sh: matching checksums return exit 0 MATCH" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.gaia/memory/checkpoints"
  mkdir -p "$tmpdir/src"
  echo "hello" > "$tmpdir/src/a.txt"
  local sum
  sum=$(shasum -a 256 "$tmpdir/src/a.txt" | awk '{print $1}')
  cat > "$tmpdir/.gaia/memory/checkpoints/quick-dev-bar.yaml" <<EOF
workflow: quick-dev
files_touched:
  - path: src/a.txt
    checksum: "sha256:$sum"
    last_modified: "2026-04-16T00:00:00Z"
EOF
  cd "$tmpdir"
  run "$QD_SCRIPTS/wip-checkpoint-resolve.sh" bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"MATCH"* ]]
  rm -rf "$tmpdir"
}

@test "wip-checkpoint-resolve.sh: mismatched checksum returns exit 1 MODIFIED (EC-5)" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.gaia/memory/checkpoints"
  mkdir -p "$tmpdir/src"
  echo "hello" > "$tmpdir/src/a.txt"
  cat > "$tmpdir/.gaia/memory/checkpoints/quick-dev-baz.yaml" <<EOF
workflow: quick-dev
files_touched:
  - path: src/a.txt
    checksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    last_modified: "2026-04-16T00:00:00Z"
EOF
  cd "$tmpdir"
  run "$QD_SCRIPTS/wip-checkpoint-resolve.sh" baz
  [ "$status" -eq 1 ]
  [[ "$output" == *"MODIFIED"* ]]
  rm -rf "$tmpdir"
}

@test "wip-checkpoint-resolve.sh: deleted file returns exit 1 DELETED (EC-5)" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.gaia/memory/checkpoints"
  cat > "$tmpdir/.gaia/memory/checkpoints/quick-dev-qux.yaml" <<EOF
workflow: quick-dev
files_touched:
  - path: src/gone.txt
    checksum: "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    last_modified: "2026-04-16T00:00:00Z"
EOF
  cd "$tmpdir"
  run "$QD_SCRIPTS/wip-checkpoint-resolve.sh" qux
  [ "$status" -eq 1 ]
  [[ "$output" == *"DELETED"* ]]
  rm -rf "$tmpdir"
}

# ---------- Script behaviour: auto-detect-stack.sh (EC-2) ----------

@test "auto-detect-stack.sh: package.json detects typescript" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  echo "# spec" > "$tmpdir/docs/implementation-artifacts/quick-spec-ts.md"
  echo '{"name":"x"}' > "$tmpdir/package.json"
  cd "$tmpdir"
  run "$QD_SCRIPTS/auto-detect-stack.sh" ts
  [ "$status" -eq 0 ]
  [[ "$output" == *"typescript"* ]]
  rm -rf "$tmpdir"
}

@test "auto-detect-stack.sh: pubspec.yaml detects flutter" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  echo "# spec" > "$tmpdir/docs/implementation-artifacts/quick-spec-fl.md"
  echo 'name: x' > "$tmpdir/pubspec.yaml"
  cd "$tmpdir"
  run "$QD_SCRIPTS/auto-detect-stack.sh" fl
  [ "$status" -eq 0 ]
  [[ "$output" == *"flutter"* ]]
  rm -rf "$tmpdir"
}

@test "auto-detect-stack.sh: go.mod detects go" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  echo "# spec" > "$tmpdir/docs/implementation-artifacts/quick-spec-gg.md"
  echo 'module x' > "$tmpdir/go.mod"
  cd "$tmpdir"
  run "$QD_SCRIPTS/auto-detect-stack.sh" gg
  [ "$status" -eq 0 ]
  [[ "$output" == *"go"* ]]
  rm -rf "$tmpdir"
}

@test "auto-detect-stack.sh: pom.xml detects java" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  echo "# spec" > "$tmpdir/docs/implementation-artifacts/quick-spec-jv.md"
  echo '<project/>' > "$tmpdir/pom.xml"
  cd "$tmpdir"
  run "$QD_SCRIPTS/auto-detect-stack.sh" jv
  [ "$status" -eq 0 ]
  [[ "$output" == *"java"* ]]
  rm -rf "$tmpdir"
}

@test "auto-detect-stack.sh: requirements.txt detects python" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  echo "# spec" > "$tmpdir/docs/implementation-artifacts/quick-spec-py.md"
  echo 'requests' > "$tmpdir/requirements.txt"
  cd "$tmpdir"
  run "$QD_SCRIPTS/auto-detect-stack.sh" py
  [ "$status" -eq 0 ]
  [[ "$output" == *"python"* ]]
  rm -rf "$tmpdir"
}

@test "auto-detect-stack.sh: ambiguous (no signals) exits 1 (EC-2)" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/docs/implementation-artifacts"
  echo "# spec" > "$tmpdir/docs/implementation-artifacts/quick-spec-amb.md"
  cd "$tmpdir"
  run "$QD_SCRIPTS/auto-detect-stack.sh" amb
  [ "$status" -eq 1 ]
  rm -rf "$tmpdir"
}

# ---------- Script behaviour: checkpoint-archive.sh ----------

@test "checkpoint-archive.sh: missing checkpoint exits non-zero" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  run "$QD_SCRIPTS/checkpoint-archive.sh" nonexistent
  [ "$status" -ne 0 ]
  rm -rf "$tmpdir"
}

@test "checkpoint-archive.sh: archives active checkpoint to completed/" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/.gaia/memory/checkpoints"
  echo 'phase: complete' > "$tmpdir/.gaia/memory/checkpoints/quick-dev-arc.yaml"
  cd "$tmpdir"
  run "$QD_SCRIPTS/checkpoint-archive.sh" arc
  [ "$status" -eq 0 ]
  [ -f "$tmpdir/.gaia/memory/checkpoints/completed/quick-dev-arc.yaml" ]
  [ ! -f "$tmpdir/.gaia/memory/checkpoints/quick-dev-arc.yaml" ]
  rm -rf "$tmpdir"
}

# ---------- AC-EC3: Non-existent stack agent HALTs ----------

@test "EC3: all listed native stack agents exist in plugin tree" {
  [ -f "$AGENTS_DIR/typescript-dev.md" ]
  [ -f "$AGENTS_DIR/angular-dev.md" ]
  [ -f "$AGENTS_DIR/flutter-dev.md" ]
  [ -f "$AGENTS_DIR/java-dev.md" ]
  [ -f "$AGENTS_DIR/python-dev.md" ]
  [ -f "$AGENTS_DIR/mobile-dev.md" ]
  [ -f "$AGENTS_DIR/go-dev.md" ]
}

# ---------- AC-EC6: 1-level delegation nesting discipline ----------

@test "EC6: SKILL.md documents 1-level delegation (no nested subagents)" {
  grep -qiE '1.level|one.level|single.level|ADR-023' "$QD_SKILL"
}

# ---------- AC-EC8: project_path discipline ----------

@test "EC8: SKILL.md documents project-path vs project-root discipline" {
  grep -qE 'project.path|project_path' "$QD_SKILL"
}

# ---------- Task 8: Namespace collision ----------

@test "Namespace: gaia-quick-dev is distinct from gaia-quick-spec" {
  [ -f "$SKILL_DIR/gaia-quick-dev/SKILL.md" ]
  [ -f "$SKILL_DIR/gaia-quick-spec/SKILL.md" ]
  local qd_name qs_name
  qd_name=$(grep -E '^name:' "$SKILL_DIR/gaia-quick-dev/SKILL.md" | head -1 | awk '{print $2}')
  qs_name=$(grep -E '^name:' "$SKILL_DIR/gaia-quick-spec/SKILL.md" | head -1 | awk '{print $2}')
  [ "$qd_name" = "gaia-quick-dev" ]
  [ "$qs_name" = "gaia-quick-spec" ]
  [ "$qd_name" != "$qs_name" ]
}
