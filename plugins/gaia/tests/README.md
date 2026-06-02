# GAIA Plugin — bats-core Unit Test Suite (E28-S17)

This directory contains the bats-core unit test suite for every foundation
script in `plugins/gaia/scripts/`. It is the binding NFR-052 enforcement
point — 100% of documented public functions in every foundation script are
covered by at least one bats test.

## Running tests

The bats suite has two equivalent invocation paths. Either one runs the same
tests against the same scripts — pick whichever matches your environment.

### Canonical: `bun test:bats`

Story Definition-of-Done blocks across the project reference `bun test:bats`
as the canonical runner. Use this when `bun` is installed locally or when
the project's `package.json` defines a `test:bats` script.

```bash
# Full suite (canonical phrasing used by story DoD blocks)
bun test:bats
```

### Fallback: bare `bats <path>`

When `bun` is unavailable (laptop without bun, container image without
node tooling, transient install issue), invoke `bats` directly. This is the
exact same runner the canonical path wraps — no behavior difference.

```bash
# Full suite
bats plugins/gaia/tests/

# Single file
bats plugins/gaia/tests/resolve-config.bats

# With filter
BATS_TEST_FILTER="happy path" bats plugins/gaia/tests/resolve-config.bats
```

### CI vs local dev

- **CI** runs the canonical path (or its underlying equivalent). The
  `bats-tests` job in `.github/workflows/plugin-ci.yml` invokes
  `plugins/gaia/scripts/bats-budget-watch.sh`, which wraps the same `bats`
  binary the bare-bats fallback uses — so the assertions exercised on CI
  and locally are bit-for-bit identical regardless of which entry point a
  developer chose.
- **Local dev** may use either path. Bare `bats <path>` is fully acceptable
  when `bun` is not installed; no story DoD has ever required `bun` itself,
  only that the bats suite passes.

### Why story DoD blocks keep saying "bun test:bats"

Story DoD templates intentionally retain the canonical `bun test:bats`
phrasing rather than spelling out "bun test:bats or equivalent bats
invocation" on every line. The justification: the canonical name is short,
greppable across the corpus, and unambiguous about which test suite is
meant. The bare-`bats` fallback documented above is the authoritative
escape hatch when the canonical command is not runnable — story authors do
NOT need to rewrite DoD lines, and reviewers should treat a green bare-
`bats` run as satisfying any DoD line that says `bun test:bats`.

## Coverage wrapper

```bash
bash plugins/gaia/tests/run-with-coverage.sh
```

The wrapper:

1. Enumerates public functions from every `plugins/gaia/scripts/*.sh`.
2. Runs the bats suite.
3. Asserts every public function is referenced from at least one `.bats`
   file (the NFR-052 binding gate). Uncovered public functions fail the
   wrapper with exit 1 and are named in stderr.
4. If `kcov` is available on PATH, produces an advisory HTML + JSON line
   coverage report under `coverage/kcov/`. kcov is advisory only — the
   binding gate is public-function coverage.

Outputs:

- `coverage/public-functions.json` — enumerated public functions per script.
- `coverage/coverage-summary.json` — per-script covered / uncovered lists
  plus the NFR-052 gate verdict.
- `coverage/kcov/index.html` — advisory line coverage (if kcov is present).

## Test isolation rules

- Every `.bats` file sources `test_helper.bash` and calls `common_setup` /
  `common_teardown` to namespace a per-test temp dir under `$BATS_TMPDIR`.
- Tests never write to the working tree or any shared global path.
- `LC_ALL=C` and `TZ=UTC` are pinned for deterministic output.
- Fixtures are generated inside `setup()` — never checked in as binary
  blobs that could drift silently.

## CI integration

The `bats-tests` job in `.github/workflows/plugin-ci.yml` runs
`plugins/gaia/tests/run-with-coverage.sh`, enforces the 2-minute budget via
a job-level `timeout-minutes: 2`, uploads the `coverage/` directory as an
artifact, and fails the PR if the NFR-052 gate is not green.

## `@hardware-dependent` tag convention (E91-S1, FR-SRF-1, AF-2026-05-14-9)

Tests that exercise host-specific timing primitives (mtime resolution,
sleep precision, host-clock semantics) MUST be tagged
`@hardware-dependent`. They are **excluded from CI by default** via
`BATS_FILTER_TAGS='!hardware-dependent'` to keep the CI bats budget under
the hard cap (sprint-43 retrospective AI-2026-05-13-14 found that
hardware-dependent test flake was the primary contributor to budget
overrun).

**Tag a test file** (file-level — applies to every `@test` in the file):

```bats
#!/usr/bin/env bats
# bats file_tags=hardware-dependent
```

**Tag a single test** (test-level):

```bats
# bats test_tags=hardware-dependent
@test "my flaky test" { ... }
```

**Run locally before merge** with:

```bash
# Run only hardware-dependent tests
bats --filter-tags hardware-dependent gaia-framework/plugins/gaia/tests/

# Run a specific tagged file
bats --filter-tags hardware-dependent gaia-framework/plugins/gaia/tests/drift-detection-ci-suppression.bats

# Run via the coverage wrapper with tag opt-in
BATS_FILTER_TAGS=hardware-dependent bash gaia-framework/plugins/gaia/tests/run-with-coverage.sh
```

Developers MUST run the hardware-dependent subset locally before merging
any PR that touches code paths the tagged tests cover. The default-skip
preserves coverage (tests still exist + can be run) while keeping CI lean.

### Current `@hardware-dependent` tag inventory

- `drift-detection-ci-suppression.bats` — exercises CI environment variable detection (CI=true, non-TTY) which can vary across shell environments.

(This inventory is updated as new tests are tagged.)
