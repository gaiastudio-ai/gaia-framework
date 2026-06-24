# gaia-add-feature tests

This directory holds bats tests, fixtures, and the historical-file allowlist
for the `/gaia-add-feature` Val-gate fail-closed enforcement layer.

## `assessment-doc-bypass-check.bats`

CI-wired anti-pattern check that scans every `/gaia-add-feature` assessment-doc
emission for three Val-gate bypass smoking-gun strings. Authored to close the
root-cause precedent from the bypass rollback assessment: the
`/gaia-add-feature` skill historically self-licensed two distinct Val-gate
bypasses that the assessment-doc audit trail recorded verbatim. The bats check
turns that prose evidence into a structural CI gate — any future bypass attempt
fails the build at PR time, not at audit-after-the-fact time.

### The three smoking-gun strings

1. **Literal — `auto-judged in patch mode`** (patch-mode bypass pattern)
   Skill self-licensed an undocumented patch-mode shortcut and recorded the
   self-judgment as a `PASS` verdict. Catching this string fails the build on
   the rationalization itself — even when the underlying patch is correct.

2. **Literal — `inline, read-only verification`** (inline-verification bypass pattern)
   Skill performed Val "inline" inside its own context instead of dispatching
   Val as a forked subagent per the forked-validation-context architecture
   decision. Inline Val erases the second-pair-of-eyes guarantee.

3. **Regex — `Agent.{0,2}tool subagent dispatch primitive not surfaced`** (dispatch rationalization)
   Skill claimed the Agent-tool dispatch primitive was unavailable, then
   defaulted to inline-Val. The `.{0,2}` is **load-bearing**: three of four
   historical occurrences of this string are backtick variants
   (`` `Agent`-tool subagent dispatch primitive not surfaced ``); a literal
   grep for the plain-text form would miss them and the bats check would be
   75% dead on day one.

### Convention for new assessment docs

Assessment docs that need to discuss the bypass patterns for documentation /
historical purposes MUST paraphrase the strings rather than quote them
verbatim. Suggested paraphrases:

| Smoking-gun string | Paraphrase |
|--------------------|------------|
| `auto-judged in patch mode` | the patch-mode-auto-judgment pattern |
| `inline, read-only verification` | the inline-read-only-verification pattern |
| `Agent-tool subagent dispatch primitive not surfaced` | the agent-tool-not-surfaced rationalization |

The convention was introduced in the bypass rollback assessment (root-cause
meeting on the original bypass action item) and applied to that assessment's
§Audit Trail section during the inline SM fix that resolved Val F1 from
this story's first validation pass.

### Historical-file allowlist

The live corpus at project-root `.gaia/artifacts/planning-artifacts/assessment-AF-*.md`
contains 10 historical (pattern, file, line) tuples spread across 5 files
that pre-date this convention:

| File | Hits | Allowlisted? |
|------|------|--------------|
| (historical assessment 1) | 1 | yes |
| (historical assessment 2) | 2 | yes |
| (historical assessment 3) | 4 | yes |
| (canonical bypass assessment A) | 1 | **no** (canonical bypass evidence) |
| (canonical bypass assessment B) | 2 (one line carries strings 2 + 3) | **no** (canonical bypass evidence) |

The allowlist (`assessment-doc-bypass-allowlist.txt`) skips the three
historical pre-convention files. The two canonical bypass assessments are the
evidence the check is designed to catch — under the allowlist, the scanner
reports exactly **3 (pattern, file, line) tuples** (string 1 in assessment A,
strings 2 and 3 sharing a single line in assessment B — they report as two
separate violation tuples to preserve diagnostic clarity).

The allowlist is INTENDED to shrink over time. New entries require explicit
reviewer approval and a `# REASON:` comment explaining why the historical
context cannot be paraphrased.

### Running locally

```sh
# Run the bats suite (skips live-corpus tests when GAIA_PROJECT_ROOT_DOCS
# is unset).
bats plugins/gaia/skills/gaia-add-feature/tests/assessment-doc-bypass-check.bats

# Run the bats suite against the live project-root corpus.
GAIA_PROJECT_ROOT_DOCS=/path/to/project-root/docs \
  bats plugins/gaia/skills/gaia-add-feature/tests/assessment-doc-bypass-check.bats

# Run the scanner directly (validation mode — disables the allowlist):
plugins/gaia/skills/gaia-add-feature/scripts/assessment-doc-bypass-check.sh \
  --no-allowlist \
  /path/to/project-root/.gaia/artifacts/planning-artifacts/assessment-AF-*.md
```

### Output format

```
{file}:{line}:{matched-string}
```

The first two fields match GNU `grep -n` so editors with grep-result
navigation work natively. The third field is the canonical plain-text form
of the smoking-gun string (string 3 normalizes backtick / hyphen variants).

### Reference

- Root-cause meeting: (internal planning artifact — bypass root-cause meeting)
- Rollback assessment: (internal planning artifact — bypass rollback assessment)
- Action item: (internal planning artifact — the bypass action item)
- Epic: fail-closed enforcement of `/gaia-add-feature` Val gate
