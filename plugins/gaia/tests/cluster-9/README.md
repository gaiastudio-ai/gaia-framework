# Cluster 9 — Run-All-Reviews Integration Tests

End-to-end integration tests for `gaia-run-all-reviews` (E28-S73).

## Fixture Layout

```
cluster-9/
  run-all-reviews.bats          # Main bats test suite
  test_helper.bash              # Cluster-9-specific test helper
  README.md                     # This file
  fixtures/
    C9-FIXTURE-fake.md          # Deterministic fixture story (status: review)
    expected/
      review-gate-all-pass.md   # Expected Review Gate table — all 6 PASSED
      review-gate-security-failed.md  # Expected — security FAILED, 5 PASSED
    shims/                      # Reserved for reviewer shims (if needed)
```

## Canonical Vocabulary Invariant

The Review Gate table Status column MUST contain only one of three values:

- `PASSED` — review passed
- `FAILED` — review failed
- `UNVERIFIED` — review not yet run

No other strings are permitted. The tests validate this invariant by parsing
every Status cell and failing hard on any non-canonical value.

## How to Run

```bash
# From the gaia-public/ root:
bats plugins/gaia/tests/cluster-9/run-all-reviews.bats
```

## Regenerating Expected Snapshots

1. Edit the fixture story `fixtures/C9-FIXTURE-fake.md` if needed
2. Run the all-pass scenario manually and capture the Review Gate table
3. Copy the Review Gate section to `fixtures/expected/review-gate-all-pass.md`
4. For the negative path, force security-review to FAILED and capture similarly

The expected files contain only the normalized Review Gate table rows.

## CI Integration

The `cluster-9-run-all-reviews` job in `.github/workflows/plugin-ci.yml` runs
this test on PRs touching:
- `plugins/gaia/skills/gaia-code-review/**`
- `plugins/gaia/skills/gaia-qa-tests/**`
- `plugins/gaia/skills/gaia-security-review/**`
- `plugins/gaia/skills/gaia-test-automate/**`
- `plugins/gaia/skills/gaia-test-review/**`
- `plugins/gaia/skills/gaia-review-perf/**`
- `plugins/gaia/skills/gaia-run-all-reviews/**`
- `plugins/gaia/scripts/review-runner.sh`
- `plugins/gaia/scripts/review-gate.sh`
- `plugins/gaia/tests/cluster-9/**`

The job is time-boxed at 10 minutes per AC4.
