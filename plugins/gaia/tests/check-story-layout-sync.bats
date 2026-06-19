#!/usr/bin/env bats
# check-story-layout-sync.bats — coverage for plugins/gaia/scripts/check-story-layout-sync.sh
#
# Story: E79-S5 — Static `monolith-shard-sync` extension — `story-layout-sync` advisory check.
# Trace: TC-CSP-7
# Refs:  AC1, AC2, AC3, AC4, AC5, AC6, AC7
#
# Public functions covered by this bats file (NFR-052 coverage gate):
#   - check_legacy_flat_path        (Check A — AC1)
#   - check_heterogeneous_story_index (Check B — AC2)
#   - check_epic_slug_mismatch      (Check C — AC3)
#
# The script is advisory: it ALWAYS exits 0 and emits WARNING lines on stdout
# when story-layout drift is detected. CRITICAL is never emitted by the three
# checks (AC4). The line format mirrors check-monolith-shard-sync.sh:
#   {SEVERITY} story-layout-sync: {check-id} {detail-fields...}

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  CHECK_SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/check-story-layout-sync.sh"
  cd "$TEST_TMP"
  mkdir -p docs/implementation-artifacts
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Fixture helpers.
# ---------------------------------------------------------------------------

# _make_canonical_story <epic_key> <epic_slug> <story_key> <slug> [fm_epic_override]
# Writes a canonical per-epic story file under
# docs/implementation-artifacts/epic-<epic_key>-<epic_slug>/stories/<story_key>-<slug>.md
_make_canonical_story() {
  local epic_key="$1" epic_slug="$2" story_key="$3" slug="$4" fm_epic="${5:-$1}"
  local epic_dir="docs/implementation-artifacts/epic-${epic_key}-${epic_slug}"
  local stories_dir="${epic_dir}/stories"
  mkdir -p "$stories_dir"
  cat > "${stories_dir}/${story_key}-${slug}.md" <<EOF
---
key: "${story_key}"
title: "Test story ${story_key}"
epic: "${fm_epic}"
status: ready-for-dev
---

# Story body
EOF
}

# _make_flat_story <story_key> <slug>
# Writes a legacy flat-path story directly under docs/implementation-artifacts/.
_make_flat_story() {
  local story_key="$1" slug="$2"
  cat > "docs/implementation-artifacts/${story_key}-${slug}.md" <<EOF
---
key: "${story_key}"
title: "Legacy flat story ${story_key}"
epic: "$(printf '%s' "$story_key" | sed 's/-S.*//')"
status: ready-for-dev
---

# Body
EOF
}

# _make_flat_story_index — writes a flat docs/implementation-artifacts/story-index.yaml.
_make_flat_story_index() {
  cat > "docs/implementation-artifacts/story-index.yaml" <<'EOF'
# legacy flat story-index
stories: []
EOF
}

# _make_per_epic_story_index <epic_key> <epic_slug>
_make_per_epic_story_index() {
  local epic_key="$1" epic_slug="$2"
  local stories_dir="docs/implementation-artifacts/epic-${epic_key}-${epic_slug}/stories"
  mkdir -p "$stories_dir"
  cat > "${stories_dir}/story-index.yaml" <<EOF
# per-epic story-index for ${epic_key}
stories: []
EOF
}

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

# TS1 / AC6 — clean run: a fully converged tree emits no WARNING / CRITICAL.
@test "clean run: zero findings, exit 0, no WARNING/CRITICAL on stdout" {
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync"
  _make_per_epic_story_index "E79" "canonical-layout"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q '^WARNING'
  ! printf '%s\n' "$output" | grep -q '^CRITICAL'
}

# TS2 / AC1 — single legacy flat-path story emits exactly one WARNING legacy-flat-path line.
@test "legacy flat-path single offender emits one WARNING legacy-flat-path line" {
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync"
  _make_flat_story "E80-S1" "test-flat"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]

  local n
  n="$(printf '%s\n' "$output" | grep -c 'legacy-flat-path' || true)"
  [ "$n" -eq 1 ]

  printf '%s\n' "$output" \
    | grep -q '^WARNING story-layout-sync: legacy-flat-path docs/implementation-artifacts/E80-S1-test-flat\.md$'
}

# AC1 — multiple legacy flat-path stories each get one WARNING line.
@test "multiple legacy flat-path offenders each get a WARNING line" {
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync"
  _make_flat_story "E80-S1" "alpha"
  _make_flat_story "E80-S2" "beta"
  _make_flat_story "E81-S1" "gamma"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]

  local n
  n="$(printf '%s\n' "$output" | grep -c 'legacy-flat-path' || true)"
  [ "$n" -eq 3 ]
}

# TS3 / AC2 — heterogeneous story-index: exactly one WARNING line.
@test "heterogeneous story-index emits exactly one WARNING line with flat + first per-epic path" {
  _make_canonical_story "E78" "alpha" "E78-S1" "x"
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync"
  _make_flat_story_index
  _make_per_epic_story_index "E78" "alpha"
  _make_per_epic_story_index "E79" "canonical-layout"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]

  local n
  n="$(printf '%s\n' "$output" | grep -c 'heterogeneous-story-index' || true)"
  [ "$n" -eq 1 ]

  # The line must mention the flat path AND the lexicographically first per-epic path.
  printf '%s\n' "$output" \
    | grep '^WARNING story-layout-sync: heterogeneous-story-index ' \
    | grep -q 'docs/implementation-artifacts/story-index.yaml'

  printf '%s\n' "$output" \
    | grep '^WARNING story-layout-sync: heterogeneous-story-index ' \
    | grep -q 'docs/implementation-artifacts/epic-E78-alpha/stories/story-index.yaml'
}

