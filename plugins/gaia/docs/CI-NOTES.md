# CI Notes — bats Sharding and Wall-Clock Budget

> **Why this file exists.** The `bats-tests` gate in `plugin-ci.yml` is the
> framework's primary integration gate. The full suite (~13000 tests across
> ~791 top-level .bats files) is split into 4 parallel shards to keep
> CI wall-clock under 10 minutes. This runbook tells contributors how
> the sharding works, how to add new tests, and when to rebalance.

## TL;DR

- **Architecture:** 4 parallel shard jobs (`bats-shard-1` through
  `bats-shard-4`) feed into a `bats-tests` gate job that runs the
  static public-function coverage check and plugin validation.
- **Per-shard timeout:** 12 min (~50% headroom over the expected ~5 min).
- **Fast feedback:** `bats-fast-feedback` runs diff-selected tests and
  reports within minutes, independently of the full regression suite.
- **Superseded runs:** cancelled automatically via workflow `concurrency`.
- **Required check:** `bats-tests` (the gate job) is the branch-protection
  required status check.  It passes only when all 4 shards pass.
- **Escalation triggers:** see the bats-scaling ADR Appendix B.

## Shard architecture

The monolithic `bats-tests` job was replaced by a 4-shard matrix.  Each
shard runs on its own runner, so temp directories, fixtures, and state
files are inherently isolated (no shared `/tmp/gaia-*` paths).

### CI job names

| Job | Purpose | Timeout |
|-----|---------|---------|
| `bats-fast-feedback` | Diff-selected tests for early signal | 5 min |
| `bats-shard-1` .. `bats-shard-4` | Parallel regression shards | 12 min each |
| `bats-tests` | Gate: coverage check + plugin validate (needs all shards) | 10 min |

### Shard assignment file

`.github/bats-shard-assignments.tsv` maps every top-level `.bats` file
to exactly one shard.  The CI `validate-shard-assignments` step fails
if any `.bats` file is not in the assignment.

### Adding a new .bats file

1. Create the file under `plugins/gaia/tests/`.
2. Add it to `.github/bats-shard-assignments.tsv` (pick the lightest
   shard, or run `.github/scripts/rebalance-shards.sh --dry-run`).
3. Register it in `plugins/gaia/tests/component-manifest.tsv` as usual.
4. Push.  The `validate-shard-assignments` step fails if you forget
   step 2; the component-manifest drift guard fails if you forget step 3.

### Rebalancing shards

When the balance drifts (one shard consistently slower than others),
regenerate assignments:

```bash
# From profiling data (after a CI run):
.github/scripts/rebalance-shards.sh --timing profiling/bats-timing.tsv

# From test counts (no profiling data needed):
.github/scripts/rebalance-shards.sh
```

### macOS bash 3.2 coverage

The macOS bash 3.2 job is a separate dimension, not
a shard of the Linux suite.  It runs a curated subset of
bash-3.2-sensitive tests on a macOS runner with the system `/bin/bash`
3.2 and BSD tools.  It is orthogonal to the 4 Linux shards.

## How to add new bats fixtures

1. **Reuse `test_helper.bash`.** Source it from every new `.bats` file
   (`load 'test_helper.bash'`) and use `common_setup` / `common_teardown`.
   That alone saves 50–100 ms per test by avoiding redundant `mktemp`
   and `mkdir -p` calls. Most importantly, never `cd` into the working
   tree — write everything under `$BATS_TEST_TMPDIR`.
2. **Prefer pure-shell assertions over subprocess calls.** Each
   `bash -c` or `git` invocation costs 5–20 ms. A `@test` that runs 10
   of them costs you 100 ms; 50 such tests cost 5 s. Use bash builtins
   (`[[ ... ]]`, `printf`, parameter expansion) where possible.
3. **Avoid `apt-get` and other network calls inside `@test` blocks.**
   Anything network-touching belongs in the workflow's `Install <foo>`
   step or behind a `skip "not in CI"` guard.
4. **Don't `sleep`.** A `sleep 1` in 30 tests is 30 s of pure dead
   time. If you need to test timing-sensitive logic, mock the clock or
   use a much smaller increment (`sleep 0.05`).
5. **Co-locate cluster tests under `tests/cluster-N/`** when the test
   targets a specific skill cluster. The cluster-{4,5,6,7,8,9} jobs
   pick those up directly and run them in their own 5-minute budget,
   keeping the main `bats-tests` job lean.

## When to escalate

Open a follow-on story when **any** of these fire:

- Any shard consistently exceeds 8 minutes (66% of the 12-minute
  timeout). Rebalance first; escalate if rebalancing does not help.
- The `bats-tests` critical path exceeds 10 minutes.
- A new shard (5th) is proposed. Consider whether the test count
  justifies the additional runner cost and queue-slot contention.

## Local repro

```bash
# Run a single shard locally:
SHARD=1
FILES=$(grep -v '^#' .github/bats-shard-assignments.tsv \
  | awk -F'\t' -v s="$SHARD" '$1==s {print "plugins/gaia/tests/" $2}')
bats --jobs 2 --no-parallelize-within-files $FILES

# Run the full suite with the coverage wrapper (same as pre-sharding):
bash plugins/gaia/tests/run-with-coverage.sh

# Run the public-function coverage check alone (static, no bats):
.github/scripts/check-public-function-coverage.sh .

# Validate shard assignments:
.github/scripts/validate-shard-assignments.sh .

# Rebalance shards from profiling data:
.github/scripts/rebalance-shards.sh --timing profiling/bats-timing.tsv
```

