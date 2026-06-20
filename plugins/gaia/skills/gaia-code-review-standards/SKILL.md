---
name: gaia-code-review-standards
description: Universal review checklist, SOLID violation detection, cyclomatic and cognitive complexity thresholds, and the review-gate-completion hard gate enforced before a story moves to done. Shared dev skill JIT-loaded by dev-story, code-review, and stack dev agents.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Native Claude Code conversion of the legacy `_gaia/dev/skills/code-review-standards.md` skill. Preserves the four sectioned-loading IDs (`review-checklist`, `solid-principles`, `complexity-metrics`, `review-gate-completion`) verbatim. The `review-gate-completion` section documents the hard gate enforced by the `review-gate-check` protocol before a story transitions from `review` to `done`.

> **Applicable to:** all 9 stack dev agents (typescript, angular, flutter, java, python, mobile, go, bash, embedded) and the code-review skill. The legacy `applicable_agents` frontmatter field is dropped per the current schema.

<!-- SECTION: review-checklist -->
## Review Checklist

### Correctness
- [ ] Code does what the PR description claims
- [ ] Edge cases are handled (null, empty, boundary values)
- [ ] Error paths are handled gracefully (no swallowed exceptions)
- [ ] No off-by-one errors in loops or slicing
- [ ] Concurrent access is safe (if applicable)

### Security
- [ ] No secrets, credentials, or API keys in code
- [ ] User input is validated and sanitized
- [ ] SQL queries use parameterized statements
- [ ] Authentication and authorization are enforced
- [ ] Sensitive data is not logged

### Performance
- [ ] No N+1 query patterns
- [ ] No unnecessary re-renders in UI components
- [ ] Large collections use pagination
- [ ] Expensive operations are cached or deferred
- [ ] Database queries have appropriate indexes

### Maintainability
- [ ] Functions and methods are under 30 lines
- [ ] Classes have a single responsibility
- [ ] Variable and function names are descriptive
- [ ] No commented-out code
- [ ] No magic numbers (use named constants)
- [ ] DRY: no copy-pasted logic blocks

### Testing
- [ ] New code has corresponding tests
- [ ] Tests cover happy path and error cases
- [ ] Tests are independent and repeatable
- [ ] No test code in production builds
- [ ] Mocks are reset between tests

### Review Etiquette
- Comment on the code, not the person
- Suggest, do not demand: "Consider using X because..."
- Distinguish blocking issues from suggestions
- Approve with minor comments when appropriate
- Respond to reviews within one business day

<!-- SECTION: solid-principles -->
## SOLID Principles

### Single Responsibility (SRP)
A class should have only one reason to change.

**Violation signal**: Class has methods for unrelated concerns.
```typescript
// BAD: UserService handles auth, email, and data access
class UserService {
  authenticate(credentials) { ... }
  sendWelcomeEmail(user) { ... }
  saveToDatabase(user) { ... }
}

// GOOD: Separated responsibilities
class AuthService { authenticate(credentials) { ... } }
class EmailService { sendWelcome(user) { ... } }
class UserRepository { save(user) { ... } }
```

### Open/Closed (OCP)
Open for extension, closed for modification.

**Violation signal**: Adding a feature requires modifying existing switch/if chains.
```typescript
// BAD: Must modify function for each new type
function calculateArea(shape) {
  if (shape.type === 'circle') return Math.PI * shape.radius ** 2;
  if (shape.type === 'rect') return shape.width * shape.height;
  // Must add more conditions for new shapes
}

// GOOD: Extend via polymorphism
interface Shape { area(): number; }
class Circle implements Shape { area() { return Math.PI * this.radius ** 2; } }
class Rectangle implements Shape { area() { return this.width * this.height; } }
```

### Liskov Substitution (LSP)
Subtypes must be substitutable for their base types.

**Violation signal**: Subclass overrides a method to throw or do nothing.

### Interface Segregation (ISP)
No client should depend on methods it does not use.

**Violation signal**: Interface has many methods and implementations leave some as no-ops.

### Dependency Inversion (DIP)
Depend on abstractions, not concretions.

**Violation signal**: Classes instantiate their own dependencies with `new`.
```typescript
// BAD: Tightly coupled to concrete class
class OrderService {
  private repo = new PostgresOrderRepository();
}

// GOOD: Depend on abstraction, inject at construction
class OrderService {
  constructor(private repo: OrderRepository) {}
}
```

### Review Flags
When reviewing, flag SOLID violations with a prefix tag:
```
[SRP] This class handles both X and Y -- consider splitting.
[OCP] Adding new types requires modifying this switch -- consider strategy pattern.
[DIP] Direct dependency on concrete class -- inject via interface.
```

