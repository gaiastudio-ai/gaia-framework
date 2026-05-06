# A11y Quality Rubric — `/gaia-test-a11y` Phase 3B

> JIT-loaded by Phase 3B LLM judgment. Categories and severity tiers conform
> to ADR-075 (LLM-cannot-override invariant). The LLM applies this rubric on
> top of the deterministic Phase 3A `analysis-results.json` artifact — it
> CANNOT override an `errored` toolkit check or a deterministic Critical-tier
> WCAG violation surfaced by the adapter.

## Shared rubric contract (E69-S2)

This rubric is byte-identical to the one consumed by `/gaia-review-a11y`
(pre-merge) and `/gaia-validate-design-a11y` (planning). The base layer lives
at `plugins/gaia/rubrics/base/a11y.json` and is loaded via
`rubric-loader.sh --skill a11y`. WCAG-level escalation is layered on top:

| Configured level | Layers loaded                                                        |
|------------------|----------------------------------------------------------------------|
| A                | base                                                                  |
| AA (default)     | base + `rubrics/regimes/wcag-2.1-aa.json`                            |
| AAA              | base + `rubrics/regimes/wcag-2.1-aa.json` + `wcag-2.1-aaa.json`      |

A finding flagged Critical at the design phase is Critical at the pre-merge
review and Critical at the post-deploy smoke. If the same rule ID is given
different severities by two phases, the divergence is itself a CRITICAL
finding for this skill.

## Categories

A11y findings are organized into five orthogonal categories (matching the
base rubric):

1. **a11y.semantic-html** — non-semantic interactive elements, broken heading
   hierarchy, unlabeled form controls.
2. **a11y.aria-usage** — ARIA roles without matching keyboard contracts,
   conflicting native + ARIA roles, missing live regions for async updates.
3. **a11y.keyboard-navigation** — non-focusable interactive controls, broken
   focus traps, missing visible focus indicators.
4. **a11y.color-contrast** — body text below 4.5:1, UI components below 3:1,
   colour-only meaning.
5. **a11y.screen-reader-support** — missing alt text, missing skip-links,
   no landmark structure.

## Severity Tiers

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not
> already block. Critical promotion is restricted to deterministic Level-A
> failures or the equivalent of an unrecoverable assistive-tech break.

Examples:
- **Keyboard-only user blocked from interactive control** — WCAG 2.1.1 Level A failure detected by axe-core (`region` or `keyboard` rule).
- **Modal lacks focus trap** — WCAG 2.1.2 Level A failure detected by Lighthouse `focus-traps` audit.
- **Body-text contrast < 4.5:1** — WCAG 1.4.3 Level AA detected by axe-core `color-contrast` rule.
- **UI-component contrast < 3:1** — WCAG 1.4.11 Level AA non-text contrast.

### High

> Blocking unless justified. Verdict resolver weight: HIGH. The LLM may
> classify a finding as High only when reproducible across runs and the WCAG
> criterion is Level A or AA.

Examples:
- **Missing visible focus indicator** — WCAG 2.4.7 Level AA — sighted keyboard users cannot tell which control will receive their next keystroke.
- **Missing alt text on meaningful image** — WCAG 1.1.1 Level A.
- **Form input without label** — WCAG 3.3.2 / 1.3.1 Level A.
- **Custom widget with ARIA role but no keyboard contract** — WAI-ARIA Authoring Practices.

### Medium

> Non-blocking single-finding; aggregated repeat occurrences may escalate
> via the resolver's accumulator. Targets advisories that materially degrade
> assistive-tech experience without an outright failure.

Examples:
- **Heading-level skip** — WCAG 1.3.1 / 2.4.6.
- **Missing skip-link** — WCAG 2.4.1 Level A but treated as Medium when navigation is short.
- **Missing live region for form errors** — WCAG 4.1.3 Level AA Status Messages.

### Suggestion

> Advisory only. Suggestion findings never escalate the verdict. Includes
> Lighthouse "manual checks" advisories and pa11y notice-level entries.

## How the LLM consumes the rubric

1. Read the deterministic `analysis-results.json` from Phase 3A.
2. For each adapter finding, look up the matching rule in the loaded rubric
   layer (base + regimes) by `wcag_criterion` and `category`.
3. Adopt the rubric severity verbatim — do NOT downgrade. Promotion to a
   higher tier is permitted only when the finding's evidence (selector,
   message, repeat count) materially increases the impact (rare).
4. When a finding has no rubric match, classify by category and emit a
   Medium-tier finding with a note flagging the rubric gap.
5. Surface no-findings explicitly: emit a single `info` finding "no
   actionable a11y violations" so the verdict resolver records evidence of
   review rather than absence of evidence.

## Cross-reference

- `plugins/gaia/rubrics/base/a11y.json` — Layer 1 (E68-S3, ADR-079).
- `plugins/gaia/rubrics/regimes/wcag-2.1-aa.json` — AA regime layer.
- `plugins/gaia/rubrics/regimes/wcag-2.1-aaa.json` — AAA regime layer.
- `plugins/gaia/skills/gaia-review-a11y/SKILL.md` — pre-merge sibling.
- ADR-079 — Layered rubric loading.
- E69-S2 — three-phase a11y reorganization.
