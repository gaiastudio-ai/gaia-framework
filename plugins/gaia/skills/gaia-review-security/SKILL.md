---
name: gaia-review-security
description: Perform an OWASP-focused security review on provided code or document — OWASP Top 10 scan, hardcoded secrets / API keys / credentials detection, authentication and authorization pattern review. Produces a markdown findings report with severity levels and remediation recommendations. Use when "review security" or /gaia-review-security.
argument-hint: "[target — file, directory, or document]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: reviewer
---

## Mission

You are performing an **OWASP-focused security review** on the target the user supplies. You evaluate the target across three categories: OWASP Top 10 scan, hardcoded secrets detection, and authentication / authorization pattern review. You produce a markdown findings report with OWASP findings table, secrets scan results, auth pattern review, per-finding severity, and remediation recommendations.

This skill is the **anytime review variant** of the security review pair. The pre-merge gate variant `/gaia-security-review` runs under `context: fork` (read-only, ADR-045) and dispatches OWASP analysis to the Zara subagent. This anytime variant runs **inline** — no fork, no subagent delegation — which means it can read `.gaia/artifacts/planning-artifacts/threat-model.md` directly with no fork-context limitation. It is therefore the natural place to implement threat-model cross-reference and live-secret severity escalation as inline LLM-judgment work (per ADR-042 — no new scripts required).

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/review-security.xml` task. Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model. Deterministic report-header generation is delegated to the shared foundation script `template-header.sh` (E28-S16) rather than re-prosed per skill.

## Critical Rules

- **Check against all OWASP Top 10 categories.** Every category must be evaluated — none may be silently skipped. The Top 10 (2021) list is the reference: Broken Access Control, Cryptographic Failures, Injection, Insecure Design, Security Misconfiguration, Vulnerable and Outdated Components, Identification and Authentication Failures, Software and Data Integrity Failures, Security Logging and Monitoring Failures, Server-Side Request Forgery (SSRF).
- **Flag hardcoded secrets, API keys, credentials.** Any literal token, password, connection string, or key-shaped constant is a finding — severity escalated when the value matches a **live-secret** pattern (see Step 3).
- **Check authentication and authorization patterns.** Review how identity is established, how sessions or tokens are managed, and how authorization decisions are made at every trust boundary — look for privilege escalation paths.
- **Threat-model cross-reference (ADR-064).** When `.gaia/artifacts/planning-artifacts/threat-model.md` exists, OWASP findings MUST cross-reference modeled threats by threat ID via an optional `Related Threat` column. When the file is absent, the column is omitted entirely — no error, no warning, no behavioral change from current V2.
- **Live-secret severity escalation.** Findings matching the live-secret pattern registry (AWS `AKIA...`, GCP service account JSON, GitHub PAT prefixes) MUST rank above generic hardcoded string findings.
- **Optional Review Gate integration.** When a story in `review` status is identifiable from context, the skill MUST offer to write findings to the story's Review Gate `Security Review` row via `review-gate.sh`. This does NOT replace the pre-merge `/gaia-security-review` gate — it supplements it for anytime reviews.

## Inputs

- `$ARGUMENTS`: optional target (file, directory, or document path). If omitted, ask the user inline: "Which code or document should I review for security?"

## YOLO Behavior

This skill conforms to the framework-wide YOLO Mode Contract (ADR-067).

| Behavior | YOLO Action |
|----------|-------------|
| Template-output prompts (`[c]/[y]/[e]`) | Auto-continue (skip prompt). |
| Severity / filter selection | Auto-accept defaults. |
| Optional confirmation prompts | Auto-confirm. |
| Optional Review Gate integration offer (Step 6) | Auto-proceed with the Review Gate write per ADR-067 auto-confirm. |
| Open-question indicators (unchecked checkboxes, TBD markers) | HALT — never auto-skip; require human input. |
| Memory save prompt at end | HALT — require human input (Phase 4 per ADR-061). |

In YOLO mode the optional Review Gate offer auto-proceeds without prompting (auto-confirm at template-output prompts). All other halt conditions (open questions, memory save) still require human input — YOLO never auto-answers genuine open questions.

## Steps

### Step 1 — Scope

- If `$ARGUMENTS` is non-empty, resolve it as the target. Otherwise ask the user inline for the code or document to review (preserves the legacy Step 1 "Ask user what code/doc to review" behavior — AC-EC4).
- Read the target file(s). If a directory is given, recursively read all source files under it.

#### Step 1b — Threat-Model Context Detection (ADR-064)

The anytime review variant reads `threat-model.md` **directly** with no fork-context limitation (unlike the pre-merge `/gaia-security-review`, which dispatches to Zara via `context: fork`). This means the skill can perform the SELECTIVE_LOAD inline using the Read tool.

- Probe for `.gaia/artifacts/planning-artifacts/threat-model.md` via the `Read` tool.
- **If the file exists:** read its full content. Apply SELECTIVE_LOAD per ADR-064 — extract only:
  - **Threat IDs** matched by the regex `T{N}` (where `{N}` is one or more digits — e.g., `T1`, `T2`, `T37`).
  - **Threat descriptions** (the narrative or short text adjacent to each threat ID, typically one table cell or one paragraph).
  - **Documented mitigations** (the mitigation column or section adjacent to each threat).

  Do not load full prose (risk matrices, methodology sections, DREAD scoring tables) — keep extracted context under ~4K tokens. The extraction is resilient to varying formats: STRIDE tables, free-form prose with `T{N}` markers, and DREAD matrices are all supported via the `T{N}` regex.

  Bind the extracted context to a local variable `threat_model_context` formatted as:

  ```
  ## Threat Model Context (from threat-model.md)
  | Threat ID | Description | Mitigations |
  |-----------|-------------|-------------|
  | T1 | ... | ... |
  | T2 | ... | ... |
  ```
- **If the file is absent:** proceed silently. Do NOT emit a warning, error, or user-visible message about the missing file — the skill must produce zero new output when threat-model.md does not exist. This is the graceful skip path: no behavioral change from current V2 (preserves AC4). The `threat_model_context` variable is unset; downstream Step 2 omits the `Related Threat` column entirely and Step 5 emits no `Threat model:` note other than "not present" if the report would otherwise be misleading.
- If `T{N}` extraction returns zero rows (e.g., a threat-model.md without ID markers, free-form prose), treat the file as absent for cross-reference purposes — proceed without cross-reference, identical to the absent-file path. No degradation.

### Step 2 — OWASP Top 10 Scan

Evaluate each category — record a verdict for every one (PASS / FINDING / N/A-with-justification):

1. **Broken Access Control** — missing authorization checks, IDOR, forced browsing, CORS misconfigurations, privilege escalation paths.
2. **Cryptographic Failures** — weak hashing (MD5, SHA-1 for passwords), no TLS, hard-coded keys, insecure random, missing integrity.
3. **Injection** — SQL, NoSQL, OS command, LDAP, XPath, template injection; untrusted input reaching an interpreter.
4. **Insecure Design** — missing threat model, lack of rate limiting, insecure defaults, unprotected workflows.
5. **Security Misconfiguration** — default credentials, verbose errors in production, unused features enabled, missing headers (CSP, HSTS, X-Frame-Options).
6. **Vulnerable and Outdated Components** — packages with known CVEs, unpatched frameworks, unmaintained libraries. (Cross-reference `/gaia-review-deps` output if available.)
7. **Identification and Authentication Failures** — missing MFA, weak password policy, session fixation, no account lockout, insecure credential recovery.
8. **Software and Data Integrity Failures** — unsigned updates, untrusted deserialization, CI/CD pipeline without artifact verification.
9. **Security Logging and Monitoring Failures** — no audit log, no alerting, logs contain secrets, no anomaly detection.
10. **Server-Side Request Forgery (SSRF)** — unvalidated URL inputs, metadata service access, internal-network reachable from user-controlled URLs.

#### Threat Model Cross-Reference (ADR-064)

When `threat_model_context` is set (Step 1b loaded `threat-model.md`):

- Inject the extracted Threat Model Context block into the OWASP evaluation context so each finding can be cross-referenced.
- Each OWASP finding gains an optional **`Related Threat`** column populated with the matching threat ID (e.g., `T3`) when a finding maps to a modeled threat. Use the cross-reference phrasing `see T{n} in threat model` in the finding's description (for example: "SQL injection in /api/users — see T3 in threat model").
- When no modeled threat matches a finding, the `Related Threat` column shows `—`. Do NOT invent matches — only cross-reference when a modeled threat directly applies.
- When `threat_model_context` is unset (file absent or zero-row extraction), omit the `Related Threat` column from the findings table entirely. The output is unchanged from pre-E48-S3 behavior.

### Step 3 — Secrets Scan

> **Tool dependency (Test05 F-039).** This anytime variant is **LLM-pattern-based
> and has NO hard dependency on Semgrep or gitleaks** — it runs the registry/
> regex heuristics below inline. If you DO have `semgrep` / `gitleaks` available
> (`command -v`) and choose to run them for corroboration, surface their absence
> prominently rather than silently skipping: emit a `severity:"warning"` finding
> `Static scan tool unavailable — {tool}; ran LLM-pattern scan only` so the
> report states which coverage was actually exercised. (The deterministic
> Semgrep/gitleaks gate is the brownfield/pre-merge path, governed by the
> `brownfield.*` config flags + ADR-121 — not this inline variant.)

- Look for hardcoded secrets, API keys, credentials, database connection strings, JWT signing secrets, encryption keys, OAuth client secrets, SSH private keys.
- Flag any literal that looks like a token (high-entropy string, base64-like pattern, etc.).
- Verify the secrets management approach: env vars + secret manager vs. committed files; check `.env` files are gitignored; check the CI does not echo secrets.

#### Live-Secret Pattern Registry and Severity Escalation (FR-364 AC2)

The pattern registry below identifies secrets whose **shape strongly indicates a live credential**. A finding matching any of these patterns is a **live-secret** and MUST be ranked above generic hardcoded string findings. Pattern matching is string-based (regex), not cryptographic validation — the registry is intentionally conservative to balance false-positive rate against catch rate for the most common live-secret shapes.

| Provider | Pattern | Severity |
|----------|---------|----------|
| AWS | `AKIA[0-9A-Z]{16}` (Access Key ID prefix) | **critical** (live-secret) |
| GCP | JSON object containing `"type": "service_account"` (service account credentials) | **critical** (live-secret) |
| GitHub | PAT prefixes `ghp_[A-Za-z0-9_]{36,}`, `gho_`, `ghs_`, `ghu_` | **critical** (live-secret) |
| Generic hardcoded string / token (no live-secret shape) | high-entropy literal without provider prefix | high or medium (existing behavior) |

When a finding matches a live-secret pattern:

1. Escalate the severity to **critical** — this is unconditional; live-secrets always rank above generic hardcoded strings regardless of any other heuristic.
2. Add a **Detection Rationale** to the finding entry explaining why the pattern is classified as a live-secret (which provider, which prefix or shape matched).
3. Surface the live-secret classification visibly in the secrets scan section of the report (do not bury it in a footnote).
4. Provide a redacted sample (first 4 chars + `***` + last 2 chars) so reviewers can locate the literal in source without exposing the full credential.

Generic hardcoded strings that do NOT match a live-secret pattern remain at their existing severity (high or medium per pattern strength). The escalation only applies to the live-secret pattern matches above.

### Step 3b — Phase 3C Privacy / Data-Protection Scanners (E67-S5)

Three deterministic scanners restore privacy and data-protection coverage that
was lost in the V1->V2 migration. They run in sequence after Step 3 (secrets
scan) and append their findings into the unified `analysis-results.json` that
feeds the Step 5 verdict resolver. Each scanner is a pure evidence collector
under ADR-075 — it produces structured findings, not verdicts, and its output
follows the canonical `analysis-results.json` schema (E66-S1).

```bash
# Run from the project root, passing the target paths captured in Step 1.
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/security/pii-detector.sh <target>
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/security/data-handling-lint.sh <target>
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/security/retention-policy-check.sh <target>
```

Each script emits a single `checks[]` fragment to stdout. The Phase 3C
aggregator (parent-context shell) merges the three fragments into the parent
`analysis-results.json` `checks` array under categories `privacy-pii`,
`privacy-data-handling`, and `privacy-retention`.

#### `pii-detector.sh` (privacy-pii)

Detects hardcoded PII patterns: `email`, `ssn`, `credit-card` (Luhn-plausible),
`phone` (E.164 + NANP), `ip-address` (IPv4/IPv6). Severity is **Critical** for
non-test source files, **Medium** for files matching test markers (`*.test.*`,
`*.spec.*`, `*_test.*`, `__tests__/...`).

#### `data-handling-lint.sh` (privacy-data-handling)

Flags PII-named variables flowing into logging (`console.log`/`logger.*`),
URL construction (query-string interpolation), error/exception messages, and
analytics/telemetry SDK calls (`analytics.track`, `mixpanel.track`,
`amplitude.logEvent`, ...). Severity is **High**.

#### `retention-policy-check.sh` (privacy-retention)

Flags PII-named ORM/schema fields without `@ttl`/`@expiry`/`expires_at`,
session/token store configs missing `max-age`/`ttl`/`expires_in`, and
explicit retention durations exceeding `--max-retention-days` (default `365`).
Severity is **Medium**.

#### Regime-aware loading (AC4)

`pii-detector.sh` reads `compliance.regimes` from one of:

1. The environment variable `GAIA_COMPLIANCE_REGIMES` (comma-separated keys).
2. The optional helper `resolve-config.sh` (overridable via `GAIA_RESOLVE_CONFIG`).

For each declared regime `<key>`, the scanner loads
`<plugin_root>/rubrics/regimes/<key>.json` and extends the base PII pattern
list with the entries under `privacy.patterns`. The shipped `gdpr.json`
adds `iban` (and `eu-national-id-de`). When neither the env var nor the
helper is available, **base patterns only** — no error, graceful degrade.

Regime loading is purely additive: a regime cannot suppress a base pattern.

### Step 3c — Dependency Audit Sub-Routine (E69-S4)

After Step 3b's privacy/data-protection scanners, invoke the dependency-audit
sub-routine — `/gaia-review-deps` is wired into `/gaia-review-security` Phase 3A
per source-report §2.2 + §5.4 + §15 Phase 4 item 21 and FR-RSV2-23.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/security/dep-audit-subroutine.sh \
  --target <project-root>
```