<!-- SECTION: complexity-metrics -->
## Complexity Metrics

### Cyclomatic Complexity
Measures the number of independent paths through a function.

**Calculation**: Count decision points + 1
- Each `if`, `else if`, `case`, `while`, `for`, `&&`, `||`, `catch` adds 1

| Score | Risk Level | Action |
|-------|------------|--------|
| 1-5 | Low | Acceptable |
| 6-10 | Moderate | Review for simplification |
| 11-20 | High | Refactor required |
| 21+ | Critical | Must be broken apart |

### Cognitive Complexity
Measures how hard code is to understand (more nuanced than cyclomatic).

Increases with:
- Nesting depth (penalty compounds with each level)
- Breaks in linear flow (else, catch, continue, break)
- Recursion

```typescript
// Cognitive complexity: 7 (nested conditions compound)
function getLabel(user, order) {       // +0
  if (user.isAdmin) {                  // +1
    if (order.isPriority) {            // +2 (nesting)
      return 'admin-priority';
    } else {                           // +1
      return 'admin-standard';
    }
  } else if (user.isVip) {            // +1
    return 'vip';
  } else {                            // +1
    if (order.total > 100) {           // +2 (nesting)
      return 'high-value';
    }
    return 'standard';
  }
}
```

### Refactoring High-Complexity Code
**Extract method**: Pull branches into well-named functions.
```typescript
// Before: one long function with nested conditions
function processOrder(order) {
  // 40 lines with nested if/else
}

// After: decomposed into focused functions
function processOrder(order) {
  const pricing = calculatePricing(order);
  const shipping = determineShipping(order);
  return finalizeOrder(order, pricing, shipping);
}
```

**Replace conditionals with polymorphism**: When branching on type, use strategy pattern.

**Use early returns**: Flatten nested conditions with guard clauses.
```typescript
// Before: deeply nested
function validate(input) {
  if (input) {
    if (input.name) {
      if (input.name.length > 0) {
        return true;
      }
    }
  }
  return false;
}

// After: guard clauses
function validate(input) {
  if (!input) return false;
  if (!input.name) return false;
  if (input.name.length === 0) return false;
  return true;
}
```

### Thresholds for Code Review
| Metric | Threshold | Action |
|--------|-----------|--------|
| Function length | > 30 lines | Suggest extraction |
| Cyclomatic complexity | > 10 | Require refactoring |
| Cognitive complexity | > 15 | Require refactoring |
| Parameter count | > 4 | Suggest object parameter |
| Nesting depth | > 3 levels | Require flattening |
| Class methods | > 10 public | Suggest decomposition |

<!-- SECTION: severity-rubric-format -->
## Severity Rubric Format

This section defines the canonical severity rubric format inherited by the six review skills (`gaia-code-review`, `gaia-security-review`, `gaia-qa-tests`, `gaia-test-automate`, `gaia-test-review`, `gaia-performance-review`). Each consumer skill provides per-domain examples that conform to the shape defined here.

> **Canonical cross-link string.** Each consumer SKILL.md places the verbatim cross-link sentence below immediately above its per-skill examples block:
>
> `> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.`
>
> The cross-link uses the canonical skill name (`gaia-code-review-standards`) and NEVER a relative path — the Skill resolver handles physical location.

### Tier shape (5 tiers)

The rubric has five tiers organized along two axes — severity (Critical / Warning / Suggestion) and category (correctness / readability). The Critical-readability tier is intentionally empty.

#### Critical-correctness

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block.

Examples:
- Off-by-one in a loop bound that produces incorrect output for the documented happy path.
- Null-deref on a code path with no guard, reachable via a documented public API entry point.
- Resource leak (file handle, DB connection, lock) on the error path with no `finally` / `defer` / `using`.

#### Critical-readability

<!-- WHY: the rubric deliberately mandates that readability never blocks. The maximum severity for any readability-class finding is Warning. A future maintainer adding a concrete example here would violate the architectural decision; bats `code-review-standards-rubric.bats` greps for the verbatim "None" string and fails CI on drift. -->

None — readability never blocks (max severity is Warning).

#### Warning-correctness

> Non-blocking but worth surfacing. Persisted to the report.

Examples:
- Edge case unhandled but documented as out-of-scope in the story or PR description.
- Logic that works on the happy path but relies on an undocumented invariant a future maintainer cannot verify.

#### Warning-readability

> Non-blocking but worth surfacing. Persisted to the report.

Examples:
- Function exceeds the team length / complexity threshold (>30 lines or cyclomatic >10).
- Misleading variable name that would surprise a future maintainer.
- Copy-pasted block that should be extracted into a shared helper (DRY violation).

