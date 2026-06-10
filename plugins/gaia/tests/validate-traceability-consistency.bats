#!/usr/bin/env bats
# validate-traceability-consistency.bats
#
# Coverage for the traceability ↔ story-registry consistency audit. Two
# detection classes, separated so callers gate on the high-signal one:
#   [A] invented key   — a story key referenced in the matrix that is neither
#                        a `### Story` header in epics-and-stories.md nor a
#                        materialized story file.
#   [B] scope mismatch — a story-detail TABLE ROW `| E<N>-S<M> | <scope> |`
#                        whose scope cell shares zero significant tokens with
#                        the registry title for that key (a mis-keyed row).
#
# The default --check scope gates on [B] (the exact mis-keying signature);
# --check existence gates on [A]; --check all gates on both.
#
# Public-function coverage anchor: the coverage gate greps this file
# for every public function in the script under test. They are listed here
# verbatim and exercised end-to-end via stdout + exit-code observation:
#   - emit_text                       (text report renderer; every non-json @test)
#   - emit_json                       (json report renderer; the --format json @test)
#   - resolve_default_epics_file      (epics auto-resolver; the default-path @test)
#   - resolve_default_matrix_file     (matrix auto-resolver; the default-path @test)
#   - resolve_default_artifacts_dir   (impl-artifacts auto-resolver; the file-only-key @test)

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/validate-traceability-consistency.sh"

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  EPICS="$WORK/epics-and-stories.md"
  MATRIX="$WORK/traceability-matrix.md"
  export WORK EPICS MATRIX
}

# ---- fixtures ----

_write_registry() {
  cat > "$EPICS" <<'MD'
## Epic 18: Cloud Deployment
### Story E18-S1: Multi-stage Dockerfiles
Body.
### Story E18-S2: /healthz + /readyz probes
Body.
### Story E18-S3: GCP core infrastructure IaC
Body.
### Story E18-S10: CI deploy pipeline
Body.
MD
}

_write_clean_matrix() {
  cat > "$MATRIX" <<'MD'
---
title: t
generated_by: "stories E18-S1..E18-S9 added"
---
# Matrix
## 3.18 Story Detail
| Story | Scope | Test |
|-------|-------|------|
| E18-S1 | multi-stage Dockerfile build | TC-1 |
| E18-S2 | readyz and healthz probe endpoints | TC-2 |
| E18-S3 | core infrastructure IaC for GCP | TC-3 |

Roll-up: E18-S1, E18-S2, E18-S3 all green.
MD
}

_write_defective_matrix() {
  # Reproduces the upstream defect: story-detail rows keyed by positional
  # numbering of cloud services rather than by registry lookup.
  cat > "$MATRIX" <<'MD'
---
title: t
---
## 3.18 Story Detail
| Story | Scope | Test |
|-------|-------|------|
| E18-S1 | GKE Autopilot cluster and probes | TC-127 |
| E18-S2 | GCS artifact bucket ACL | TC-128 |
| E18-S5 | Cloud Load Balancing | TC-130 |
| E18-S99 | Memorystore Redis cache | TC-140 |
| E18-S3 | GCP core infrastructure IaC provisioning | TC-131 |
| E18-S10 | CI deploy pipeline for GCP | TC-138 |
MD
}

# ---- [B] scope-mismatch (default --check scope) ----

