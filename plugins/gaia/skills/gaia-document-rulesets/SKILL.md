---
name: gaia-document-rulesets
description: Document-specific validation rulesets for artifact type detection (path and frontmatter), structural quality checks per artifact type (application, infrastructure, platform PRDs, gap analysis output), and two-pass validation logic. Consumed by the validator subagent as a JIT-loaded library.
version: '1.3'
applicable_agents: [validator]
sections: [type-detection, prd-rules, infra-prd-rules, platform-prd-rules, arch-rules, ux-rules, test-plan-rules, epics-rules, gap-analysis-rules, brainstorm-rules, market-research-rules, domain-research-rules, technical-research-rules, two-pass-logic]
allowed-tools: [Read, Write, Edit, Grep]
orchestration_class: light-procedural
---

<!-- Source: _gaia/lifecycle/skills/document-rulesets.md. -->

## Mission

Provide the document-type-aware validation rulesets used by the validator (Val) when checking planning and test artifacts. This skill supplies the rules — it does not decide *when* to run them. Callers (the validator subagent, `gaia-val-validate`, `gaia-val-validate-plan`) detect the artifact type, load the matching section(s) of this skill JIT, and apply the rules listed there.

Every section marker below is a contract. Under the native execution model, the Claude Code skill runtime resolves caller references like `document-rulesets§prd-rules` by scanning this file for the matching `<!-- SECTION: {id} -->` marker and reading the body until the corresponding `<!-- END SECTION -->`. Section resolution is native to the skill runtime — there is no separate engine to consult.

## Critical Rules

- **Do not rename, merge, or drop any section.** Every `<!-- SECTION: -->` marker is part of the public JIT contract. Renaming a section is a breaking change against every caller that references it by ID.
- **Frontmatter detection wins over path detection.** When both produce a match, the `template:` frontmatter value is authoritative.
- **Unknown artifact types fall through to factual verification only.** Do not fabricate rules for unrecognized types — let the two-pass logic run Pass 2 only and note the unknown type in the report.
- **Severity is enforced here, not negotiated.** CRITICAL, WARNING, and INFO classifications in each ruleset MUST be respected by the caller without downgrading.

<!-- SECTION: type-detection -->
## Artifact Type Detection

### Frontmatter-Based Detection (Higher Priority)

Check frontmatter first before falling back to filename detection. If the artifact has YAML frontmatter with a `template` field, use the frontmatter mapping table below. Frontmatter detection takes higher priority than filename detection because it is explicit and unambiguous.

| Frontmatter `template` Value | Ruleset ID(s) | Description |
|------------------------------|---------------|-------------|
| `'prd'` | prd-rules | Application Product Requirements Document |
| `'infra-prd'` | infra-prd-rules | Infrastructure PRD |
| `'platform-prd'` | prd-rules + infra-prd-rules | Platform PRD (both rulesets applied) |

### Frontmatter Detection Algorithm

1. Parse the artifact's YAML frontmatter (content between opening `---` and closing `---`)
2. Check for a `template` field in the frontmatter
3. If `template` field exists, match against the frontmatter mapping table above
4. If a match is found, return the corresponding ruleset ID(s). For `'platform-prd'`, return both `prd-rules` and `infra-prd-rules` — both rulesets are applied sequentially
5. If `template` field is absent or does not match, fall through to path-based detection below

### Artifact-Type Slug Mapping (Upstream Caller Hint)

Upstream skills invoke `/gaia-val-validate` with an explicit `artifact_type` slug per the Upstream Integration Contract (see `gaia-val-validate/SKILL.md`). When that slug is present, it takes precedence over both frontmatter and path detection — the caller has authoritative knowledge of the artifact type.

| `artifact_type` Slug | Ruleset ID | Description |
|----------------------|------------|-------------|
| `brainstorm` | brainstorm-rules | Brainstorm artifact emitted by `/gaia-brainstorm` |
| `market-research` | market-research-rules | Market Research artifact emitted by `/gaia-market-research` |
| `domain-research` | domain-research-rules | Domain Research artifact emitted by `/gaia-domain-research` |
| `technical-research` | technical-research-rules | Technical Research artifact emitted by `/gaia-tech-research` (slug aligned with filename) |

For the Phase 1 artifact types above, the slug is the canonical detection signal because their on-disk filenames vary by `{slug}` (brainstorm) or live in `.gaia/artifacts/planning-artifacts/` alongside other planning docs (market/domain/technical research) and may not carry a `template:` frontmatter field. Detection precedence: `artifact_type` slug -> frontmatter `template` -> filename basename -> unknown.

