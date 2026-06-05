# CI Notes — bats Wall-Clock Budget

> **Why this file exists.** The `bats-tests` job in `plugin-ci.yml` is the
> framework's primary integration gate. Wall-clock has crept from ~150 s
> (sprint-23, ~1300 tests) to ~270 s (sprint-28, 2085 tests) — see
> the bats-scaling memo under `.gaia/artifacts/planning-artifacts/` for the full
> trajectory. This runbook tells contributors how to add new tests
> without pushing the suite into another timeout escalation.

## TL;DR

- **Soft budget:** 240 s (4 min) of bats wall-clock, watched by
  `plugins/gaia/scripts/bats-budget-watch.sh`.
- **Hard budget:** 300 s (5 min) `timeout-minutes` on the `bats-tests` job.
- **Escalation triggers:** see the bats-scaling ADR Appendix B.

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

## How to interpret the budget warning

When the bats-tests step runs longer than 240 s, the GitHub Actions step
summary will include a yellow warning block:

```
> [!WARNING]
> bats budget exceeded — bats-tests
>
> - threshold: 240s
> - elapsed: 248s
> - over by: 8s
>
> The bats CI step is approaching its wall-clock budget. ...
```

This is **advisory only** — the build still passes. It means:

- If your PR added new tests: consider whether the additions truly
  belong in the foundation suite or whether they should live under a
  cluster-specific path with its own job.
- If your PR didn't add tests: the warning is a leading indicator that
  the suite is drifting toward the hard wall. Flag in the PR
  description so the next planner sees it.

## When to escalate

Open a sprint-29-or-later story (or extend the bats-scaling ADR) when **any** of
these fire:

- The warning posts on >25 % of staging-bound PRs in a sprint.
- A single PR's bats wall-clock exceeds 270 s (90 % of the hard wall).
- A second `timeout-minutes` escalation is proposed in any PR review.

The likely next step is parallelisation via `bats --jobs N` — see
the bats-scaling ADR Option A. Don't bump `timeout-minutes` past 5 minutes
without first running the parallelisation prototype.

## Local repro

```bash
# Run the budget-watched bats suite locally — same wrapper as CI.
bash plugins/gaia/scripts/bats-budget-watch.sh \
  --threshold-seconds 240 \
  --label bats-tests \
  -- bash plugins/gaia/tests/run-with-coverage.sh
```

If your local box is slow, drop `--threshold-seconds` to a value that
matches your hardware so you see the warning during development rather
than on the PR.

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

- `tests/` (legacy, 104 .bats files) — cluster-4-e2e, cluster-5-parity,
  cluster-6-e2e, cluster-7-chain, cluster-8-sprint-cycle, and
  skills-bats-tests jobs.
- `plugins/gaia/tests/` (canonical, 194 .bats files) — `bats-tests`
  (full suite via `run-with-coverage.sh`) and cluster-9-run-all-reviews.

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