# AC2 — only flat story-index (no per-epic ones) does NOT trigger heterogeneous warning.
@test "only flat story-index alone does not trigger heterogeneous-story-index" {
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync"
  _make_flat_story_index

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'heterogeneous-story-index'
}

# AC2 — only per-epic story-index files (no flat) do NOT trigger heterogeneous warning.
@test "only per-epic story-index files alone do not trigger heterogeneous-story-index" {
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync"
  _make_per_epic_story_index "E79" "canonical-layout"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'heterogeneous-story-index'
}

# TS4 / AC3 — epic-slug-mismatch: one WARNING line naming the file, dir epic-key, frontmatter value.
@test "epic-slug-mismatch emits one WARNING line with file, dir epic-key, fm value" {
  # Story file lives under epic-E79-... but its frontmatter declares epic: "E80".
  _make_canonical_story "E79" "canonical-layout" "E80-S1" "wrong-epic" "E80"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]

  local n
  n="$(printf '%s\n' "$output" | grep -c 'epic-slug-mismatch' || true)"
  [ "$n" -eq 1 ]

  printf '%s\n' "$output" \
    | grep '^WARNING story-layout-sync: epic-slug-mismatch ' \
    | grep -q 'docs/implementation-artifacts/epic-E79-canonical-layout/stories/E80-S1-wrong-epic\.md'

  printf '%s\n' "$output" \
    | grep '^WARNING story-layout-sync: epic-slug-mismatch ' \
    | grep -q 'dir=E79'

  printf '%s\n' "$output" \
    | grep '^WARNING story-layout-sync: epic-slug-mismatch ' \
    | grep -q 'fm=E80'
}

# AC3 — matching frontmatter does not trigger mismatch.
@test "matching epic frontmatter does not trigger epic-slug-mismatch" {
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync" "E79"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'epic-slug-mismatch'
}

# TS5 — all three classes simultaneously: all three check-ids appear, exit 0.
@test "all three drift classes simultaneously: each check-id appears at least once, exit 0" {
  # Per-epic clean story (ensures the heterogeneous check has a per-epic match)
  # plus a per-epic story with mismatched frontmatter.
  _make_canonical_story "E79" "canonical-layout" "E79-S5" "story-layout-sync" "E79"
  _make_canonical_story "E79" "canonical-layout" "E80-S1" "wrong-epic" "E80"
  _make_flat_story "E81-S1" "legacy"
  _make_flat_story_index
  _make_per_epic_story_index "E79" "canonical-layout"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]

  printf '%s\n' "$output" | grep -q 'legacy-flat-path'
  printf '%s\n' "$output" | grep -q 'heterogeneous-story-index'
  printf '%s\n' "$output" | grep -q 'epic-slug-mismatch'
  ! printf '%s\n' "$output" | grep -q '^CRITICAL'
}

# TS6 / AC4 — advisory exit invariant: exit 0 in every scenario.
@test "advisory exit invariant — exit 0 with all three drift classes" {
  _make_canonical_story "E79" "canonical-layout" "E80-S1" "wrong-epic" "E80"
  _make_flat_story "E81-S1" "legacy"
  _make_flat_story_index
  _make_per_epic_story_index "E79" "canonical-layout"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
}

# AC5 — line format parity: every emitted finding line conforms to
# `WARNING story-layout-sync: {check-id} ...` and uses one of the three known check-ids.
@test "emitted lines conform to canonical line format" {
  _make_canonical_story "E79" "canonical-layout" "E80-S1" "wrong-epic" "E80"
  _make_flat_story "E81-S1" "legacy"
  _make_flat_story_index
  _make_per_epic_story_index "E79" "canonical-layout"

  run "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]

  # Every WARNING line must start with `WARNING story-layout-sync: ` and the
  # next token must be one of the three known check-ids.
  while IFS= read -r line; do
    case "$line" in
      'WARNING story-layout-sync: legacy-flat-path '*) ;;
      'WARNING story-layout-sync: heterogeneous-story-index '*) ;;
      'WARNING story-layout-sync: epic-slug-mismatch '*) ;;
      *)
        printf 'unexpected WARNING line: %q\n' "$line" >&2
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$output" | grep '^WARNING' || true)
}

# AC7 — pattern parity: the script lives at the canonical path, has the right shebang,
# and uses `set -euo pipefail`.
@test "script has correct shebang, set -euo pipefail, and lives at canonical path" {
  [ -f "$CHECK_SCRIPT" ]
  [ -x "$CHECK_SCRIPT" ]

  # Shebang on first line.
  run head -n1 "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "#!/usr/bin/env bash" ]

  # set -euo pipefail somewhere near the top (within first 50 lines).
  run head -n50 "$CHECK_SCRIPT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'set -euo pipefail'
}
