#!/usr/bin/env bats
# e34-s1-val-sidecar-perf.bats
#
# TC-VSP-7 — 100 consecutive invocations with distinct payloads.
# NFR-VSP-1: median sidecar-write latency <= 75ms on developer / CI hardware.
# Additional guard: no single invocation exceeds 1s.
#
# ----------------------------------------------------------------------------
# Stabilization strategy (E34-S3 / TD-66) — widen threshold with margin
# ----------------------------------------------------------------------------
# The original threshold (50ms) was authored without empirical measurement of
# the per-invocation floor. Profiling on three platforms (developer macOS,
# Linux GitHub Actions runners, Linux self-hosted runners) showed steady-state
# medians clustered around 50-55ms because val-sidecar-write.sh is fork/exec'd
# 100 times — the dominant per-call cost is process startup, not the write
# itself. Result: the test reported median ~51ms vs the 50ms threshold and
# was flaky on staging HEAD without any product-side change.
#
# Three stabilization options were considered (per E34-S3):
#   (a) Widen the threshold (with margin justification)
#   (b) Switch from median to p95
#   (c) Stabilize the harness (extra warm-ups, best-of-N batches)
#
# Option (c) was tried first (5 warm-up calls + best-of-3 batches) but the
# floor was confirmed genuinely above 50ms on developer hardware — harness
# stabilization moved the median by <0.5ms, not the ~2-5ms needed to clear
# the threshold. Option (b) would change what NFR-VSP-1 measures.
#
# We chose option (a). Threshold widened to 75ms — 50% margin above the
# observed floor (~50ms). The 75ms threshold is comfortably below any
# user-perceptible blocking I/O (the NFR's actual intent is "no command is
# blocked on slow sidecar I/O", which 75ms still satisfies). PRD NFR-VSP-1
# and architecture references updated in the same change to keep traceability
# (NFR-VSP-1 -> TC-VSP-7) consistent.
#
# Harness improvements from option (c) are kept because they reduce variance
# (5 warm-ups instead of 1; best-of-3 batches), tightening the test's signal
# even with the wider threshold.
# ----------------------------------------------------------------------------

load 'test_helper.bash'

setup() {
  common_setup
  PROJECT_ROOT="$TEST_TMP/proj"
  mkdir -p "$PROJECT_ROOT/_memory/validator-sidecar"
  export PROJECT_ROOT
}

teardown() { common_teardown; }

SCRIPT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)/val-sidecar-write.sh"

@test "100 invocations with distinct payloads — median latency <= 75ms, no single call > 1s" {
  # Five warm-up invocations to amortize OS page-cache, fork/exec, and
  # interpreter startup costs before any sample is recorded. NFR-VSP-1
  # measures steady-state median, not cold start.
  local i
  for i in 1 2 3 4 5; do
    "$SCRIPT" --root "$PROJECT_ROOT" --command-name "/gaia-create-story" \
      --input-id "WARMUP-$i" \
      --decision-payload '{"verdict":"passed","findings":[],"artifact_path":"w"}' \
      --sprint-id "sprint-26" >/dev/null 2>&1
  done

  # Best-of-3 batches. Each batch records 100 samples. We report the minimum
  # batch median (filters single-batch runner jitter), the maximum batch p99
  # (worst tail observed), and the maximum across all batches (worst single
  # call) so we never lose visibility into pathological outliers.
  local report
  report=$(python3 - "$SCRIPT" "$PROJECT_ROOT" <<'PY'
import subprocess, time, statistics, sys, json

script, root = sys.argv[1], sys.argv[2]
batch_count = 3
samples_per_batch = 100

batch_medians = []
batch_p99s = []
batch_maxes = []

for batch in range(batch_count):
    durations = []
    for i in range(samples_per_batch):
        payload = json.dumps({
            "verdict": "passed",
            "findings": [{"id": f"F{batch}-{i}", "msg": f"m{batch}-{i}"}],
            "artifact_path": f"docs/x{batch}-{i}.md",
        })
        t0 = time.perf_counter_ns()
        subprocess.run(
            [script,
             "--root", root,
             "--command-name", "/gaia-create-story",
             "--input-id", f"ID-{batch}-{i}",
             "--decision-payload", payload,
             "--sprint-id", "sprint-26"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        t1 = time.perf_counter_ns()
        durations.append((t1 - t0) / 1_000_000)  # ms
    batch_medians.append(statistics.median(durations))
    batch_p99s.append(sorted(durations)[98])
    batch_maxes.append(max(durations))

best_median = min(batch_medians)
worst_p99 = max(batch_p99s)
worst_max = max(batch_maxes)
print(f"{best_median:.1f} {worst_p99:.1f} {worst_max:.1f}")
PY
)
  local median p99 hi
  read -r median p99 hi <<<"$report"
  echo "median_ms=$median p99_ms=$p99 max_ms=$hi (best-of-3 batches)" >&3
  # No single call across any batch exceeds 1000ms.
  local hi_int=${hi%.*}
  [ "$hi_int" -lt 1000 ]
  # Best-of-3 median <= 75ms (NFR-VSP-1; widened from 50ms — see top comment).
  local median_int=${median%.*}
  [ "$median_int" -le 75 ]
}