#### Suggestion

> Non-blocking. Style / comment polish; no behavior implications.

Examples:
- Comment wording could be tightened, or a stale comment refers to renamed code.
- Naming could match team convention more closely.
- Opportunity for a parameter-object refactor to reduce a long argument list.

### Rubric-evolution impact-radius

Any change to the rubric tier shape (adding a tier, renaming a tier, changing the Critical-readability invariant) is a SHARED contract change with the following impact-radius:

1. The six review consumer SKILL.md files (`gaia-code-review`, `gaia-security-review`, `gaia-qa-tests`, `gaia-test-automate`, `gaia-test-review`, `gaia-performance-review`) — each must update its per-skill examples to match the new shape.
2. `evidence-judgment-parity.bats` MUST be re-run to confirm the canonical cross-link is present and the per-skill examples still conform.
3. Backward-compatibility check against existing review reports — old reports use the prior tier names; document the migration path before merging.
4. An architectural-decision amendment is required if the new shape diverges from the canonical rubric (e.g., introducing a Critical-readability tier).

### Scope boundary

This rubric format is the standard for the six current review skills. A future review skill (e.g., a hypothetical `gaia-accessibility-review` with a 4-tier Blocker / Major / Minor / Info shape) requires an explicit architectural-decision amendment and its own rubric section — divergence from this rubric is out of scope for the current six skills.

<!-- SECTION: review-gate-completion -->
## Review Gate Completion Requirements

Before a story transitions from `review` to `done`, all 6 individual review reports AND the consolidated review-summary.md must exist in the filesystem. This is a **hard gate** — it is enforced structurally by the `review-gate-check` protocol and is not advisory.

### Required Review Artifacts

| Artifact | Path | Required When |
|---|---|---|
| Code review | `.gaia/artifacts/implementation-artifacts/{story_key}-review.md` | Always |
| Security review | `.gaia/artifacts/implementation-artifacts/{story_key}-security-review.md` | Always |
| QA tests | `.gaia/artifacts/test-artifacts/{story_key}-qa-tests.md` | Always |
| Test automation | `.gaia/artifacts/test-artifacts/{story_key}-test-automation.md` | Always |
| Test review | `.gaia/artifacts/test-artifacts/{story_key}-test-review.md` | Always |
| Performance review | `.gaia/artifacts/implementation-artifacts/{story_key}-performance-review.md` | Always |
| **Review summary** | `.gaia/artifacts/implementation-artifacts/{story_key}-review-summary.md` | **Always — enforced hard gate** |

### Enforcement Mechanism (Live)

The hard gate is enforced by `plugins/gaia/scripts/review-gate.sh` (foundation script). Before invoking `status-sync` to move a story from `review` to `done`, the script:

1. Builds the summary file path `{implementation_artifacts}/{story_key}-review-summary.md`
2. Checks whether the file exists
3. If missing AND any of the 6 individual review reports exist → HALT with: `Review summary missing for {story_key}. Run /gaia-run-all-reviews {story_key} to generate the summary, or create it manually via /gaia-create-review-summary {story_key}.`
4. If missing AND all 6 individual review reports are also missing → skip the check (story never entered review)
5. If present → gate passes, transition proceeds

**This is a live hard gate, not a guidance note.** Stories with missing summaries physically cannot transition to `done` — the protocol will halt.

### Auto-Generation via run-all-reviews

`/gaia-run-all-reviews` auto-generates the review-summary.md as the final step of its 6-review pipeline (see `_gaia/lifecycle/workflows/4-implementation/run-all-reviews/instructions.xml` step 8). The summary aggregates the 6 review verdicts (read from the Review Gate table in the story file and from each review's report) — it does not re-run the reviews.

### Manual Generation

If auto-generation fails or is skipped, create the summary manually by copying the schema in `run-all-reviews/instructions.xml` step 8 and filling in the verdicts from the individual reports.

### Review Summary Schema

```yaml
---
story_key: {story_key}
date: {YYYY-MM-DD}
overall_status: PASSED | FAILED | INCOMPLETE
reviewers: [code-review, qa-tests, security-review, test-automate, test-review, review-perf]
---
```

Followed by 6 sections (one per review) with verdict + report link + one-line synopsis, then a final aggregate Gate Status table.

## Test Scenarios

Migrated from the legacy `test_scenarios` frontmatter array.

| Scenario | Expected |
|----------|----------|
| Review checklist application | All checklist items are evaluated and blocking issues are flagged |
| SOLID violation detection | Reviewer identifies specific SOLID principle violations with remediation suggestions |
| Complexity assessment | Functions exceeding complexity thresholds are flagged with refactoring recommendations |
