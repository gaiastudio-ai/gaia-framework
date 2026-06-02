#!/usr/bin/env bats
# e60-s1-flat-artifact-path-keys.bats — regression guard for E60-S1
#
# Story: E60-S1 (Add four flat artifact-path keys to project-config.yaml)
# Epic:  E60 (Artifact Paths in project-config.yaml)
# ADR:   ADR-074 contract C1 (project-config.yaml schema additions)
# Trace: AF-2026-04-28-7, ADR-074-C1, Work-Item-2
#
# Validates:
#   AC1 — Active config/project-config.yaml contains the four flat top-level
#         artifact-path keys.
#   AC2 — yq parses each surface with no errors and no duplicate keys.
#   AC3 — Canonical template gaia-framework/plugins/gaia/config/project-config.yaml
#         contains the four keys with the listed `docs/*` defaults.
#   AC4 — Existing keys/comments are preserved (smoke: project_root + framework_version
#         still resolve from active file).
#   AC5 — Schema gaia-framework/plugins/gaia/config/project-config.schema.yaml
#         declares all four keys with type `path`.
#
# Negative invariants:
#   - No nested `artifacts:` block introduced (flat-keys-only convention).
#
# Usage:
#   bats tests/skills/e60-s1-flat-artifact-path-keys.bats

# Repo layout: this file lives at gaia-framework/tests/skills/. The active project
# config lives at the project root (one level above gaia-framework/).
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"   # -> .../gaia-framework
PROJECT_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"            # -> .../GAIA-Framework
ACTIVE_CONFIG="${PROJECT_ROOT}/config/project-config.yaml"
TEMPLATE_CONFIG="${REPO_ROOT}/plugins/gaia/config/project-config.yaml"
SCHEMA_FILE="${REPO_ROOT}/plugins/gaia/config/project-config.schema.yaml"
EXAMPLE_FILE="${REPO_ROOT}/plugins/gaia/config/project-config.yaml.example"

# ---------- AC1 — active file has all four flat keys ----------

@test "AC1: active config/project-config.yaml contains planning_artifacts" {
    grep -Eq '^planning_artifacts:' "${ACTIVE_CONFIG}"
}

@test "AC1: active config/project-config.yaml contains implementation_artifacts" {
    grep -Eq '^implementation_artifacts:' "${ACTIVE_CONFIG}"
}

@test "AC1: active config/project-config.yaml contains test_artifacts" {
    grep -Eq '^test_artifacts:' "${ACTIVE_CONFIG}"
}

@test "AC1: active config/project-config.yaml contains creative_artifacts" {
    grep -Eq '^creative_artifacts:' "${ACTIVE_CONFIG}"
}

@test "AC1 smoke: subtask 4.1 grep returns four matches" {
    run grep -cE '^(planning|implementation|test|creative)_artifacts:' "${ACTIVE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" -eq 4 ]
}

# ---------- AC2 — yq parses each surface cleanly, no duplicate keys ----------

@test "AC2: yq parses active config/project-config.yaml without error" {
    run yq '.' "${ACTIVE_CONFIG}"
    [ "${status}" -eq 0 ]
}

@test "AC2: yq parses canonical template without error" {
    run yq '.' "${TEMPLATE_CONFIG}"
    [ "${status}" -eq 0 ]
}

@test "AC2: yq parses schema without error" {
    run yq '.' "${SCHEMA_FILE}"
    [ "${status}" -eq 0 ]
}

@test "AC2: active file has no duplicate top-level artifact-path keys" {
    # Each of the four keys appears exactly once at column 0.
    for key in planning_artifacts implementation_artifacts test_artifacts creative_artifacts; do
        run grep -cE "^${key}:" "${ACTIVE_CONFIG}"
        [ "${status}" -eq 0 ] || return 1
        [ "${output}" -eq 1 ] || { echo "duplicate key: ${key} (count=${output})"; return 1; }
    done
}

# ---------- AC3 — canonical template carries listed `docs/*` defaults ----------

@test "AC3: template defines planning_artifacts: docs/planning-artifacts" {
    run yq -r '.planning_artifacts' "${TEMPLATE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "docs/planning-artifacts" ]
}

@test "AC3: template defines implementation_artifacts: docs/implementation-artifacts" {
    run yq -r '.implementation_artifacts' "${TEMPLATE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "docs/implementation-artifacts" ]
}

@test "AC3: template defines test_artifacts: docs/test-artifacts" {
    run yq -r '.test_artifacts' "${TEMPLATE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "docs/test-artifacts" ]
}

@test "AC3: template defines creative_artifacts: docs/creative-artifacts" {
    run yq -r '.creative_artifacts' "${TEMPLATE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "docs/creative-artifacts" ]
}

# ---------- AC4 — existing keys preserved (smoke) ----------

@test "AC4: active file still has project_root key" {
    grep -Eq '^project_root:' "${ACTIVE_CONFIG}"
}

@test "AC4: active file still has framework_version key" {
    grep -Eq '^framework_version:' "${ACTIVE_CONFIG}"
}

@test "AC4: active file still has installed_path key" {
    grep -Eq '^installed_path:' "${ACTIVE_CONFIG}"
}

# ---------- AC5 — schema declares all four keys with type: path ----------

@test "AC5: schema declares planning_artifacts with type path" {
    run yq -r '.fields.planning_artifacts.type' "${SCHEMA_FILE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "path" ]
}

@test "AC5: schema declares implementation_artifacts with type path" {
    run yq -r '.fields.implementation_artifacts.type' "${SCHEMA_FILE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "path" ]
}

@test "AC5: schema declares test_artifacts with type path" {
    run yq -r '.fields.test_artifacts.type' "${SCHEMA_FILE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "path" ]
}

@test "AC5: schema declares creative_artifacts with type path" {
    run yq -r '.fields.creative_artifacts.type' "${SCHEMA_FILE}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "path" ]
}

# ---------- Negative invariant — no nested `artifacts:` block ----------

@test "negative: active file does NOT introduce a nested artifacts: block" {
    run yq -r '.artifacts // ""' "${ACTIVE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

@test "negative: template does NOT introduce a nested artifacts: block" {
    run yq -r '.artifacts // ""' "${TEMPLATE_CONFIG}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "" ]
}

# ---------- Example file parity (subtask 2.2) ----------

@test "example: yaml.example contains all four flat keys" {
    for key in planning_artifacts implementation_artifacts test_artifacts creative_artifacts; do
        grep -Eq "^${key}:" "${EXAMPLE_FILE}" || { echo "missing key in example: ${key}"; return 1; }
    done
}
