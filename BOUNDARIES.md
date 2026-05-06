# BOUNDARIES.md

> **Scope-edges index for the GAIA Review System v2.** Single canonical reference
> for resolving classification ambiguities (review vs action, gate phase, rubric
> precedence, adapter availability, agent type, verdict vocabulary). This is an
> index, not a duplicate of the canonical ADRs — every section cross-references
> the source of truth. Story: `E75-S1`. Sources: ADR-077, ADR-078, ADR-079,
> ADR-080, ADR-081, ADR-082, source report
> `docs/planning-artifacts/decisions/gaia-review-system-final-report.md`.

---

## Review Skills vs Action Skills

> **Source:** ADR-077 (Three-Tier Review Pipeline) §Decision wiring table; source
> report §1.5 (Action skills vs review skills). The two families share the
> seven-phase pipeline contract but differ on side effects, plan-then-execute
> machinery (ADR-051), and inclusion in `/gaia-review-all`.

**Six review skills (verdict-producing, read-only, included in `/gaia-review-all`):**

| # | Skill | Trigger | Owner agent (ADR-077 wiring) |
|---|---|---|---|
| 1 | `/gaia-review-code` | Always | stack-specific reviewer (ts-dev, java-dev, python-dev, go-dev, flutter-dev, mobile-dev, angular-dev) |
| 2 | `/gaia-review-qa` | Always | Vera |
| 3 | `/gaia-review-test` | Always | Sable |
| 4 | `/gaia-review-security` | Always | Zara |
| 5 | `/gaia-review-perf` | Always (light → full escalation) | Juno |
| 6 | `/gaia-review-mobile` | Conditional on `platforms[]` declared in `project-config.yaml` | Talia |

`/gaia-review-a11y` is included via the conditional gate when `compliance.ui_present: true`
(ADR-082 §Decision); it shares Christy as owner agent and follows the same
six-skill review-pipeline contract. ADR-082 enumerates seven possible gates
(the six above plus `/gaia-review-a11y`); the canonical "six" subset listed here
matches the FR-DEJ-12 review-skill template inheritance set referenced by
ADR-075 / ADR-077.

**Five action skills (verdict-producing, write-capable, NOT included in `/gaia-review-all`):**

| # | Skill | Phase | Owner agent (ADR-077 wiring) |
|---|---|---|---|
| 1 | `/gaia-test-e2e` | Deployment-phase (pre-release / staging) | Sable |
| 2 | `/gaia-test-perf` | Deployment-phase (pre-release / staging) | Sable |
| 3 | `/gaia-test-dast` | Deployment-phase (pre-release / staging) | Sable |
| 4 | `/gaia-test-a11y` | Deployment-phase (post-deploy smoke) | Sable |
| 5 | `/gaia-deploy` | Deployment orchestrator (Pattern A, Claude-driven) | Soren |

Action-skill differentiators (source report §1.5):

| Aspect | Review skills | Action skills |
|---|---|---|
| Side effects | Read-only | Write code, run tests, deploy |
| Verdict | `APPROVE` / `REQUEST_CHANGES` / `BLOCKED` | Same vocabulary, plus execution success + coverage delta |
| Inclusion in `/gaia-review-all` | Yes (mandatory or conditional) | No — triggered explicitly |
| Plan-then-execute machinery (ADR-051) | No | Yes |
| Path allowlist | No | Yes |

Two additional action skills exist outside this five — `/gaia-test-automate` and
`/gaia-test-run` — but they are **not deployment-phase action skills**;
`/gaia-test-automate` is the canonical action skill that mutates the test suite,
`/gaia-test-run` is a manual any-env runner. They are listed under the broader
"action skills" family in the source report §3.2 but are out of scope for the
five deployment-phase action skills enumerated in PRD §4.38 prelude. The mobile
deployment-phase skills `/gaia-test-mobile-e2e` and `/gaia-test-device-matrix`
(ADR-081) are mobile-platform extensions of the same action-skill pattern;
they are not counted in the canonical five but inherit the contract.

---

## Gate Phases

> **Source:** ADR-080 (Deployment-Phase Pattern), ADR-082 (Composite Review
> Verdict GATING), source report §3.4 + §15 Phase 8. Pre-merge gates run
> against the source tree; deployment-phase gates run against a deployed
> environment URL or device target.

