# Pre-sharding profiling report

## Baseline (monolithic bats-tests job)

| Metric | Value |
|--------|-------|
| Total top-level .bats files | 791 |
| Total @test cases | 13013 |
| Typical wall-clock (CI, --jobs 2) | ~19 min |
| Job timeout | 40 min |
| CI queue time (median) | ~2 min |
| Setup overhead | ~15 s |

## Profiling method

Per-file test counts were used as the primary weight for shard
balancing.  Test count correlates well with wall-clock time because
the bats files in this suite are structurally similar: each test
sets up a fixture in $BATS_TEST_TMPDIR, runs a script under test,
and asserts output.  The heaviest files (261 tests in the largest)
are the design/sync suites with many small fixture-driven cases.

Timing data from CI run 39019646250 (staging baseline, 2026-10-17):
- bats-tests: started 09:02:51, completed 09:21:36 = **18m 45s**
- Queue time: ~2s (runner provisioned quickly)
- Setup (checkout + deps): ~16s
- Bats execution: ~18m 29s

## Sharding scheme

4 shards, balanced by per-file test count using greedy bin-packing.

| Shard | Files | Tests | Expected wall (est.) |
|-------|-------|-------|---------------------|
| 1 | 198 | 3254 | ~4.8 min |
| 2 | 197 | 3253 | ~4.7 min |
| 3 | 198 | 3253 | ~4.7 min |
| 4 | 198 | 3253 | ~4.7 min |

**Balance ratio**: 1.00x (target < 1.5x)

## Shard timeout

Expected per-shard wall-clock: ~5 min (19 min / 4 shards, with --jobs 2).
Per-shard timeout: 12 min = 2.4x the expected runtime (>50% headroom).

## Top 10 heaviest files

| File | Tests | Shard |
|------|-------|-------|
| create-ux-claude-design.bats | 261 | 1 |
| build-manifest-cards.bats | 247 | 2 |
| sync-derived-artifacts.bats | 187 | 3 |
| design-record-v2-migration.bats | 154 | 4 |
| design-gate.bats | 139 | 4 |
| design-record.bats | 126 | 3 |
| round-lifecycle.bats | 125 | 2 |
| phase-parallel-orchestrator.bats | 120 | 1 |
| findings-register.bats | 109 | 4 |
| sprint-status-dashboard-cache.bats | 102 | 3 |

## macOS bash 3.2 coverage (AC-EC4)

The macOS bash 3.2 job runs as a separate dimension
alongside the 4 Linux shards.  It is not a shard of the Linux suite
because it runs a curated subset of bash-3.2-sensitive tests (not the
full 791 files) on a macOS runner with the system /bin/bash 3.2 and
BSD tools.

Sharding plan for macOS:
- Linux: 4 shards of ~198 files each, balanced by test count
- macOS: 1 dedicated job running component test partitions (scripts-lib,
  scripts-sprint) plus portability-specific suites

The two dimensions are orthogonal:
- Linux shards cover the full test surface on the CI reference platform
- macOS covers bash-3.2 portability on the developer-facing platform
