# Advisory-to-Gating Promotion Procedure

## Overview

The manual-test review gate starts in **advisory** mode. When the team's manual-test results stabilize (low flakiness), the gate can be promoted to **gating** mode so a FAILED verdict blocks the review-to-done transition.

## Promotion Criteria

Promotion is eligible when **all three** conditions hold:

1. **Three consecutive closed sprints** exist in the sprint archive.
2. The **aggregate verdict-flip rate** across those sprints is below the threshold (default: 10%).
3. The team has reviewed the data in a retrospective and **decided** to promote.

The flip rate is the ratio of verdict transitions (a run whose verdict differs from the preceding run for the same story) to total runs, expressed as a percentage. A flip rate of 0% means every story's manual-test verdict was consistent across all runs.

## How to Check

Run the flakiness analyzer:

```bash
bash plugins/gaia/scripts/manual-test-flakiness.sh --check-promotion
```

- **Exit 0** — flip rate is below the threshold across 3 consecutive closed sprints; promotion is eligible.
- **Exit 1** — insufficient data, or flip rate exceeds the threshold.

An optional `--threshold <N>` flag overrides the default 10%.

## How to Promote

Promotion is a **configuration change**, not a code change. In `project-config.yaml`:

```yaml
review_gate:
  manual_test_mode: gating
```

This changes the behavior of the `review -> done` transition:

| Mode     | FAILED manual-test verdict | Effect                              |
|----------|----------------------------|-------------------------------------|
| advisory | WARNING emitted to stderr  | Transition proceeds (non-blocking)  |
| gating   | Transition refused (exit 8)| Story stays in `review`             |

## Revert Path

To revert from gating back to advisory:

```yaml
review_gate:
  manual_test_mode: advisory
```

Or remove the `manual_test_mode` key entirely (the default is `advisory`).

## Decision Record

The promotion or reversion decision should be recorded in the sprint retrospective action items. The flakiness data at the time of the decision should be cited as evidence.

## Verdicts TSV

The persistent data file is `.gaia/state/manual-test-verdicts.tsv` with columns:

| Column    | Description                                    |
|-----------|------------------------------------------------|
| story_key | The story key                                  |
| run_id    | Unique run identifier from the test execution  |
| verdict   | PASSED, FAILED, or UNVERIFIED                  |
| timestamp | ISO 8601 UTC timestamp of the run              |

Rows are append-only. The finalize script appends one row per manual-test execution.
