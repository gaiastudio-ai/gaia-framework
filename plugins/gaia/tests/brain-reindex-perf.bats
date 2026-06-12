#!/usr/bin/env bats
# brain-reindex-perf.bats — performance budget coverage for the reindex sweep.
#
# The naive per-node sweep (forking python3 6x/node + re-scanning the 22K-line
# epics and 5K-line matrix per node) blows the budget by ~3.7x. Two fixes neutral
# that: a once-per-sweep PyYAML-presence cache and a single-pass pre-slice of the
# shared epics/matrix files. These tests assert the budget those fixes buy.
#
# Fixtures are generated at runtime (hundreds of minimal markdown files across
# the three layouts) and never committed.
#
# The full 500-artifact budget test is tagged slow/perf and skipped unless
# GAIA_RUN_PERF=1 is set (it is gated in CI to a nightly/perf lane). A small
# proportional ~50-file early-warning runs on every pass to catch gross
# regressions cheaply.

load 'test_helper.bash'

setup() {
  common_setup
  REINDEX="$SCRIPTS_DIR/brain/gaia-brain-reindex.sh"
  PROJ="$TEST_TMP/proj"
  export CLAUDE_PROJECT_ROOT="$PROJ"
}

teardown() {
  unset CLAUDE_PROJECT_ROOT
  common_teardown
}

# _gen_corpus <count> — generate <count> minimal story artifacts spread across
# the three layouts, plus a shared epics + matrix fragment that references them.
_gen_corpus() {
  local count="$1"
  local impl="$PROJ/.gaia/artifacts/implementation-artifacts"
  local plan="$PROJ/.gaia/artifacts/planning-artifacts"
  local strat="$PROJ/.gaia/artifacts/test-artifacts/strategy"
  mkdir -p "$impl/epic-E777-perf/stories" "$plan" "$strat" "$PROJ/.gaia/state"

  local epics="$plan/epics-and-stories.md"
  local matrix="$strat/traceability-matrix.md"
  printf '# Epics and Stories (perf corpus)\n\n' > "$epics"
  printf '# Traceability Matrix (perf corpus)\n\n## 1. Functional Requirements\n\n' > "$matrix"
  printf '| FR ID | Description | Story(s) | Unit | Integration | Coverage |\n' >> "$matrix"
  printf '|-------|-------------|----------|------|-------------|----------|\n' >> "$matrix"

  local i key tier dir
  i=1
  while [ "$i" -le "$count" ]; do
    key="E777-S$i"
    tier=$(( i % 3 ))
    case "$tier" in
      0) dir="$impl/epic-E777-perf/$key-perf"; mkdir -p "$dir"
         _emit_story "$dir/story.md" "$key" ;;
      1) dir="$impl/epic-E777-perf/stories"
         _emit_story "$dir/$key-perf.md" "$key" ;;
      2) dir="$impl"
         _emit_story "$dir/$key-perf.md" "$key" ;;
    esac
    printf '### Story %s: perf node\n\n- **Allocates:** FR-%d (perf req)\n\n---\n\n' "$key" "$i" >> "$epics"
    printf '| FR-%d | perf req | %s | — | — | Planned |\n' "$i" "$key" >> "$matrix"
    i=$(( i + 1 ))
  done

  printf 'schema_version: 1\nsprint_id: sprint-perf\nstatus: active\nstories: []\n' \
    > "$PROJ/.gaia/state/sprint-status.yaml"
}

_emit_story() {
  local path="$1" key="$2"
  cat > "$path" <<EOF
---
template: 'story'
key: "$key"
title: "Perf node $key"
epic: "E777"
status: backlog
traces_to: ["FR-900"]
---

# Story: Perf node $key

A minimal generated perf-corpus artifact.
EOF
}

_time_reindex() {
  local start end
  start="$(date +%s)"
  run bash "$REINDEX"
  end="$(date +%s)"
  ELAPSED=$(( end - start ))
}

# Proportional early-warning: ~50 files must sweep well within a small budget on
# every CI pass. Scaled from the 120s/500 budget (12s) with generous headroom.
@test "a small proportional corpus sweeps within the scaled budget" {
  _gen_corpus 50
  _time_reindex
  [ "$status" -eq 0 ]
  echo "elapsed=${ELAPSED}s for 50 artifacts" >&3
  [ "$ELAPSED" -lt 30 ]
}

@test "a 500-artifact corpus completes within 120 seconds" {
  [ "${GAIA_RUN_PERF:-0}" = "1" ] || skip "perf lane (set GAIA_RUN_PERF=1)"
  _gen_corpus 500
  _time_reindex
  [ "$status" -eq 0 ]
  echo "elapsed=${ELAPSED}s for 500 artifacts" >&3
  [ "$ELAPSED" -lt 120 ]
}

@test "sprint-close reindex overhead stays under 30 seconds" {
  [ "${GAIA_RUN_PERF:-0}" = "1" ] || skip "perf lane (set GAIA_RUN_PERF=1)"
  _gen_corpus 500
  local finalize="$SCRIPTS_DIR/../skills/gaia-sprint-close/scripts/finalize.sh"

  # The sprint-close reindex runs AFTER an index already exists (the cold first
  # sweep amortizes once; sprint-close is the warm steady-state case). The
  # content-hash short-circuit makes a warm re-sweep O(delta): unchanged files
  # carry their prior synopsis + edges forward without re-harvesting. Measure
  # that warm overhead, which is the real sprint-close cost.
  bash "$REINDEX" >/dev/null 2>&1   # warm the index (amortized first sweep)

  local start end elapsed
  start="$(date +%s)"
  GAIA_BRAIN_REINDEX_BIN="$REINDEX" run bash "$finalize"
  end="$(date +%s)"
  elapsed=$(( end - start ))
  [ "$status" -eq 0 ]
  echo "sprint-close warm overhead=${elapsed}s for 500 artifacts" >&3
  [ "$elapsed" -lt 30 ]
}