The helper probes for dependency manifests (package.json, requirements.txt,
pom.xml, pubspec.yaml, go.mod, Gemfile, Cargo.toml, etc.) under the project
root and emits a single `analysis-results.json`-shaped check fragment under the
`dependency_audit` category.

- **Conditional skip (AC3):** when no dependency manifests are found, the
  helper emits a `status:"skipped"` fragment with the verbatim
  `skip_reason: "No dependency manifests found -- skipping dep audit"`. The
  parent `/gaia-review-security` review continues; the skip does NOT affect
  the parent verdict.
- **Failure isolation (AC-EC1):** a sub-routine failure (e.g., `npm audit`
  exits non-zero from a network error) is captured as a single
  `severity:"warning"` finding (`Dependency audit unavailable -- {reason}`).
  The helper ALWAYS exits 0 on detection paths so an infrastructure failure
  in the sub-routine NEVER cascades as a parent BLOCKED verdict.
- **Evidence merging (AC4):** the parent context merges the fragment into its
  `checks[]` array under the `dependency_audit` category. Severity
  classifications then flow through the parent's resolved rubric layer
  (base + regime + domain + project per ADR-079) at the verdict-resolver
  step — sub-routine findings inherit the parent's rubric thresholds.
- **Standalone preserved (AC5):** invoking `/gaia-review-deps` directly
  remains a fully standalone path — the standalone skill resolves its own
  rubric and emits its own verdict (independent of this sub-routine wiring).