## Related artifacts

- The bats-scaling ADR memo under `.gaia/artifacts/planning-artifacts/`.
- `gaia-framework/.github/workflows/plugin-ci.yml` — the wired-in
  `bats-tests` job (lines around the "Run bats suite with coverage
  wrapper (budget-watched)" step).
- `plugins/gaia/scripts/bats-budget-watch.sh` — the wrapper script.
- `plugins/gaia/tests/e45-s6-bats-budget-watch.bats` — the unit /
  black-box suite for the wrapper.

## Cross-tree script-reference sweep linter

The plugin ships **two** bats trees, both exercised by CI:

- `tests/` (legacy) — cluster-4-e2e, cluster-5-parity,
  cluster-6-e2e, cluster-7-chain, cluster-8-sprint-cycle, and
  skills-bats-tests jobs.
- `plugins/gaia/tests/` (canonical, ~791 top-level .bats files) —
  `bats-shard-{1..4}` (sharded regression suite) and
  cluster-9-run-all-reviews.

The two trees are **disjoint** (zero filename or relative-path overlap),
hosting architecturally distinct surfaces (cluster parity / e2e vs
plugin-internal unit). Both are intentionally kept in place — the path
(a) consolidate vs (b) lint trade-off was weighed when the linter was added.

### Why the linter exists

When a script is deleted from `plugins/gaia/scripts/` or
`plugins/gaia/skills/*/scripts/`, an engineer can easily miss a stale
reference in the other tree. A prior finding surfaced this exact
gap: an update touched only `plugins/gaia/tests/` and missed two
references under `gaia-framework/tests/`. The sweep linter catches that
class of regression at PR time.

### What it checks

`plugins/gaia/scripts/lint-bats-script-refs.sh` walks every `.bats`
under `tests/` and `plugins/gaia/tests/`, extracts script references
matching `plugins/gaia/scripts/<name>.sh` and
`plugins/gaia/skills/<skill>/scripts/<name>.sh`, and verifies each one
resolves to an existing file at the repo root. Stale references print
one `STALE: <file>:<line> -> <path>` line to stdout and the linter
exits 1. The script:

- skips comment lines (`^\s*#...`).
- skips heredoc bodies (e.g., `cat > ... <<EOS ... EOS`) so fixture
  content embedded inside test setup does not produce false positives.
- skips matches preceded by `$VAR/` so shell-variable rooted paths
  (e.g., `$FIXTURE_ROOT/plugins/gaia/scripts/...`) do not register as
  canonical repo-root references.
- accepts `--ignore-pattern <regex>` (repeatable) for documented
  fixture cases that intentionally reference non-existent scripts.

### CI wiring

The `bats-script-refs-lint` job in `.github/workflows/plugin-ci.yml`
runs on every PR touching `plugins/gaia/**`. It is pure bash + awk
(no bats install, no apt install) and completes in well under a
second. Failure surfaces every stale reference at once so the author
can fix them all in one push.

### Local invocation

```bash
plugins/gaia/scripts/lint-bats-script-refs.sh --root .
# or with allowlist
plugins/gaia/scripts/lint-bats-script-refs.sh --root . \
  --ignore-pattern "intentional-fixture"
```

### Related artifacts

- `plugins/gaia/scripts/lint-bats-script-refs.sh` — the linter.
- `plugins/gaia/tests/lint-bats-script-refs.bats` — the bats suite.
- `gaia-framework/.github/workflows/plugin-ci.yml` — the
  `bats-script-refs-lint` job.

## Release pipeline — promote-PR merge strategy

The release workflow (`release.yml`) auto-opens a `release/vX.Y.Z` PR
when it detects a commit on `main` whose subject matches a Conventional
Commit type that classifies as `minor` or `major` (`feat:` or `fix:`).
Anything else — including `chore:`, `docs:`, and any non-conventional
subject — yields `bump_size=none` and **no release PR is opened**.

### Pitfall: squash-merging a `promote:` PR collapses the type

When a `staging → main` promote PR is squash-merged with title
`promote: staging → main (...) (#NNN)`, GitHub generates a single
commit whose subject is `promote: ...` and whose body is a bullet list
of the squashed `feat:` / `fix:` commits. The classifier reads only
the subject, sees `promote:` (not a recognized type), and skips. The
12 properly-typed `feat:` lines in the body are ignored.

### Two ways to avoid the trap

1. **Merge promote PRs with a default merge-commit, not squash.**
   `gh pr merge <pr> --merge` preserves the individual `feat:` /
   `fix:` commits — each contributes to the classifier range.

2. **If a squash already happened, push a follow-up `feat:` commit.**
   Either a no-op CHANGELOG note or a small doc touch with a
   `feat(scope): ...` subject will land on `main` via the standard
   promote flow and re-trigger the release workflow on next push.

### Related artifacts

- `.github/workflows/release.yml` — the workflow.
- `plugins/gaia/scripts/lib/resolve-release-anchor.sh` — BEFORE anchor
  resolution (most-recent `v*` tag).
- `plugins/gaia/scripts/classify-commits.js` — subject-line classifier.