### Path-to-Ruleset Mapping (Fallback)

If no frontmatter match is found, detect the artifact type from the file path basename. Match against these patterns:

| File Pattern | Ruleset ID | Description |
|-------------|------------|-------------|
| `prd.md` | prd-rules | Product Requirements Document |
| `architecture.md` | arch-rules | Architecture Document |
| `ux-design.md` | ux-rules | UX Design Specification |
| `test-plan.md` | test-plan-rules | Test Plan |
| `epics-and-stories.md` | epics-rules | Epics and Stories |
| `test-gap-analysis-*.md` | gap-analysis-rules | Test Gap Analysis Output |
| `brainstorm-*.md` | brainstorm-rules | Brainstorm artifact (Phase 1) |
| `market-research.md` | market-research-rules | Market Research artifact (Phase 1) |
| `domain-research.md` | domain-research-rules | Domain Research artifact (Phase 1) |
| `technical-research.md` | technical-research-rules | Technical Research artifact (Phase 1) |

### Path-Based Detection Algorithm

1. Extract the basename from the artifact path (e.g., `.gaia/artifacts/planning-artifacts/prd.md` -> `prd.md`)
2. Match basename against the mapping table above (case-insensitive)
3. If a match is found, return the corresponding ruleset ID
4. If no match is found, return `unknown` — skip document-specific rules, run factual claim verification only

### Edge Cases and Fallback

- **Frontmatter takes priority**: If both frontmatter and filename match, frontmatter wins
- **Nested directories**: Only the basename matters — `any/nested/path/prd.md` still matches prd-rules
- **Custom paths**: Files with non-standard names (e.g., `custom-doc.md`) fall back to unknown/unrecognized type
- **Case sensitivity**: Match is case-insensitive (`PRD.md` and `prd.md` both match prd-rules)
- **Fallback**: When no ruleset matches, skip structural pass entirely and proceed to factual claims only
<!-- END SECTION -->

<!-- SECTION: prd-rules -->
## PRD Validation Rules

Structural quality checks for Product Requirements Documents. This ruleset absorbs and supersedes all checks from the standalone validate-prd workflow, enabling its deprecation.

### Section Completeness Check

Verify all required PRD sections exist: overview, personas, functional requirements, non-functional requirements, user journeys, data model, integrations, constraints, success criteria. Flag missing sections as CRITICAL.

### FR/NFR Sequential Numbering

Verify functional requirements use sequential numbering (FR-001, FR-002, ...). Verify non-functional requirements use sequential numbering (NFR-001, NFR-002, ...). Flag gaps or duplicates as WARNING.

### Acceptance Criteria Quality

For each requirement, verify acceptance criteria exist, are specific (not blank or generic), are testable, unambiguous, and measurable. Flag vague criteria (e.g., "fast", "easy to use" without quantification) as WARNING.

### Priority Consistency

