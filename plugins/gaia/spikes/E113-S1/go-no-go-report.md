# Go / No-Go Report: Selective Test Execution

Spike: E113-S1
Date: 2026-06-17

---

## Executive Summary

**PROCEED**

The algorithm is sound and correct where stacks are covered. A single coverage
gap (`config/` subdir missing from the glob list) causes a file-level false
negative in PR #1545, but because other files in the same PR are covered the
stack-level detection result is still correct for all three measured PRs. The
gap is a one-line config fix deferred to S2. Measured CI savings are 0% in this
single-stack repo (every PR hits the one stack), but the algorithm is designed
for multi-stack savings and the projection is compelling. Recommend PROCEED with
S2 immediately adding the `config/**` glob as a prerequisite gate before
production use.

---

## Methodology

1. Extracted changed-file lists for three recent PRs using
   `git diff --name-only <sha>^ <sha>` from the `gaia-public` root.

2. Built `detect-affected.sh` — a POSIX-awk + bash prototype that parses
   `stacks[].name` and `stacks[].paths` from project-config.yaml, normalizes
   each glob (strips `gaia-public/` prefix and trailing `/**`), and does a
   prefix match against each changed path.

3. Ran the prototype against all three PR fixture files; manually verified
   each changed path against the stacks table.

4. Counted false positives and false negatives at both file level and
   stack-detection level.

TDD discipline: 5 bats tests written first (all RED), then `detect-affected.sh`
written to pass them (all GREEN). Tests remain green after refactor pass.

---

## Ground-Truth Summary

| PR | Files changed | FP (file) | FN (file) | FN (stack-level) | Stack detected | Correct? |
|----|:---:|:---:|:---:|:---:|:---:|:---:|
| #1548 | 14 | 0 | 0 | 0 | gaia-plugin | YES |
| #1547 | 10 | 0 | 0 | 0 | gaia-plugin | YES |
| #1545 | 24 | 0 | 1 | 0 | gaia-plugin | YES* |

\* PR #1545: `plugins/gaia/config/project-config.schema.yaml` is unclassified at
file level (false negative), but the stack-level verdict is correct because 23
other files in the same PR are covered. In a PR that ONLY changed `config/` the
stack-level result would also be wrong.

**Total across all PRs:** 48 files, 0 false positives, 1 file-level false
negative, 0 stack-level false negatives.

---

## Cross-Stack Accuracy

### Coverage analysis

- 47 of 48 changed files are correctly classified (97.9% file-level accuracy).
- 3 of 3 PRs receive the correct stack-level verdict (100% stack-level accuracy).
- The single false-negative file (`plugins/gaia/config/project-config.schema.yaml`)
  is caused by a missing glob in the config, not by an algorithmic defect.

### Does zero-FN hold?

At the **stack-detection level**: YES for all three measured PRs.

At the **file-level** (stricter): NO. PR #1545 has one uncovered file. In a
hypothetical PR touching only `config/` files, the stack-level result would
also be a false negative.

### Threshold assessment

The requirement is 95% accuracy with zero-FN tolerance.

- File-level accuracy: 97.9% — above the 95% threshold.
- Stack-level FN rate: 0/3 — within zero-FN tolerance for measured PRs.
- Latent risk: a `config/`-only PR would violate zero-FN. Fix is trivial.

---

## CI Savings

### Measured (single-stack, empirical)

In this single-stack repo every PR touches the one stack (`gaia-plugin`).
Selective execution cannot skip any tests.

**Measured savings: 0%**

Expressed as a p50 (median) CI-savings figure across the 3 measured PRs: 0% — every PR touches the single stack, so no test jobs are skipped. The multi-stack projection below is the relevant p50 proxy once a second stack is configured.

This is expected and does not indicate an algorithmic problem. Selective
execution is a multi-stack optimization. The savings are not visible in a
single-stack repo by construction.

### Multi-stack projection (extrapolation, not measured)

For a repo with N stacks where each PR typically touches 1 stack:

| Stacks (N) | Projected skip rate | Label |
|:---:|:---:|:---|
| 2 | (N-1)/N = 50% | extrapolation |
| 3 | 67% | extrapolation |
| 5 | 80% | extrapolation |
| 10 | 90% | extrapolation |

**These are model projections only.** They assume uniform PR-to-stack
distribution. Actual savings in a multi-stack repo would require empirical
measurement in S2.

---

## Recommendation and Rationale

**PROCEED**

The algorithm is well-specified, correctly implemented, and passes 5/5 bats
tests plus manual verification on 3 real PRs. The only defect found is a
missing config glob in project-config.yaml — a 1-line change that is trivially
fixable in S2 and does not reflect any flaw in the approach. Stack-level
accuracy is 100% across all measured PRs. The 0% measured savings figure is a
property of the single-stack test environment, not of the algorithm; the
projection for multi-stack repos is strong. The recommendation to PROCEED is
conditional on S2 adding the `config/**` glob before this logic is used in any
production gate — without it, a `config/`-only PR would silently skip all tests.

---

## Evidence Table

| Artifact | Path |
|---|---|
| Prototype script | `spikes/E113-S1/detect-affected.sh` |
| Test suite | `tests/spikes/E113-S1/detect-affected.bats` |
| PR #1548 fixture | `spikes/E113-S1/fixtures/pr-1548-files.txt` |
| PR #1547 fixture | `spikes/E113-S1/fixtures/pr-1547-files.txt` |
| PR #1545 fixture | `spikes/E113-S1/fixtures/pr-1545-files.txt` |
| PR #1548 affected set | `spikes/E113-S1/pr-1548-affected-set.json` |
| PR #1547 affected set | `spikes/E113-S1/pr-1547-affected-set.json` |
| PR #1545 affected set | `spikes/E113-S1/pr-1545-affected-set.json` |
| Ground truth table | `spikes/E113-S1/ground-truth.md` |

---

## S2 Prerequisites

Before this prototype is used in a production CI gate, S2 must:

1. **Add `config/**` glob** — add `"gaia-public/plugins/gaia/config/**"` to
   `stacks[gaia-plugin].paths` in project-config.yaml. Without this, any PR
   that only modifies `config/` files is silently unclassified (stack-level FN).

2. **Synthetic 2-stack fixture** — create a synthetic project-config.yaml with
   two stacks and a test PR touching only one stack. This validates that
   savings are real and that no cross-stack leakage occurs.

3. **CI integration contract** — define how `detect-affected.sh` output feeds
   into `bats --filter-tags` or equivalent test runner filtering. The prototype
   outputs stack names as a JSON array; the integration layer is not built.

4. **Edge-case hardening** — test empty changed-file list, malformed YAML
   (graceful exit 0), and PRs spanning multiple stacks.