| Phase | Trigger condition | Responsible agent(s) | Output artifact type |
|---|---|---|---|
| **Planning** | `/gaia-validate-design-a11y` invoked at end of UX design phase, before story creation; also `/gaia-validate-rubric` and `/gaia-config-validate` for setup-time checks | Christy (a11y validation) | Validation report + `analysis-results.json` |
| **Pre-merge** | `/gaia-review-all` invoked on a story at `status: review`; runs every always-on review skill plus conditional `/gaia-review-a11y` (when `compliance.ui_present: true`) and `/gaia-review-mobile` (when `platforms[]` declared) | Per-skill owner agent (see Review Skills vs Action Skills wiring table) | Per-gate `analysis-results.json` + Review Gate row update + composite verdict (ADR-082) |
| **Post-deploy** | Deployment-phase action skills invoked by `/gaia-deploy` orchestrator after a successful deploy: `/gaia-test-e2e`, `/gaia-test-perf`, `/gaia-test-dast`, `/gaia-test-a11y` post-deploy variant, plus mobile equivalents per ADR-081 | Sable (web), Talia (mobile), Soren (deploy orchestration) | Smoke-gate `analysis-results.json` + final `/gaia-deploy` verdict |

**Composite verdict (ADR-082) on pre-merge:** Aggregator considers up to seven
gates (six always-six + at most one conditional). First-match-wins precedence:
any `BLOCKED` → `BLOCKED`; any `REQUEST_CHANGES` → `REQUEST_CHANGES`; otherwise
`APPROVE`. Skipped conditional gates contribute neutrally.

**Cross-reference:** see
[`docs/planning-artifacts/architecture/architecture.md`](../docs/planning-artifacts/architecture/architecture.md)
for the gate-execution timeline diagram.

---

## Rubric Layers

> **Source:** ADR-079 (Layered Rubric Loading) §Decision.
> Merge engine: `gaia-public/plugins/gaia/scripts/rubric-merger.sh` (deterministic
> shell + jq pipeline; byte-identical output for identical inputs per NFR-RSV2-10).

**Four-layer precedence, lowest to highest (later layers override earlier):**

| Order | Layer | Path pattern | Source |
|---|---|---|---|
| 1 | **Base** | `rubrics/base/{skill}.json` (six files: `code`, `qa`, `test`, `security`, `perf`, `a11y`; `mobile.json` added by ADR-081) | Ships with the framework |
| 2 | **Regime** | `rubrics/regimes/{regime}.json` for each regime declared in `project-config.yaml` `compliance.regimes:`, **loaded in declaration order** | Framework (nine ship: `gdpr`, `hipaa`, `pci-dss`, `sox`, `ccpa`, `soc2`, `iso-27001`, `wcag-2.1-aa`, `wcag-2.1-aaa`; three more under ADR-081: `apple-app-store`, `google-play-store`, `coppa`) |
| 3 | **Domain** | Optional, project-supplied at `compliance.domain` (e.g., `fintech.json`, `healthcare.json`) | Project |
| 4 | **Project** | Optional, project-supplied at `rubrics/project/{skill}.json` | Project (highest precedence) |

**Merge semantics — RFC 7396 JSON Merge Patch:**
- `null` in a higher layer **deletes** a key from the merged result.
- Objects merge **recursively**.
- Arrays **replace** (not concatenate). The replace-on-arrays rule lets a regime
  fully redefine an enumerated severity list without inheriting base entries.

**Concrete example — project-layer override supersedes base.** Base
`rubrics/base/security.json` declares:

```json
{
  "severities": {
    "missing_input_validation": "high",
    "hardcoded_secret": "critical"
  }
}
```

A project that wants to upgrade `missing_input_validation` to `critical`
ships `rubrics/project/security.json`:

```json
{
  "severities": {
    "missing_input_validation": "critical"
  }
}
```

Merged result (project layer overrides base; `hardcoded_secret` survives unchanged):

```json
{
  "severities": {
    "missing_input_validation": "critical",
    "hardcoded_secret": "critical"
  }
}
```

If the project instead shipped `"missing_input_validation": null`, the key would
be deleted from the merged result.

**Schema validation:** every rubric file MUST validate against
`plugins/gaia/schemas/rubric.schema.json`. A failed validation HALTS the loading
skill with status `BLOCKED` (NFR-RSV2-4). `/gaia-validate-rubric {path}`
validates a single file; `/gaia-config-validate` validates the merged result.

---

## Adapter Origins

