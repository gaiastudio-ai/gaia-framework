# E2E Quality Rubric — `/gaia-test-e2e` Phase 3B

> JIT-loaded by Phase 3B LLM judgment. Categories and severity tiers conform
> to ADR-075 (LLM-cannot-override invariant). The LLM applies this rubric on
> top of the deterministic Phase 3A `analysis-results.json` artifact — it
> CANNOT override an `errored` toolkit check by promoting an APPROVE.

## Categories

E2E findings are organized into four orthogonal categories:

1. **Stability** — flakiness, retry loops, timing dependencies, race conditions in selectors or assertions.
2. **Coverage** — critical user-journey path coverage (login, checkout, primary CRUD), happy-path-only suites that omit error states.
3. **Root-cause classification** — when failures occur, can they be attributed to application code, test infrastructure, or target environment?
4. **Selector resilience** — text-match fragility, hard-coded array indices, deep CSS chains, accessibility-name vs role-based selectors.

## Severity Tiers

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block. Critical promotion is restricted to high-confidence regressions with deterministic evidence.

Examples:
- **Flaky critical-path test** — checkout flow test fails 3 of 10 retries in CI history (`analysis-results.json` shows retry count > threshold).
- **Hard-coded sleep > 5s** in a critical-path test — masks a race condition that will surface in production environments.
- **No coverage for primary auth flow** — login/logout or session expiry has zero corresponding e2e tests.

### High

> Blocking unless justified. Verdict resolver weight: HIGH. The LLM may classify a finding as High only when reproducible across runs.

Examples:
- **Selector by deeply nested CSS chain** — `.outer .inner .child:nth-of-type(3)` instead of role + accessible-name. One DOM refactor breaks the test.
- **Test asserts only HTTP status** — passes without verifying rendered UI state for a UI-driven flow.
- **Conditional `if (browser === 'chrome') { ... }` branches in a test** — different assertions per browser hide regressions.

### Medium

> Non-blocking. Recorded in the report; does not flip the verdict on its own.

Examples:
- **Hard-coded test data** that overlaps with seeded fixtures — risks order dependence.
- **Test names that don't reflect the assertion** — `it('works')` instead of `it('logs in with valid credentials and lands on dashboard')`.
- **Long test bodies > 100 lines** — should be decomposed into helper functions.

### Suggestion

> Advisory. Educational; does not affect the verdict.

Examples:
- Adopt `page.getByRole(...)` (Playwright) / `cy.findByRole(...)` (Cypress) over `page.locator('css selector')`.
- Consider visual regression snapshots for stable layouts.
- Tag tests with `@smoke` or `@regression` for staged CI gates.

## LLM-cannot-override Invariant

A deterministic Phase 3A finding (e.g., adapter `status: errored` because Playwright crashed; or `status: errored` because the probe returned `expected_and_missing`) wins over any LLM APPROVE judgment. The rubric tiers above apply to LLM tier classification — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` or `status: errored`.
