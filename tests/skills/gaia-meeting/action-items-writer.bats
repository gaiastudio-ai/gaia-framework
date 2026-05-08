#!/usr/bin/env bats
# action-items-writer.bats — gaia-meeting v2 action-items registry writer (E76-S3)
#
# AC2 / AC5 / FR-MTG-21 / ADR-086 / TC-MTG-AI-3 / TC-MTG-AI-4 / TC-MTG-AI-6

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/action-items-writer.sh"
  TMPDIR_T="$(mktemp -d)"
  REGISTRY="$TMPDIR_T/action-items.yaml"
  DRAFT_DIR="$TMPDIR_T/drafts"
  mkdir -p "$DRAFT_DIR"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

@test "Pre-flight: action-items-writer.sh exists and is executable" {
  [ -x "$WRITER" ]
}

# Helper: write a v1 registry to test idempotent header bump
_seed_v1_registry() {
  cat > "$REGISTRY" <<'YAML'
# Action Items — architecture §10.28.6 schema
items:

- id: AI-1
  sprint_id: "sprint-31"
  text: "Legacy item one"
  classification: implementation
  status: open
  escalation_count: 0
  created_at: "2026-04-28T11:06:47Z"
  theme_hash: "sha256:aaaa"

- id: AI-2
  sprint_id: "sprint-31"
  text: "Legacy item two"
  classification: process
  status: open
  escalation_count: 0
  created_at: "2026-04-28T11:06:47Z"
  theme_hash: "sha256:bbbb"
YAML
}

# Helper: build a single drafted action-items YAML payload
_seed_draft() {
  local count="${1:-1}"
  local out="$DRAFT_DIR/items.yaml"
  : > "$out"
  for ((i=1; i<=count; i++)); do
    cat >> "$out" <<YAML
- type: feature
  priority: normal
  assignee: "derek"
  context_for_target: "Draft item ${i} context"
  acceptance: "Draft item ${i} acceptance"
YAML
  done
  echo "$out"
}

@test "AC2: header gains schema_version: 2 on first v2 write to v1 registry" {
  _seed_v1_registry
  draft="$(_seed_draft 1)"
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07
  [ "$status" -eq 0 ]
  grep -q '^schema_version: 2$' "$REGISTRY"
}

@test "AC2: pre-existing v1 entries remain byte-identical after v2 append" {
  _seed_v1_registry
  pre_hash=$(grep -E '^- id: AI-[12]$|^  text:|^  classification:|^  theme_hash:' "$REGISTRY" | sha256sum | awk '{print $1}')
  draft="$(_seed_draft 1)"
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07
  [ "$status" -eq 0 ]
  post_hash=$(grep -E '^- id: AI-[12]$|^  text:|^  classification:|^  theme_hash:' "$REGISTRY" | sha256sum | awk '{print $1}')
  [ "$pre_hash" = "$post_hash" ]
}

@test "AC2: v2 entry carries all required fields (id, created, source_meeting, type, priority, status, target_command, assignee, context_for_target, acceptance)" {
  _seed_v1_registry
  draft="$(_seed_draft 1)"
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07
  [ "$status" -eq 0 ]
  for field in id created source_meeting type priority status target_command assignee context_for_target acceptance; do
    grep -qE "(^|[[:space:]-])${field}:" "$REGISTRY" || { echo "missing field: $field"; cat "$REGISTRY"; return 1; }
  done
}

@test "AC2: id format AI-{YYYY-MM-DD}-{N}" {
  _seed_v1_registry
  draft="$(_seed_draft 1)"
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07
  [ "$status" -eq 0 ]
  grep -qE '^- id: AI-2026-05-07-[0-9]+$' "$REGISTRY"
}

@test "AC2: idempotent header bump — second run does not duplicate schema_version" {
  _seed_v1_registry
  draft="$(_seed_draft 1)"
  "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "meeting-2026-05-07-fixture" --date 2026-05-07
  draft2="$(_seed_draft 1)"
  "$WRITER" --registry "$REGISTRY" --drafts "$draft2" --source-meeting "meeting-2026-05-07-fixture-2" --date 2026-05-07
  count=$(grep -c '^schema_version: 2$' "$REGISTRY")
  [ "$count" -eq 1 ]
}

@test "AC2 / TC-MTG-AI-3: daily-N reset — second meeting same day continues count, next day restarts at 1" {
  _seed_v1_registry
  d1="$(_seed_draft 3)"
  "$WRITER" --registry "$REGISTRY" --drafts "$d1" --source-meeting "m1" --date 2026-05-07
  grep -qE '^- id: AI-2026-05-07-1$' "$REGISTRY"
  grep -qE '^- id: AI-2026-05-07-3$' "$REGISTRY"

  d2="$(_seed_draft 2)"
  "$WRITER" --registry "$REGISTRY" --drafts "$d2" --source-meeting "m2" --date 2026-05-07
  grep -qE '^- id: AI-2026-05-07-4$' "$REGISTRY"
  grep -qE '^- id: AI-2026-05-07-5$' "$REGISTRY"

  d3="$(_seed_draft 1)"
  "$WRITER" --registry "$REGISTRY" --drafts "$d3" --source-meeting "m3" --date 2026-05-08
  grep -qE '^- id: AI-2026-05-08-1$' "$REGISTRY"
}

@test "AC5: discussion-only items emit type: discussion-only and target_command: 'no target — discussion-only'" {
  _seed_v1_registry
  draft="$DRAFT_DIR/disc.yaml"
  cat > "$draft" <<'YAML'
- type: discussion-only
  priority: normal
  assignee: "user"
  context_for_target: "discussion-only context"
  acceptance: "—"
YAML
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "m-disc" --date 2026-05-07
  [ "$status" -eq 0 ]
  grep -qE '^[[:space:]]*type: discussion-only' "$REGISTRY"
  grep -qE 'target_command: "no target — discussion-only"' "$REGISTRY"
}

@test "AC2: writer rejects unknown type (no silent coercion)" {
  _seed_v1_registry
  draft="$DRAFT_DIR/bad.yaml"
  cat > "$draft" <<'YAML'
- type: not-a-real-type
  priority: normal
  assignee: "x"
  context_for_target: "x"
  acceptance: "x"
YAML
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "m-bad" --date 2026-05-07
  [ "$status" -ne 0 ]
  [ "$status" -ne 127 ]
}

@test "AC2: writer creates registry from scratch when --registry path missing" {
  rm -f "$REGISTRY"
  draft="$(_seed_draft 1)"
  run "$WRITER" --registry "$REGISTRY" --drafts "$draft" --source-meeting "m-new" --date 2026-05-07
  [ "$status" -eq 0 ]
  [ -f "$REGISTRY" ]
  grep -q '^schema_version: 2$' "$REGISTRY"
}