> **Source:** ADR-078 (Tool Adapter Framework) §Decision, FR-RSV2-18
> (three-state availability probe), shared helper `tool-availability-probe.sh`.

Adapters live under `gaia-public/plugins/gaia/scripts/adapters/{tool}/`
(framework built-ins) or `custom/adapters/{tool}/` (project-local; honoured
ahead of built-ins per FR-RSV2-10 tool-selection precedence).

**Three-state availability probe vocabulary and fallback behavior:**

| State | Meaning | Fallback behavior |
|---|---|---|
| **available** | Tool is installed and applicable to the repo (e.g., declared as `tools.linter.provider: eslint` AND `eslint` is on `$PATH` AND TS/JS files exist in the source tree) | Run normally; emit `analysis-results-fragment.json` with verdict-producing findings |
| **degraded** (sub-state of `available`, recorded as `errored` in the JSON fragment) | Tool ran but errored (crash, infra failure, transient timeout, partial output) | Verdict resolver emits `BLOCKED`; surface the error to the human reviewer; the skill HALTS with the actionable error |
| **unavailable** | Either (a) **expected and missing** — declared in `project-config.yaml` but not installed → fail Phase 1 prereq, skill HALTS with `BLOCKED` and an actionable error naming the missing tool; or (b) **not applicable to repo** — silent skip with `skip_reason` recorded; not a failure | (a) HALT; (b) skip silently |

**Built-in adapter origins shipped under ADR-078 (by phase):**

| Phase | Adapter set |
|---|---|
| Phase 5 (static, pre-merge) | Semgrep, gitleaks, radon, gocyclo, eslint-plugin-sonarjs, SonarQube, OWASP Dependency-Check |
| Phase 8 (deployment) | Playwright, Cypress, k6, Lighthouse, OWASP ZAP, axe-core, pa11y |
| Phase 9 (mobile static, ADR-081) | SwiftLint, SwiftFormat, Detekt, ktlint, MobSF, xcsize, apkanalyzer |
| Phase 9 (mobile dynamic, ADR-081) | Detox, Maestro, Appium, XCUITest, Espresso |
| Phase 9 (device-farm, ADR-081) | Firebase Test Lab, BrowserStack, Sauce Labs |

**Discovery skills** (FR-RSV2-21): `/gaia-list-tools` (enumerate adapters by
category), `/gaia-tool-info {tool}` (full adapter metadata),
`/gaia-validate-rubric {path}` (validate rubric against schema; cross-references
ADR-079).

---

## Agent Types

> **Source:** ADR-077 (Three-Tier Review Pipeline) §Decision wiring table —
> `agent-overlay.sh` resolves `(skill, stack) → (agent-id, sidecar-path)`.
> The wiring table is the single source of truth and is mirrored in
> [`docs/planning-artifacts/architecture/architecture.md`](../docs/planning-artifacts/architecture/architecture.md)
> §ADR-077 cross-references.

GAIA agents fall into three types based on what they consume and produce:

| Type | Description | Examples (ADR-077 wiring) |
|---|---|---|
| **Reviewer** | Verdict-producing, read-only fork-context agent invoked by a review skill or a deployment-phase action skill. Consumes the seven-phase pipeline (ADR-077). Produces `analysis-results.json` + verdict. Never mutates the source tree. | Vera (`gaia-review-qa`), Sable (`gaia-review-test`, `gaia-test-automate`, deployment-phase action skills), Zara (`gaia-review-security`), Juno (`gaia-review-perf`), Talia (`gaia-review-mobile`, mobile deployment-phase), Christy (`gaia-validate-design-a11y`), stack-specific reviewers (ts-dev, java-dev, python-dev, go-dev, flutter-dev, mobile-dev, angular-dev) for `gaia-review-code` |
| **Action** | Write-capable agent that mutates code, runs tests, or invokes external systems. Adopts the seven-phase contract with Phase 6 extended to include external write. Bound by a path allowlist and the ADR-051 plan-then-execute machinery. | Sable (test-automation actions), Soren (`gaia-deploy` orchestration) |
| **Orchestrator** | Composes reviewer/action skills, aggregates verdicts, manages gate transitions. Does not produce its own verdict; emits the composite. | `/gaia-review-all` (composite verdict aggregator per ADR-082), `/gaia-deploy` (Pattern A, Claude-driven, sequencing pre-deploy → deploy → post-deploy gates per ADR-080) |