The "Dependency Audit" subsection MUST appear in the Step 5 report whenever
the sub-routine ran (skipped fragments included for transparency).

### Step 4 — Auth Review

- Verify authentication pattern: how is identity established at request entry? Is the session or token validated on every protected route?
- Verify authorization pattern: role / scope / attribute checks at the right trust boundary; least privilege by default; consistent enforcement.
- Check for privilege escalation paths: horizontal (same role, different user's data — IDOR) and vertical (user → admin via weak role check).
- Check token lifecycle: issue, refresh, revoke, expiry.

### Step 5 — Report

Invoke the shared foundation script to emit the deterministic artifact header (ADR-042):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/template-header.sh --template security-review --workflow gaia-review-security
```

If `template-header.sh` is missing or non-executable (AC-EC7), degrade gracefully to an inline prose header (`# Security Review — {date}`), log a warning, and still write a valid report.

Write the report to the following path (preserved verbatim from the legacy task — AC4):

```
{planning_artifacts}/security-review-{date}.md
```

If the file already exists for the same day (AC-EC3), write to a suffix-incremented filename (`security-review-{date}-2.md`, ...).

The report contains:

- **Threat-model status** — one-line note: "Threat model: loaded ({N} threats extracted)" or "Threat model: not present".
- **OWASP findings table** — columns: OWASP category (1–10), location (file:line or component), severity (critical / high / medium / low), finding description, remediation recommendation, **`Related Threat`** (only when threat-model context was loaded — column omitted entirely otherwise).
- **Secrets scan results** — list of any hardcoded tokens / keys / credentials, with file:line, detection rationale, redacted sample, and live-secret classification flag where applicable. Live-secret findings appear **first**, ranked critical.
- **Auth pattern review** — authentication, authorization, token lifecycle, privilege escalation findings.
- **Remediation recommendations** — prioritised action list, critical first (live-secrets at the top by construction).

If the target is empty or resolves to no files (AC-EC6), exit with `No review target resolved` and do NOT write an empty report file.

### Step 6 — Optional Review Gate Integration (FR-364 AC3)

This step is **optional** and **opt-in**. It bridges anytime reviews into the story workflow for teams that want findings persisted into the six-row Review Gate table. It does NOT replace the pre-merge `/gaia-security-review` gate.

#### Step 6a — Detect a review-status story from context

Attempt to identify a candidate story in `review` status from any of these sources:

1. **Explicit argument.** If the user passed a story key as part of `$ARGUMENTS` (e.g., `/gaia-review-security E48-S3`), use that key.
2. **Branch name.** Run `git branch --show-current` and look for a `{story_key}` token matching the canonical pattern `E\d+-S\d+` (e.g., `feat/E48-S3-...`). Resolve the story file via `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`.
3. **Current sprint context.** Read `.gaia/artifacts/planning-artifacts/sprint-status.yaml` (if present) and find any story whose `status` is `review`. If exactly one matches, propose that key. If multiple match, list them and ask the user to pick.

If a candidate is found, verify its `status` is `review` by reading the story file YAML frontmatter. A story is **identifiable for Review Gate integration** only when status is exactly `review`.

#### Step 6b — Offer the Review Gate write

When a review-status story is identifiable:

- In **normal mode**: prompt the user "Write findings summary to Review Gate `Security Review` row for story {story_key}? [y/n]". Wait for explicit confirmation.
- In **YOLO mode**: auto-proceed with the Review Gate write per ADR-067 (auto-confirm at template-output / optional-confirmation prompts). Display the verdict and the gate update result inline; do NOT prompt.

When **no review-status story is identifiable** (no key in arguments, no story-key in branch name, no `review` rows in sprint-status.yaml, or sprint-status.yaml absent), silently skip the offer entirely — no warning, no error, no user-visible message. This preserves a clean output for ad-hoc reviews of code that is not tied to a story.

#### Step 6c — Map the verdict and write to the Review Gate

Map the findings to the canonical Review Gate vocabulary (case-sensitive: `PASSED` | `FAILED`):

- **PASSED** — zero critical or high severity findings (live-secrets are critical by construction, so any live-secret triggers FAILED).
- **FAILED** — any critical or high severity finding exists. List blocking findings in the report.

Invoke the shared `review-gate.sh` script to update the story's `Security Review` row:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update --story "{story_key}" --gate "Security Review" --verdict "{PASSED|FAILED}"
```

Confirm the update succeeded (exit code 0). Report the final status to the user. Note: sprint-status.yaml may now be out of sync. Run `/gaia-sprint-status` to reconcile.

**No new scripts.** The `review-gate.sh` script already exists at `plugins/gaia/scripts/review-gate.sh` and supports the `update` sub-operation with the canonical six-row gate vocabulary. Per ADR-042, this skill introduces zero new scripts — the Review Gate integration reuses the existing shared foundation script.

## References

- Source: `_gaia/core/tasks/review-security.xml` (legacy 37-line task body — ported per ADR-041 + ADR-042).
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations (no new scripts in this skill).
- ADR-048 — Engine Deletion as Program-Closing Action.
- ADR-064 — Threat-Model Context Plumbing for Security Skills (anytime variant reads threat-model.md directly, no fork-context limitation).
- ADR-067 — YOLO Mode Contract — Consistent Non-Interactive Behavior (Review Gate offer auto-confirms in YOLO).
- FR-323 — Skill Conversion — slash-command identity preserved.
- FR-364 — `/gaia-review-security` Threat-Model Linkage and Live-Secret Escalation.
- NFR-053 — Full v1.127.2-rc.1 Feature Parity.
- OWASP Top 10 (2021): https://owasp.org/Top10/
