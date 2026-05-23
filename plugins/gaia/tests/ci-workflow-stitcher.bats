#!/usr/bin/env bats
# ci-workflow-stitcher.bats — E98-S2 (FR-517, ADR-114, TC-CCL-4/5/8)
#
# Verifies the four-phase stitching engine at
# scripts/lib/ci-workflow-stitcher.sh:
#   (1) GAIA template scaffold
#   (2) user-steps.steps_before_gaia spliced BEFORE the managed steps block
#   (3) GAIA-generated jobs unioned with user-jobs.yml entries
#   (4) user-steps.steps_after_gaia spliced AFTER the managed steps block

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_DIR="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
  STITCHER="$PLUGIN_DIR/scripts/lib/ci-workflow-stitcher.sh"
  WORKDIR="$TEST_TMP/.github/workflows"
  mkdir -p "$WORKDIR"
}

teardown() {
  common_teardown
}

# ---------- TC-CCL-4: user-jobs.yml YAML-merge into managed jobs: map ----------

@test "TC-CCL-4: user-jobs.yml jobs merge into managed jobs: map" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
# Managed by GAIA
name: ci
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
YAML

  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
# User-jobs overlay — merged into the managed jobs: map.
jobs:
  coverage-upload:
    runs-on: ubuntu-latest
    steps:
      - run: echo coverage
  notify-slack:
    runs-on: ubuntu-latest
    steps:
      - run: echo slack
YAML

  run bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'"
  [ "$status" -eq 0 ]

  # All three job names present in stitched output
  printf '%s\n' "$output" | grep -q '^  lint:'
  printf '%s\n' "$output" | grep -q '^  coverage-upload:'
  printf '%s\n' "$output" | grep -q '^  notify-slack:'
}

# ---------- TC-CCL-5: steps_before_gaia / steps_after_gaia splicing ----------

@test "TC-CCL-5: user-steps overlay splices steps_before / steps_after around managed steps" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: gaia-checkout
        uses: actions/checkout@v4
      - name: gaia-build
        run: echo build
YAML

  cat > "$WORKDIR/gaia-ci.user-steps.yml" <<'YAML'
steps_before_gaia:
  - name: user-pre
    run: echo before
steps_after_gaia:
  - name: user-post
    run: echo after
YAML

  run bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'"
  [ "$status" -eq 0 ]

  # All step names present
  printf '%s\n' "$output" | grep -q 'name: user-pre'
  printf '%s\n' "$output" | grep -q 'name: gaia-checkout'
  printf '%s\n' "$output" | grep -q 'name: gaia-build'
  printf '%s\n' "$output" | grep -q 'name: user-post'

  # Ordering: user-pre BEFORE gaia-checkout BEFORE gaia-build BEFORE user-post
  line_pre=$(  printf '%s\n' "$output" | grep -n 'name: user-pre'     | head -1 | cut -d: -f1)
  line_co=$(   printf '%s\n' "$output" | grep -n 'name: gaia-checkout'| head -1 | cut -d: -f1)
  line_build=$(printf '%s\n' "$output" | grep -n 'name: gaia-build'   | head -1 | cut -d: -f1)
  line_post=$( printf '%s\n' "$output" | grep -n 'name: user-post'    | head -1 | cut -d: -f1)
  [ "$line_pre" -lt "$line_co" ]
  [ "$line_co" -lt "$line_build" ]
  [ "$line_build" -lt "$line_post" ]
}

# ---------- TC-CCL-8: ten-run byte-identical determinism ----------

@test "TC-CCL-8: ten consecutive runs produce byte-identical output (sha256 match)" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: gaia-checkout
        uses: actions/checkout@v4
      - name: gaia-lint
        run: echo lint
YAML

  cat > "$WORKDIR/gaia-ci.user-jobs.yml" <<'YAML'
jobs:
  coverage-upload:
    runs-on: ubuntu-latest
    steps:
      - run: echo coverage
  notify-slack:
    runs-on: ubuntu-latest
    steps:
      - run: echo slack