**Sidecar memory** is read-only inside the fork — loaded by the parent context
via `agent-overlay.sh` and passed as input. Stack-conditional resolution applies
only to `gaia-review-code` (resolved via the `/gaia-dev-story` resolver); all
other skill→agent bindings are fixed.

For the canonical wiring table see ADR-077 §Decision and the architecture
document at
[`docs/planning-artifacts/architecture/architecture.md`](../docs/planning-artifacts/architecture/architecture.md).

---

## Review Verdicts vs Review Gate

> **Source:** ADR-082 (Composite Review Verdict GATING) §"Verdict-mapping
> presentation contract"; ADR-075 introduced the per-skill mapping;
> ADR-077 extended it across all twelve verdict-producing skills.
> Test contract: TC-RSV2-DOCS-1.

Two distinct vocabularies serve different surfaces and **must not be conflated**:

- **Per-skill verdict vocabulary** (output of `verdict-resolver.sh` per ADR-077):
  `APPROVE` | `REQUEST_CHANGES` | `BLOCKED`. This is the deterministic verdict
  emitted by every verdict-producing skill (six review skills + five
  deployment-phase action skills + `/gaia-review-mobile`).

- **Review Gate row vocabulary** (rendered in the story file's Review Gate
  table, consumed by `review-gate.sh` and `/gaia-check-review-gate`):
  `PASSED` | `FAILED` | `UNVERIFIED`.

**Rollup mapping (ADR-082, ADR-075):**

| Per-skill verdict | Review Gate row | Composite verdict (ADR-082) | Notes |
|---|---|---|---|
| `APPROVE` | `PASSED` | Counts as `APPROVE` toward composite (no halt) | Skill ran cleanly; no Critical findings; no errored checks |
| `REQUEST_CHANGES` | `FAILED` | Composite → `REQUEST_CHANGES` (HALT) | At least one blocking finding or LLM Critical finding |
| `BLOCKED` | `FAILED` | Composite → `BLOCKED` (HALT) | At least one check `errored` or expected-and-missing tool |
| (skill not yet run) | `UNVERIFIED` | Treated as not-yet-included; story cannot transition past gate | Initial state seeded by `init-review-gate.sh` |
| (conditional gate not triggered, e.g., a11y when `compliance.ui_present: false`) | `PASSED` (with skip reason) | Contributes neutrally — not counted as APPROVE or BLOCKED | Composite enumerates skipped gates with reason |

**Composite-verdict aggregation rule (ADR-082, first match wins):**

1. Any included gate verdict = `BLOCKED` → composite = `BLOCKED`.
2. Any included gate verdict = `REQUEST_CHANGES` → composite = `REQUEST_CHANGES`.
3. Otherwise → composite = `APPROVE`.

Both `REQUEST_CHANGES` and `BLOCKED` map to the same `FAILED` Review Gate row —
the distinction is preserved in the per-skill `analysis-results.json` and in the
composite-verdict explanation, not in the gate-row table. The Review Gate row
vocabulary is intentionally narrower than the per-skill vocabulary; the
deterministic verdict is the source of truth, the gate row is the
presentation surface.

---

## References

- ADR-077 — Three-Tier Review Pipeline (Deterministic Evidence / LLM Judgment / Scripted Verdict)
- ADR-078 — Tool Adapter Framework (Static Pre-Merge + Dynamic Deployment-Phase + Three-State Availability Probe)
- ADR-079 — Layered Rubric Loading (Base + Regimes + Domain + Project; RFC 7396 JSON-Merge-Patch)
- ADR-080 — Deployment-Phase Pattern (Post-Deploy Smoke Gates + `/gaia-deploy` Pattern A)
- ADR-081 — Mobile-as-Platform Extension (`platforms[]`, mobile stacks, store regimes, Talia overlay)
- ADR-082 — Composite Review Verdict GATING (`/gaia-review-all` migrates from informational to gating)
- Source report: [`docs/planning-artifacts/decisions/gaia-review-system-final-report.md`](../docs/planning-artifacts/decisions/gaia-review-system-final-report.md)
- Architecture wiring detail: [`docs/planning-artifacts/architecture/architecture.md`](../docs/planning-artifacts/architecture/architecture.md)
- ADR detail records: [`docs/planning-artifacts/architecture/12-12-adr-detail-records.md`](../docs/planning-artifacts/architecture/12-12-adr-detail-records.md)