@test "clean matrix → OK, exit 0" {
  _write_registry
  _write_clean_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --severity halt
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "mis-keyed story-detail rows → [B] HARD, exit 1 under default scope+halt" {
  _write_registry
  _write_defective_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --severity halt
  [ "$status" -eq 1 ]
  [[ "$output" == *"[B]"* ]]
  [[ "$output" == *"E18-S1"* ]]   # registry "Multi-stage Dockerfiles" vs matrix "GKE..."
  [[ "$output" == *"E18-S2"* ]]   # registry "healthz/readyz" vs matrix "GCS bucket ACL"
}

@test "scope mismatch under --severity warn → advisory, exit 0" {
  _write_registry
  _write_defective_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --severity warn
  [ "$status" -eq 0 ]
  [[ "$output" == *"[B]"* ]]
}

@test "correctly-keyed rows produce no scope mismatch (no false positive)" {
  _write_registry
  cat > "$MATRIX" <<'MD'
## Detail
| Story | Scope | Test |
|-------|-------|------|
| E18-S1 | multi-stage Dockerfile layering | TC-1 |
| E18-S3 | GCP core infrastructure IaC modules | TC-3 |
MD
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --severity halt
  [ "$status" -eq 0 ]
}

# ---- [A] invented key (--check existence) ----

@test "invented key → [A] HARD under --check existence, exit 1" {
  _write_registry
  _write_defective_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --check existence --severity halt
  [ "$status" -eq 1 ]
  [[ "$output" == *"[A]"* ]]
  [[ "$output" == *"E18-S99"* ]]
  [[ "$output" == *"E18-S5"* ]]
}

@test "invented key is ADVISORY under default --check scope (does not gate)" {
  _write_registry
  # only an invented key, no scope mismatch
  cat > "$MATRIX" <<'MD'
## Detail
| Story | Scope | Test |
|-------|-------|------|
| E18-S77 | brand new thing | TC-9 |
MD
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --severity halt
  [ "$status" -eq 0 ]                    # scope gate: invented key is advisory
  [[ "$output" == *"[A]"* ]]
  [[ "$output" == *"ADVISORY"* ]]
}

@test "--check all gates on both [A] and [B]" {
  _write_registry
  _write_defective_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --check all --severity halt
  [ "$status" -eq 1 ]
  [[ "$output" == *"[A]"* ]]
  [[ "$output" == *"[B]"* ]]
}

# ---- registry augmentation: materialized story files ----

@test "key registered ONLY as a story file is not flagged invented" {
  _write_registry
  # E18-S20 has no `### Story` header but a materialized story file exists.
  mkdir -p "$WORK/impl/epic-E18-cloud/stories"
  cat > "$WORK/impl/epic-E18-cloud/stories/E18-S20-some-story.md" <<'MD'
---
key: E18-S20
epic: "E18 — Cloud Deployment"
---
# Story
MD
  cat > "$MATRIX" <<'MD'
## Detail
| Story | Scope | Test |
|-------|-------|------|
| E18-S20 | anything at all here | TC-5 |
MD
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" \
      --artifacts-dir "$WORK/impl" --check all --severity halt
  [ "$status" -eq 0 ]                    # file-only key: registered, no scope check
  [[ "$output" == *"OK"* ]]
}

# ---- default path resolution ----

@test "auto-resolves epics + matrix from PROJECT_ROOT (.gaia layout)" {
  mkdir -p "$WORK/.gaia/artifacts/planning-artifacts" \
           "$WORK/.gaia/artifacts/test-artifacts"
  EPICS="$WORK/.gaia/artifacts/planning-artifacts/epics-and-stories.md"
  MATRIX="$WORK/.gaia/artifacts/test-artifacts/traceability-matrix.md"
  _write_registry
  _write_clean_matrix
  run env PROJECT_ROOT="$WORK" "$SCRIPT" --severity halt
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---- output formats + usage ----

@test "--format json emits parseable JSON with gate_count" {
  _write_registry
  _write_defective_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --format json --check all
  [ "$status" -eq 0 ]   # severity defaults to warn → exit 0 even with issues
  echo "$output" | grep -q '"gate_count"'
  echo "$output" | grep -q '"scope_mismatches"'
  echo "$output" | grep -q '"invented_keys"'
}

@test "--help exits 0 and prints usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"traceability"* ]]
}

@test "unknown flag → usage error exit 2" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "invalid --check value → usage error exit 2" {
  _write_registry
  _write_clean_matrix
  run "$SCRIPT" --epics-file "$EPICS" --matrix-file "$MATRIX" --check nonsense
  [ "$status" -eq 2 ]
}