Verify every requirement has a priority assigned (P0/P1/P2/P3 or Must/Should/Could/Won't). Check that priorities do not contradict across related requirements. Flag missing or contradictory priorities as WARNING.

### Persona Cross-Reference

Verify user personas referenced in requirements match personas defined in the personas section. Flag orphaned persona references (used but not defined) as WARNING.

### Quality and Consistency

Verify terminology is used consistently across sections. Cross-reference all sections for contradictions. Flag inconsistencies as WARNING.
<!-- END SECTION -->

<!-- SECTION: infra-prd-rules -->
## Infra PRD Validation Rules

Structural quality checks for Infrastructure Product Requirements Documents. This ruleset validates infra PRDs.

### Section Presence Check

Verify all 13 required infrastructure PRD sections exist and are non-empty. Flag missing sections as CRITICAL.

Required sections:
1. Overview & Scope
2. Goals and Non-Goals
3. Platform Capabilities
4. Resource Specifications
5. Operational SLOs
6. Security Posture
7. Environment Strategy & Developer Experience
8. Dependencies & Provider Constraints
9. Cost Model
10. Verification Strategy
11. Operational Runbooks
12. Requirements Summary
13. Open Questions

### IR/OR/SR ID Uniqueness

Verify requirement IDs use the infrastructure ID scheme (IR-###, OR-###, SR-###). Check ID uniqueness within each prefix family — no duplicate IR-001 entries, no duplicate OR-001 entries, no duplicate SR-001 entries. Flag duplicate IDs as WARNING.

### Security Posture Non-Empty

The Security Posture section is mandatory and must be non-empty for all infrastructure PRDs. An empty or placeholder-only Security Posture section is a CRITICAL finding. This section must contain substantive content covering IAM/RBAC, network segmentation, secrets management, or compliance mapping.

### Cost Model Per-Environment Estimates

The Cost Model section must include per-environment cost estimates. At minimum, dev, staging, and prod environments must have cost projections. Flag missing per-environment estimates as WARNING.

### Verification Strategy Policy-as-Code Reference

The Verification Strategy section must reference at least one policy-as-code tool. Recognized tools include: OPA, Rego, Checkov, tfsec, Sentinel, or equivalent. Flag missing policy-as-code references as WARNING.

### Platform Capabilities Format Validation

Each entry in the Platform Capabilities section must follow the format: "Enable {team/service} to {capability} with {SLO}". Entries that do not match this pattern should be flagged as WARNING with a suggestion to reformat.
<!-- END SECTION -->

<!-- SECTION: platform-prd-rules -->
## Platform PRD Validation Rules

Platform PRDs represent hybrid projects that combine application and infrastructure concerns. A platform PRD must pass both the `prd-rules` (application) and `infra-prd-rules` (infrastructure) validation rulesets.

### Composite Validation

When validating a platform PRD (detected via `template: 'platform-prd'` in frontmatter):
1. Run all checks from `prd-rules` — application structural rules apply
2. Run all checks from `infra-prd-rules` — infrastructure structural rules apply
3. Merge findings from both rulesets into a single report

### Dual ID Scheme Validation

Platform PRDs use both application and infrastructure requirement ID schemes:
- Application requirements: FR-### (functional) and NFR-### (non-functional)
- Infrastructure requirements: IR-### (infrastructure), OR-### (operational), SR-### (security)

Both ID namespaces must be validated for uniqueness within their respective prefix families. No collisions between FR-001 and IR-001 because the prefix disambiguates.
<!-- END SECTION -->

<!-- SECTION: arch-rules -->
## Architecture Validation Rules

Structural quality checks for Architecture Documents.

### Component Coverage

Verify all system components mentioned in the system overview are covered in the detailed component descriptions. Check that the C4 diagrams (context, container, component) reference all declared components. Flag undocumented components as WARNING.

### ADR Consistency

Verify each ADR has: ID, Decision, Rationale, Status. Check ADR IDs are sequential (ADR-001, ADR-002, ...). Verify ADR status values are valid (Proposed, Active, Deprecated, Superseded). Check cross-references between ADRs and component descriptions are bidirectional. Flag inconsistencies as WARNING.

### API Completeness

Verify each declared API endpoint has: method, path, request/response schema, error codes. Check that APIs referenced in component descriptions exist in the API specification section. Flag incomplete API definitions as WARNING.
<!-- END SECTION -->

<!-- SECTION: ux-rules -->
## UX Design Validation Rules

Structural quality checks for UX Design Specifications.

### Required Sections

Verify presence of: design principles, user flows, wireframes/mockups, component library, accessibility requirements, responsive breakpoints. Flag missing sections as WARNING.

### Flow Completeness

Verify each user flow has: entry point, steps, decision points, exit conditions. Check that flows reference defined screens/components. Flag incomplete flows as WARNING.

### Accessibility

Verify WCAG compliance requirements are stated. Check color contrast ratios are specified. Verify keyboard navigation patterns are defined. Flag missing accessibility considerations as WARNING.
<!-- END SECTION -->

<!-- SECTION: test-plan-rules -->
## Test Plan Validation Rules

Structural quality checks for Test Plans.

### Required Sections

Verify presence of: test strategy, test scope, test types (unit, integration, e2e), entry/exit criteria, test environment, risk assessment. Flag missing sections as WARNING.

### Coverage Mapping

Verify each functional requirement has at least one mapped test case. Check that test case IDs are unique and sequential. Verify traceability links between requirements and test cases. Flag unmapped requirements as WARNING.

### Environment Specification

Verify test environments are fully specified (OS, browser, device matrix). Check that CI/CD integration is described. Flag underspecified environments as WARNING.
<!-- END SECTION -->

<!-- SECTION: epics-rules -->
## Epics and Stories Validation Rules

Structural quality checks for Epics and Stories documents.

### Epic Structure

Verify each epic has: ID, title, description, acceptance criteria, priority, stories list. Check epic IDs are sequential (E1, E2, ...). Flag incomplete epics as WARNING.

### Story Structure

Verify each story has: key, title, user story (As a/I want/So that), acceptance criteria, tasks, size estimate. Check story keys follow convention ({epic}-S{n}). Flag incomplete stories as WARNING.

### Dependency Consistency

Verify all `depends_on` and `blocks` references point to existing stories. Check for circular dependencies. Verify priority ordering respects dependency chains. Flag broken references as WARNING.
<!-- END SECTION -->

<!-- SECTION: gap-analysis-rules -->
## Gap Analysis Output Validation Rules

Structural quality checks for the test gap analysis output artifact produced by `/gaia-test-gap-analysis`. These rules validate conformance to the output schema defined by `_gaia/lifecycle/templates/test-gap-analysis-template.md`.

**Scope:** files matching `.gaia/artifacts/test-artifacts/test-gap-analysis-*.md`.

**Schema version:** 1.0.0

### YAML Frontmatter — Required Fields

The frontmatter block must parse cleanly as YAML and contain all five required fields. Missing any field is a WARNING. A frontmatter parse failure (malformed YAML, missing `---` delimiters, unquoted special characters) is a CRITICAL finding.

| Field | Type | Constraint |
|-------|------|------------|
| `mode` | enum | must be `coverage` or `verification` |
| `date` | string | non-empty ISO-8601 date (YYYY-MM-DD) |
| `project` | string | non-empty |
| `story_count` | integer | >= 0 |
| `gap_count` | integer | >= 0 |

### Gap Type Enum (Closed)

The `gap_type` field on every Gap Table row must match exactly one of these four values. Any other value is a CRITICAL finding. This enum is closed by design — adding a new gap type is a breaking change and requires a schema version bump.

- `missing-test`
- `unexecuted`
- `uncovered-ac`
- `missing-edge-case`

### Severity Enum (Closed)

The `severity` field on every Gap Table row must match exactly one of these four values. Any other value is a CRITICAL finding.

- `critical`
- `high`
- `medium`
- `low`

### Required Sections

The output must contain these four top-level sections in this order. Missing any section is a WARNING.

1. `## Executive Summary`
2. `## Gap Table`
3. `## Per-Story Detail`
4. `## Recommendations`

### Gap Table Column Order

The Gap Table must declare its columns in this exact order. A table with columns in a different order or with missing columns is a WARNING.

1. `story_key`
2. `gap_type`
3. `severity`
4. `description`

### Cross-Field Consistency

- If `gap_count == 0`, the Executive Summary should contain the phrase `No coverage gaps detected` — absence is an INFO finding.
- `gap_count` should equal the number of data rows in the Gap Table (excluding the header and separator rows) — mismatch is a WARNING.

### Generated vs Executed Tracking

Verification-mode outputs must report generated and executed test case
counts per story and in aggregate. These rules apply only when `mode:
verification` appears in the frontmatter.

- The Executive Summary must contain a `Generated vs Executed` row in the
  format `{total_executed}/{total_generated} ({aggregate_exec_ratio}%)`.
  Missing row is a WARNING.
- Each Per-Story Detail subsection must declare three fields: `generated`
  (integer >= 0), `executed` (integer >= 0), and `exec_ratio` (percentage
  with one decimal place, e.g., `60.0%`). A missing field on a present
  story subsection is a WARNING.
- `exec_ratio` must equal `round((executed / generated) * 100, 1)` when
  `generated > 0`. When `generated == 0`, `exec_ratio` must be `0.0%` and
  the subsection should include the note `0/0 (no generated tests)` —
  absence of the note is an INFO finding.
- Stories with `executed == 0` and `generated > 0` should be flagged as
  HIGH gap priority — absence of the HIGH flag for such stories is a
  WARNING.
- The aggregate row values must be consistent with the sum of per-story
  counts: `total_generated == sum(story.generated)` and
  `total_executed == sum(story.executed)` — mismatch is a WARNING.
<!-- END SECTION -->

<!-- SECTION: brainstorm-rules -->
## Brainstorm Validation Rules

Structural quality checks for brainstorm artifacts emitted by `/gaia-brainstorm` to `.gaia/artifacts/creative-artifacts/brainstorm-{slug}.md`. This ruleset complements the `/gaia-brainstorm` 24-item finalize.sh checklist — finalize.sh enforces the script-verifiable items at write time; this ruleset is what Val applies during auto-review.

**Scope:** files matching `.gaia/artifacts/creative-artifacts/brainstorm-*.md`. Detected via `artifact_type = brainstorm` per the slug mapping table.

### Required Sections

Verify presence of the following top-level sections. Missing any section is a WARNING.

1. `## Vision Summary`
2. `## Target Users`
3. `## Pain Points`
4. `## Differentiators`
5. `## Competitive Landscape`
6. `## Opportunity Areas`
7. `## Parking Lot`
8. `## Next Steps`

### Opportunity Areas Minimum Count

The `## Opportunity Areas` section must contain at least 3 enumerated opportunity entries. Fewer than 3 is a CRITICAL finding — brainstorm output below this threshold has insufficient breadth for downstream PRD/market-research consumption.

### Opportunity Entry Quality

Each opportunity entry should declare Impact and Feasibility (e.g., `Impact: high; Feasibility: medium`). Missing Impact or Feasibility on any opportunity entry is a WARNING.

### Parking Lot Revival Triggers

Each `## Parking Lot` entry should declare a revival condition (e.g., `Revival condition: when X demand is validated`). Parking-lot entries without a revival condition are an INFO finding — they signal a future-elicitation gap rather than a structural defect.

### Next Steps Traceability

The `## Next Steps` section must reference at least one downstream GAIA workflow (e.g., `/gaia-market-research`, `/gaia-domain-research`, `/gaia-create-prd`). A missing or empty Next Steps section is a WARNING.

**References:** `/gaia-brainstorm` SKILL.md (finalize.sh checklist), `gaia-val-validate` SKILL.md (Step 2 type-detection slug mapping).
<!-- END SECTION -->

<!-- SECTION: market-research-rules -->
## Market Research Validation Rules

Structural quality checks for market research artifacts emitted by `/gaia-market-research` to `.gaia/artifacts/planning-artifacts/market-research.md`. This ruleset complements the `/gaia-market-research` 28-item finalize.sh checklist.

**Scope:** files matching `.gaia/artifacts/planning-artifacts/market-research.md`. Detected via `artifact_type = market-research` per the slug mapping table.

### Required Sections

Verify presence of the following top-level sections. Missing any section is a WARNING.

1. `## Executive Summary`
2. `## Market Definition`
3. `## Competitive Analysis`
4. `## Customer Segments`
5. `## Market Sizing`
6. `## Key Findings`
7. `## Strategic Recommendations`

### Geographic Scope Declaration

The `## Market Definition` or `## Executive Summary` section must declare a geographic scope (e.g., `global`, `North America`, `EMEA`). A missing geographic scope is a WARNING — the market sizing is not interpretable without it.

### Competitive Analysis Minimum Count

The `## Competitive Analysis` section must enumerate at least 3 competitors. Fewer than 3 is a CRITICAL finding — competitive positioning below this threshold cannot meaningfully differentiate.

### Competitor Strengths/Weaknesses

For each named competitor, the artifact should declare both Strengths and Weaknesses. A competitor entry missing either is a WARNING.

### TAM/SAM/SOM Estimates and Assumptions

The `## Market Sizing` section must include three estimates: TAM, SAM, and SOM. Each estimate must be accompanied by stated assumptions (e.g., `TAM assumptions: 40M product professionals worldwide, $200 ACV per seat`). Missing any of the three estimates is a CRITICAL finding. Missing assumptions on a present estimate is a WARNING (mirrors the V1 finalize.sh `tam_assumptions` / `sam_assumptions` / `som_assumptions` items).

### Customer Segment Evidence

Each customer segment in `## Customer Segments` should cite evidence (e.g., interview counts, survey results, behavioral data). Segments without evidence are a WARNING.

### Web Access Disclosure

The artifact should declare whether web access was available during the research session (e.g., a `## Web Access` section noting availability). A missing web-access disclosure is an INFO finding.

**References:** `/gaia-market-research` SKILL.md (finalize.sh checklist), `gaia-val-validate` SKILL.md (Step 2 type-detection slug mapping).
<!-- END SECTION -->

<!-- SECTION: domain-research-rules -->
## Domain Research Validation Rules

Structural quality checks for domain research artifacts emitted by `/gaia-domain-research` to `.gaia/artifacts/planning-artifacts/domain-research.md`. This ruleset complements the `/gaia-domain-research` finalize.sh checklist.

**Scope:** files matching `.gaia/artifacts/planning-artifacts/domain-research.md`. Detected via `artifact_type = domain-research` per the slug mapping table.

### Required Sections

Verify presence of the following top-level sections. Missing any section is a WARNING.

1. `## Domain Overview`
2. `## Key Players`
3. `## Regulatory Landscape`
4. `## Trends`
5. `## Terminology Glossary`
6. `## Risk Assessment`
7. `## Recommendations`

### Terminology Glossary Mandatory

The `## Terminology Glossary` section is mandatory and must contain at least 5 defined terms. A missing or empty glossary is a CRITICAL finding — domain research without a shared vocabulary cannot be reliably consumed by downstream workflows.

### Key Players Coverage

The `## Key Players` section must enumerate at least 3 named players with role descriptions. Fewer than 3 named players is a WARNING.

### Risk Assessment Categorization

The `## Risk Assessment` section should partition risks into named subcategories (e.g., `### Regulatory and Compliance Risks`, `### Technical Risks`, `### Market and Competitive Risks`). A flat unstructured Risk Assessment is a WARNING.

### Regulatory Landscape Specificity

The `## Regulatory Landscape` section should cite named regulations, standards, or licensing regimes (e.g., GDPR, PSD2, PCI-DSS). A regulatory section without named regulations is a WARNING.

### Web Access Disclosure

The artifact should declare whether web access was available during the research session. A missing web-access disclosure is an INFO finding.

**References:** `/gaia-domain-research` SKILL.md (finalize.sh checklist), `gaia-val-validate` SKILL.md (Step 2 type-detection slug mapping).
<!-- END SECTION -->

<!-- SECTION: technical-research-rules -->
## Technical Research Validation Rules

Structural quality checks for technical research artifacts emitted by `/gaia-tech-research` to `.gaia/artifacts/planning-artifacts/technical-research.md`. This ruleset complements the `/gaia-tech-research` 22-item finalize.sh checklist. The artifact_type slug `technical-research` is aligned with the on-disk filename.

**Scope:** files matching `.gaia/artifacts/planning-artifacts/technical-research.md`. Detected via `artifact_type = technical-research` per the slug mapping table.

### Required Sections

Verify presence of the following top-level sections. Missing any section is a WARNING.

1. `## Technology Overview`
2. `## Evaluation Matrix`
3. `## Trade-off Analysis`
4. `## Recommendation`
5. `## Migration / Adoption Considerations`

### Alternatives Minimum Count

The `## Trade-off Analysis` (or its `### Alternatives Compared` subsection) must compare at least 2 alternatives. Fewer than 2 is a CRITICAL finding — a single-candidate "comparison" is a recommendation, not research.

### Evaluation Matrix Dimensions

The `## Evaluation Matrix` must declare at least 5 evaluation dimensions (e.g., maturity, community, learning curve, licensing, ecosystem, performance, scalability). Fewer than 5 is a WARNING.

### Recommendation Rationale

The `## Recommendation` section must declare both the recommended technology and a rationale referencing constraints from the Technology Overview (e.g., team size, runway, licensing preference). A recommendation without explicit rationale is a WARNING.

### Migration Considerations

The `## Migration / Adoption Considerations` section must address at minimum: timeline, team ramp-up, and risk factors. A migration section missing any of these three is a WARNING.

### Web Access Disclosure

The artifact should declare whether web access was available during the research session. A missing web-access disclosure is an INFO finding.

**References:** `/gaia-tech-research` SKILL.md (finalize.sh checklist), `gaia-val-validate` SKILL.md (Step 2 type-detection slug mapping).
<!-- END SECTION -->

<!-- SECTION: two-pass-logic -->
## Two-Pass Validation Logic

### Pass Ordering

Document-specific validation uses a two-pass approach:

1. **Pass 1 — Structural Rules**: Run the document-specific ruleset matched by type detection. This checks internal document quality: section completeness, numbering, cross-references within the document itself. Produces structural findings.

2. **Pass 2 — Factual Claims**: Run the standard factual claim extraction and filesystem verification (from validation-patterns skill). This checks external accuracy: file paths exist, counts match reality, references resolve. Produces factual findings.

### Merge Strategy

After both passes complete, merge findings into a single report:
- Structural findings are tagged with source `[STRUCTURAL]`
- Factual findings are tagged with source `[FACTUAL]`
- Both use the same severity classification (CRITICAL/WARNING/INFO)
- Findings are grouped by severity, then by source (structural first within each group)

### Unknown Type Handling

When the artifact type is unknown (no matching ruleset):
- Skip Pass 1 entirely — no structural rules to apply
- Run Pass 2 only — factual claim verification
- Report notes: "No document-specific ruleset for this artifact type — factual verification only"
<!-- END SECTION -->