YAML

  cat > "$WORKDIR/gaia-ci.user-steps.yml" <<'YAML'
steps_before_gaia:
  - name: user-pre
    run: echo before
steps_after_gaia:
  - name: user-post
    run: echo after
YAML

  # Capture sha256 of 10 consecutive runs
  local hash first
  first=""
  for i in $(seq 1 10); do
    out=$(bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'")
    hash=$(printf '%s' "$out" | shasum -a 256 | awk '{print $1}')
    if [ -z "$first" ]; then
      first="$hash"
    else
      [ "$hash" = "$first" ] || {
        echo "iteration $i hash $hash != first $first" >&2
        return 1
      }
    fi
  done
}

# ---------- Sanity: no overlay → output equals input (template-only path) ----------

@test "no overlay: stitcher emits managed workflow unchanged" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
YAML

  run bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^  lint:'
  # No injected user-* anything
  ! printf '%s\n' "$output" | grep -q 'user-'
}

# ---------- Source-guard sanity ----------

@test "source-guard: double-source is idempotent" {
  run bash -c "source '$STITCHER' && source '$STITCHER' && declare -F gaia_ci_stitch >/dev/null && echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- AC3/AC4 implicit: stitched output is structurally valid YAML ----------

@test "stitched output is valid YAML parseable by yq (AC3/AC4 implicit)" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: gaia-checkout
        uses: actions/checkout@v4
      - name: gaia-build
        run: echo build
YAML

  cat > "$WORKDIR/gaia-ci.user-steps.yml" <<'YAML'
steps_before_gaia:
  - name: user-pre
    run: echo before
steps_after_gaia:
  - name: user-post
    run: echo after
YAML

  out=$(bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'")
  # Round-trip through yq to confirm structural validity.
  printf '%s' "$out" | yq eval '.' >/dev/null
}

@test "stitched output preserves comments (AC5)" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
# top-level managed comment
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    # managed-step comment
    steps:
      - name: gaia-checkout
        uses: actions/checkout@v4
YAML

  run bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '# top-level managed comment'
  printf '%s\n' "$output" | grep -q '# managed-step comment'
}

# ---------- TEST_TMP is NOT required at runtime (Critical 1 fix) ----------

@test "gaia_ci_stitch works without TEST_TMP defined (production-callable)" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: gaia-checkout
        uses: actions/checkout@v4
YAML

  cat > "$WORKDIR/gaia-ci.user-steps.yml" <<'YAML'
steps_before_gaia:
  - name: user-pre
    run: echo before
steps_after_gaia: []
YAML

  # Clear TEST_TMP for this invocation only — function MUST resolve its
  # own temp dir via mktemp.
  run env -u TEST_TMP bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'name: user-pre'
}

# ---------- Block-level only: no per-step insert_after/insert_before honored ----------

@test "block-level only: per-step markers are NOT honored (deliberate FR-517 scope cut)" {
  cat > "$WORKDIR/gaia-ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: gaia-checkout
        uses: actions/checkout@v4
      - name: gaia-build
        run: echo build
YAML

  # Overlay with a stray per-step marker — must be IGNORED, not honored
  cat > "$WORKDIR/gaia-ci.user-steps.yml" <<'YAML'
steps_before_gaia:
  - name: stray-with-marker
    insert_after: gaia-checkout
    run: echo stray
steps_after_gaia: []
YAML

  run bash -c "source '$STITCHER' && gaia_ci_stitch '$WORKDIR/gaia-ci.yml'"
  [ "$status" -eq 0 ]

  # stray-with-marker MUST land in the steps_before_gaia slot (top of managed
  # steps block), NOT split-inserted after gaia-checkout per its (ignored) marker.
  line_stray=$(    printf '%s\n' "$output" | grep -n 'name: stray-with-marker' | head -1 | cut -d: -f1)
  line_checkout=$( printf '%s\n' "$output" | grep -n 'name: gaia-checkout'     | head -1 | cut -d: -f1)
  [ "$line_stray" -lt "$line_checkout" ]
}
