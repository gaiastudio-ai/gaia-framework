---
name: deprecated-gaia-security-review
description: DEPRECATED — This skill has been retired. Use /gaia-review-security (canonical, see gaia-review-security/SKILL.md). This file remains only to expose the deprecated alias for one sprint per E69-S1.
argument-hint: "[story-key]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-security-review]
deprecated_since: sprint-37
replaced_by: gaia-review-security
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-security-review/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review skill (FR-DEJ-1, ADR-075). For `gaia-security-review` it means: deterministic tools (Semgrep ruleset, secret scanner, dependency CVE audit) run first and emit a structured `analysis-results.json` artifact. The LLM then performs an OWASP-aligned semantic review **on top of** that artifact — it cannot disregard a high-confidence Semgrep `p/security-audit` failure or a gitleaks hit on a production path, and it cannot relabel a tool failure as APPROVE. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill pattern-matches against `gaia-code-review` (E65-S2) as the canonical reference. Per-skill specialization here = (a) the security toolkit (Semgrep + secret scan + dep audit + `live-secret-classifier.sh` + `threat-model-validator.sh`) and (b) the OWASP-aligned severity rubric examples. Structural plumbing — fork dispatch, cache key, parent-mediated write — is identical to E65-S2.

**V2 sibling-reference status (E66-S4 / ADR-077).** This SKILL.md is the **canonical V2 sibling reference** for the V2 review pipeline migrations under E67. Phase 3A wiring routes through `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/` shared primitives (`agent-overlay.sh`, `verdict-resolver.sh`) and the three-state `${CLAUDE_PLUGIN_ROOT}/scripts/tool-availability-probe.sh`. E67-S1..S5 stories cite this file as the canonical migration pattern — see the **Migration Checklist** section at the bottom of this document.

**Fork context semantics (ADR-041, ADR-045, NFR-DEJ-4):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files — the tool allowlist enforces no-write isolation. Persistence of the rendered review report is parent-mediated (Option A per ADR-075): the fork returns the rendered report payload to the parent context, and the parent writes the file. `Write` and `Edit` are NEVER added to the fork allowlist.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-security-review [story-key]".
- The story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- The story MUST be in `review` status. If not, fail with "story must be in review status before security review".
- This skill is READ-ONLY in the fork. Do NOT attempt to call Write or Edit — the allowlist enforces this. Persistence is routed through the parent context.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary (inline, no separate script): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Determinism settings: `temperature: 0`, `model: claude-opus-4-7` (per ADR-074), `prompt_hash` recorded in the report header. Re-running with identical `analysis-results.json` MUST yield findings that match by category and severity (NFR-DEJ-2); textual variation is allowed.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in report header at Phase 6
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce findings that match by `{category, severity}` (NFR-DEJ-2). Textual message variation is allowed; category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch.

## Stack Toolkit Table

The toolkit invoked by Phase 3A is selected by the canonical stack name emitted by `load-stack-persona.sh`. Stack-key vocabulary is canonical across this skill and the script — they MUST match (EC-8). The Semgrep ruleset and secret scanner are stack-agnostic; only the dep-audit binary varies per stack:

| Stack key (canonical) | Semgrep ruleset                                          | Secret scanner | Dep-audit binary                             |
|-----------------------|----------------------------------------------------------|----------------|----------------------------------------------|
| `ts-dev`              | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `npm audit`                                  |
| `java-dev`            | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `mvn org.owasp:dependency-check-maven:check` |
| `python-dev`          | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `pip-audit`                                  |
| `go-dev`              | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `govulncheck ./...`                          |
| `flutter-dev`         | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `dart pub audit` (or `pub-audit`)            |
| `mobile-dev`          | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `swift package audit` / `gradle dependencyCheckAnalyze` |
| `angular-dev`         | `p/security-audit` + `p/secrets` (+ `.semgrep/` if present) | `gitleaks`     | `npm audit`                                  |

Phase 3A scope per FR-DEJ-3 is **strict**: Semgrep static analysis + secret scan + dep CVE audit. Phase 3A does NOT invoke linters, formatters, type checkers, or build verification — those belong to `gaia-code-review`. Phase 3A does NOT invoke test runners — those belong to `gaia-qa-tests` / `gaia-test-automate`.

Mismatched stack name (vocabulary drift between `load-stack-persona.sh` output and the table key) → silent skip on dep audit per FR-DEJ-4 case 3 with `skip_reason` populated.

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The LLM Phase 3B review applies the rubric below. Findings are organized by OWASP Top 10 category. Coverage targets the five categories most likely to surface in pre-merge review: **A01 Broken Access Control**, **A02 Cryptographic Failures**, **A03 Injection**, **A05 Security Misconfiguration**, **A07 Identification & Authentication Failures**. Other OWASP categories (A04, A06, A08, A09, A10) are still in scope; the rubric below seeds disambiguation for the high-frequency tiers.

The category+severity sets MUST match across two runs of identical inputs (NFR-DEJ-2 determinism contract); textual message variation is allowed. Category+severity divergence escalates as a model-pin or temperature regression.

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block. Critical-promotion threshold for Semgrep: `(rule_confidence: high) AND (rule_severity: high/error)` — prevents stock `p/security-audit` noise from forcing REQUEST_CHANGES on every diff (EC-1).

Examples (per OWASP category):

- **A01 Broken Access Control** — Admin route `/api/admin/users` reachable without authn middleware on the production-bound handler.
- **A01 Broken Access Control** — Object-level authz bypass: handler trusts a client-supplied `userId` parameter when the authenticated session already pins a different identity.
- **A02 Cryptographic Failures** — Hardcoded production API key checked into `src/config.ts:12` (gitleaks rule_confidence=high).
- **A02 Cryptographic Failures** — Symmetric encryption key derived from a constant string and used for at-rest PII encryption.
- **A03 Injection** — SQL injection in user-input path: handler concatenates `req.body.name` into a SQL string with no parameterization, Semgrep rule_confidence=high.
- **A03 Injection** — OS command injection: shell call with unescaped user input `exec("convert " + req.query.file)`.
- **A05 Security Misconfiguration** — Production CORS allows `*` on a credentialed endpoint.
- **A05 Security Misconfiguration** — Debug endpoint `/__debug__/dump` mounted on the production router with no flag gate.
- **A07 Identification & Authentication Failures** — Session cookie set without `HttpOnly`, `Secure`, and `SameSite` on a production auth flow.
- **A07 Identification & Authentication Failures** — Password reset link uses a sequential-integer token with no expiry.

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Examples (per OWASP category):

- **A01 Broken Access Control** — Authz check present at the route layer but missing on a sibling handler that exposes the same resource — defense-in-depth gap.
- **A01 Broken Access Control** — Rate-limit middleware applied per-route but not per-user — abuse vector for an authenticated bulk endpoint.
- **A02 Cryptographic Failures** — Weak crypto used for a non-security hash (e.g., MD5 for cache-key fingerprint) — not directly exploitable but flagged for cleanup.
- **A02 Cryptographic Failures** — TLS 1.0/1.1 still listed in the cipher allowlist for a non-public endpoint; modern config recommended.
- **A03 Injection** — Unsafe regex on bounded input (ReDoS-medium): user input length-capped at 64 chars but the regex still has catastrophic backtracking on a ≤64-char attacker string.
- **A03 Injection** — Missing CSRF token on an idempotent `GET` route that nevertheless writes audit-log entries.
- **A05 Security Misconfiguration** — Verbose error response leaks internal class names (e.g., `NullPointerException at com.app.service.UserService.lookup`).
- **A05 Security Misconfiguration** — Default Express security headers (`x-powered-by: Express`) not stripped.
- **A07 Identification & Authentication Failures** — Password complexity policy enforced client-side only; server accepts any non-empty string.
- **A07 Identification & Authentication Failures** — Session timeout not documented anywhere; default framework behavior likely acceptable but unverified.

### Suggestion

> Non-blocking. Style/comment polish; no behavior implications. Includes context-aware downgrades.

Examples (per OWASP category):

- **A01 Broken Access Control** — Comment-only TODO referencing a future RBAC migration; no current finding, just a tracked intent.
- **A02 Cryptographic Failures** — Synthetic test secret with the `sk-test-` prefix in `tests/fixtures/auth.test.ts` — context-aware downgrade per EC-4 (test-fixture path rule).
- **A02 Cryptographic Failures** — High-entropy literal flagged by gitleaks but matches the hex-hash pattern (64 hex chars) in a constants file — entropy false-positive per EC-12.
- **A03 Injection** — Variable named `query` in a context that does NOT reach a SQL builder; misleading name worth a rename comment.
- **A05 Security Misconfiguration** — Deprecated TLS cipher in dev-only configuration (not production-reachable) — note for cleanup.
- **A05 Security Misconfiguration** — Verbose log message in a debug-only path; not user-facing.
- **A07 Identification & Authentication Failures** — Comment in auth flow could be tightened to clarify which token type is expected.
- **A06 Vulnerable Components** — Transitive CVE in dev-only dependency path (e.g., webpack plugin not in production bundle); evidence-gated downgrade Critical→Warning→Suggestion per EC-7.

**Context-aware downgrade rules (documented in rubric):**
- Test-fixture path (e.g., `tests/`, `__tests__/`, `*.test.*`) → secret findings downgrade to Suggestion (EC-4).
- High-entropy literal matching a known non-secret pattern (hex hash, base64-encoded UUID, fixed test-data fingerprint) → Suggestion (EC-12). LLM-cannot-override still applies if the deterministic tool's `rule_confidence` is high.
- Transitive CVE in a dev-only dependency path or unreachable code path → Warning (EC-7); LLM-cannot-override still applies for production-reachable CVEs.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output + Gate Update → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable.

### Phase 1 — Setup

- If no story key was provided as an argument, fail with: "usage: /gaia-security-review [story-key]"
- Resolve the story file path using the canonical glob: `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. If zero matches: fail. If multiple matches: fail with "multiple story files matched key {story_key}".
- Read the resolved story file; parse YAML frontmatter to extract `status` and `figma:` block (if any).
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name (`ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`).
- **Persona resolution via `agent-overlay.sh` (ADR-077, V2).** In the parent context, resolve the security reviewer persona via the shared overlay:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill gaia-review-security
  ```
  Stdout is `{"agent_id":"zara","sidecar_path":".gaia/memory/zara-sidecar.md"}`. The parent context lazy-loads the Zara persona + sidecar BEFORE fork dispatch (NFR-RSV2-5 / NFR-DEJ-4 preserved). The sidecar is forwarded into the fork as **read-only context** — the fork tool allowlist `[Read, Grep, Glob, Bash]` provides no write capability against the sidecar file.
- **Threat-model context (ADR-064).** When `.gaia/artifacts/planning-artifacts/threat-model.md` exists, the skill loads it and injects it into the Phase 3B fork context under a "Threat Model Context" section. When the file is absent, proceed silently — preserves exact pre-E48-S2 behavior.
- **Tool prereq probe.** For each tool (Semgrep, gitleaks/trufflehog, the dep-audit binary listed in the toolkit row): probe via `command -v <tool>` first; fall back to local binaries. NEVER use `npx <tool> --version` — registry fetch breaks the NFR-DEJ-1 60s P95 budget. Cap each probe at 5s wall-clock; on timeout, log a Warning and continue (assume tool present). Capture each tool's reported version into `tool_versions` for the cache key.
- **Per-tool wall-clock caps (EC-10):** Semgrep ≤30s, secret scanner ≤15s, dep audit ≤15s. Cumulative Phase 3A budget ≤60s P95 cold (NFR-DEJ-1). On individual tool timeout, that tool's `status: errored` (NOT `failed` — timeout is not a finding); resolver maps to BLOCKED for the run.
- **Expected-missing-tool (FR-DEJ-4 case 1).** If a required toolkit binary is absent and not optional for the stack: emit Phase 1 BLOCKED with an actionable error message naming the missing tool and the install hint. Do NOT dispatch the fork.

### Phase 2 — Story Gate

- Status check: if `status` is not `review`, fail with "story {story_key} is in '{status}' status — must be in 'review' status for security review".
- Extract the File List section under "Dev Agent Record".
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path> --base <branch> --repo <repo>`. The script returns a JSON-shaped report; surface divergence as a Warning to the user. **Story Gate semantics are advisory per FR-DEJ-2 — divergence does NOT halt the review.** Honor `no-file-list`, `empty-file-list`, and `divergence` reasons.
- Record divergence findings in `gate_warnings[]` of the eventual `analysis-results.json`.
- Missing-file handling: if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`. Do NOT crash; Phase 3A handles it gracefully.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` written to `.gaia/state/review/security-review/{story_key}/analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`).

**Toolkit invocation (V2 / ADR-077).** Look up the toolkit row in the Stack Toolkit Table above using the canonical stack name from Phase 1. Each tool invocation is wrapped in `${CLAUDE_PLUGIN_ROOT}/scripts/tool-availability-probe.sh` (E66-S2) which performs a deterministic three-state classification before dispatching the adapter:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/tool-availability-probe.sh \
  --adapter-dir ${CLAUDE_PLUGIN_ROOT}/scripts/adapters/<tool> \
  --file-list <file-list-path> \
  --timeout <per-tool-cap>
```

The probe emits a single-line JSON object on stdout. Per ADR-078 the probe classifies into one of four states; this skill maps each state to a Phase 3A `status` field as follows:

| Probe state              | Phase 3A `status` | Verdict mapping       |
|--------------------------|-------------------|-----------------------|
| `available`              | `passed`/`failed` | per resolver          |
| `expected_and_missing`   | `errored`         | BLOCKED               |
| `ran_and_errored`        | `errored`         | BLOCKED               |
| `not_applicable`         | `skipped`         | silent skip + `skip_reason` |

The probe is the **single source of truth** for tool availability — Phase 3A MUST NOT invoke an adapter without first consulting `tool-availability-probe.sh`. This eliminates both silent downgrades (missing tools passing as APPROVE) and false BLOCKEDs (inapplicable tools halting the pipeline).

The Phase 3A toolkit, each routed through the probe and the `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/` adapter wiring:

1. **Semgrep** — invoke with the registry packs `p/security-audit` + `p/secrets`. If `.semgrep/` exists in the repo root, also invoke the custom rules; if `.semgrep/` is missing or empty, the probe returns `not_applicable` and the custom-rules step is silently skipped with `skip_reason: "no Semgrep custom rules at .semgrep/"` (EC-9). Semgrep wall-clock cap: 30s. Crash on malformed source → `ran_and_errored` → BLOCKED.
2. **Secret scanner** (gitleaks default; trufflehog acceptable per project policy) — invoke with explicit File List + working-tree scope. CLI flags MUST exclude `--history` mode (EC-2). For gitleaks: `--no-git` is REQUIRED to scope to the working tree only. Historical secrets are an out-of-scope concern for `/gaia-security-review` and belong to a separate periodic full-history scan. Secret scanner wall-clock cap: 15s.
3. **Dep CVE audit** — invoke the binary listed in the toolkit table for the resolved stack. Capture full advisory output. Dep audit wall-clock cap: 15s. Stack mismatch → probe returns `not_applicable`; binary absent for the stack → probe returns `expected_and_missing` → BLOCKED.
4. **`live-secret-classifier.sh` (V2 helper).** Credential-prefix pattern matcher that classifies high-confidence credential literals (AKIA…, ghp_…, xoxb-…, glpat-…, etc.) detected by gitleaks/Semgrep into known issuer families and emits a `revocation_runbook` field per finding. Invoked via:
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/scripts/review-common/live-secret-classifier.sh \
      --findings <gitleaks-output.json>
    ```
   Wrapped by the probe so absent helper → `not_applicable` (no failure) and runtime crash → `ran_and_errored` → BLOCKED.
5. **`threat-model-validator.sh` (V2 helper).** Cross-references each Phase 3A finding against `.gaia/artifacts/planning-artifacts/threat-model.md`. When a finding matches a modeled threat, the validator emits a `threat_ref` field (e.g., `T3`) downstream consumed by Phase 3B for inline cross-reference rendering. Invoked via:
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/scripts/review-common/threat-model-validator.sh \
      --findings <semgrep-output.json> --threat-model .gaia/artifacts/planning-artifacts/threat-model.md
    ```
   Wrapped by the probe so absent threat-model.md → `not_applicable` (silent skip) — preserves the exact pre-E48-S2 behavior.
6. **Path normalizer + finding deduplicator.** Runs after all tool adapters return; dedup key is `(file, line, finding-type)` tuple. Path normalization to repo-relative covered in detail in the Path normalization sub-section below.

**Status taxonomy (FR-DEJ-4).** Each tool invocation produces exactly one of:
- `status: passed` — tool ran to completion, no findings, exit code zero.
- `status: failed` — tool ran to completion AND emitted findings (e.g., Semgrep exit 1 with security findings; gitleaks exit 1 on secret detection; npm-audit exit 1 with CVE findings). Maps to REQUEST_CHANGES via verdict-resolver precedence rule 2 (LLM-cannot-override).
- `status: errored` — tool crashed mid-run, returned an unclassified non-zero exit code, OR exceeded its wall-clock cap. Maps to BLOCKED via precedence rule 1. Examples: Semgrep parse error on malformed source (EC-5); npm-audit network failure; tool wall-clock timeout (EC-10). Even when partial findings were emitted before the crash, `errored` wins over partial findings.
- `status: skipped` — tool not applicable; `skip_reason` populated verbatim. Examples: `skip_reason: "no Semgrep custom rules at .semgrep/"` (EC-9); dep-audit binary absent for an exotic stack (FR-DEJ-4 case 3).

**Distinguish `failed` vs `errored` by exit-code semantics, not by exit code alone** (consistent with E65-S2 EC-6). Semgrep exits 1 on findings (failed) and 2 on parse error/crash (errored). gitleaks exits 1 on secret detection (failed) and 2 on config/io error (errored).

**Path normalization (EC-13).** Tool outputs vary in path convention:
- Semgrep emits absolute paths.
- gitleaks emits paths relative to repo root.
- npm audit emits package names with no file path.

Phase 3A normalizes all `findings[].file` to repo-relative before writing `analysis-results.json`. Package-only findings (npm audit / pip-audit / govulncheck) use a synthetic location field formatted as `package.json:dependencies.<pkg>` (or per-stack equivalent: `pyproject.toml:dependencies.<pkg>`, `go.mod:require <pkg>`).

**Finding deduplication (EC-11).** Phase 3A deduplicates findings across tools by the tuple `(file, line, finding_type)` before passing to Phase 3B. Example: an API key on `src/config.ts:12` flagged by both gitleaks and Semgrep `p/secrets` is deduplicated to a single finding. The dedup key is documented here so resolver counts unique findings only.

**Cache plumbing (FR-DEJ-11).** Cache lives at `.gaia/state/review/security-review/{story_key}/.cache/`. Cache directory created via `mkdir -p` (idempotent and concurrency-safe).

Cache key:
```
sha256(
  File List contents
  || file_hashes (sha256 per File List entry, sorted)
  || tool_config blob
  || tool_versions (sorted "tool:version" lines)
  || resolved_config_hash
  || advisory_db_fingerprint
)
```

`advisory_db_fingerprint` is the sha256 of `npm audit --json | jq .metadata.advisories` for npm, or the per-stack equivalent (e.g., `pip-audit --vulnerability-service osv` digest, or a daily date-stamp proxy). This is the EC-3 mitigation: the dep-audit advisory database refreshes daily without changing the binary version. Without this fingerprint, a story marked safe yesterday can have new CVEs today and the cache would return a stale safe verdict.

`resolved_config_hash` is the sha256 of the rendered Semgrep configuration (registry packs + custom rules content) — NOT the raw `.semgrep/` directory listing.

Cache lookup:
1. Compute the candidate cache key from current File List + tool versions + resolved configs + advisory_db_fingerprint.
2. Look up `.gaia/state/review/security-review/{story_key}/.cache/{cache_key}.json`. On miss: run tools.
3. On candidate hit, **revalidate file_hashes** against current on-disk file hashes. A file in the File List can be edited externally without changing any cache-key input — if any cached `file_hashes` entry diverges from the current on-disk hash, treat as miss.

Cache write (same-story parallel-invocation safety):
- Write `analysis-results.json` to a per-PID temp path: `.gaia/state/review/security-review/{story_key}/.cache/.tmp.<pid>.<timestamp>.json`.
- `mv` (atomic rename) to the final `.cache/{cache_key}.json` path. Atomic rename gives last-writer-wins without corruption.
- Cross-story parallel invocations are safe by per-story directory partitioning.
- Persist via `${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write --workflow security-review --step 3 --file <results.json> --var cache_key=<hash>` so `checkpoint.sh validate --workflow security-review` can detect drift later.

Phase 3A also emits a rendered `.md` companion alongside `analysis-results.json` — a human-readable summary of per-tool status and findings count for log inspection.

### Phase 3B — LLM Semantic Review

Phase 3B is the **judgment layer**. The fork subagent reads `analysis-results.json` as evidence and applies the OWASP-aligned severity rubric to produce category-organized Critical / Warning / Suggestion findings.

**Fork dispatch contract.**
- `context: fork`
- `allowed-tools: [Read, Grep, Glob, Bash]` (frontmatter-enforced; no Write/Edit ever)
- `model: claude-opus-4-7` (frontmatter-pinned per ADR-074)
- `temperature: 0`
- Inputs forwarded into the fork: persona payload (from Phase 1), `analysis-results.json` content, story file path, severity rubric (this section), and — when present — the threat-model context loaded in Phase 1.

**Output contract.** Fork returns a structured findings JSON with shape `{ "findings": [{"category", "severity", "file", "line", "message", "threat_ref?"}, ...] }`. The fork ALSO returns the rendered report payload as its conversational output — the parent will validate the structure in Phase 6 before persisting.

**OWASP categorization.** Each finding carries an `owasp_category` (e.g., `A01`, `A02`, `A03`, `A05`, `A07`). Findings outside the OWASP Top 10 are categorized as `category: integrity` for missing-file divergence or `category: fidelity` for design-token drift, consistent with the cross-skill convention.

**Determinism contract (NFR-DEJ-2).** Two runs against unchanged `analysis-results.json` MUST produce findings that match by `{category, severity}`. Textual message variation is allowed. Category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch. The bats determinism regression test compares ONLY `{category, severity}` sets across two runs.

**Prompt hash recording.** The fork records `prompt_hash` (sha256 of system prompt || `analysis-results.json` content) in the report header. This is the audit trail for determinism debugging.

**Context-aware classification (rubric-driven).** Per the Severity Rubric above:
- Test-fixture path → secret findings downgrade to Suggestion (EC-4).
- High-entropy literal matching hex-hash / base64-UUID pattern → Suggestion (EC-12).
- Transitive CVE in dev-only dependency path or unreachable code path → Warning (EC-7).
- Semgrep finding promotes to Critical only when `(rule_confidence: high) AND (rule_severity: high/error)` (EC-1).

LLM-cannot-override invariant: a high-confidence deterministic finding cannot be downgraded by the LLM into APPROVE territory. The rubric downgrades above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

### Phase 4 — Architecture Conformance + Design Fidelity

The fork extends Phase 3B's findings with architecture and design checks; findings flow into the Phase 3B category buckets.

- **Security-architecture conformance.** Fork reads `.gaia/artifacts/planning-artifacts/architecture.md` and (when present) `.gaia/artifacts/planning-artifacts/threat-model.md`. For each File List entry, verify authn/authz boundaries align with the documented gateway/middleware pattern, secret-storage references match the documented vault path, and any ADRs referenced by the story exist with status Accepted. Findings under `category: architecture`.
- **Threat-model cross-reference.** When threat-model context was provided, findings that match a modeled threat carry an optional `threat_ref` field (e.g., `threat_ref: "T3"`). Format the cross-reference inline as `(see T3 in threat model)`.
- **Design fidelity.** If the story frontmatter has a `figma:` block, fork compares design-token references in the changed code against `.gaia/artifacts/planning-artifacts/design-system/design-tokens.json`. Findings under `category: fidelity`. If no `figma:` block: skip silently (no Warning, no finding).

### Phase 5 — Verdict

The verdict is computed by the parameterized `verdict-resolver.sh` from `review-common/` (E66-S1). The LLM never computes or overrides it. The resolver consumes the per-skill `analysis-results.json` regardless of which review skill produced it — the file is validated against `plugins/gaia/schemas/analysis-results.schema.json` `schema_version: "1.0"` before precedence rules apply.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh \
  --analysis-results .gaia/state/review/security-review/{story_key}/analysis-results.json \
  --llm-findings .gaia/state/review/security-review/{story_key}/llm-findings.json
```

Legacy single-skill invocations of `${CLAUDE_PLUGIN_ROOT}/scripts/verdict-resolver.sh` (the symlinked entry-point preserved for back-compat with E65-S2 fixtures) emit identical stdout — the parameterized resolver is the canonical path under V2.

The resolver applies strict first-match-wins precedence (FR-DEJ-6):
1. Any check `status: errored` → **BLOCKED**.
2. Any check `status: failed` with blocking finding → **REQUEST_CHANGES**. *The LLM cannot override this — rule 2 wins over rule 4 (LLM APPROVE) every time.*
3. Any LLM finding `severity: Critical` → **REQUEST_CHANGES**.
4. Otherwise → **APPROVE**.

Stdout is exactly one of `APPROVE | REQUEST_CHANGES | BLOCKED`. **Mapping to Review Gate canonical vocabulary is inline (no separate `verdict-normalizer.sh`):**

| Resolver output  | Review Gate verdict |
|------------------|---------------------|
| APPROVE          | PASSED              |
| REQUEST_CHANGES  | FAILED              |
| BLOCKED          | FAILED              |

This three-line mapping is local to this section per PRD §4.37. If a future review skill diverges, extract to a shared script then (YAGNI).

### Phase 6 — Output + Gate Update

Phase 6 is the **persistence layer**. The fork CANNOT write — persistence is parent-mediated (Option A per ADR-075).

**Fork output.** The fork returns a rendered report payload as its conversational output. The report MUST contain:

- Header: story key, title, prompt_hash, model, temperature.
- `## Deterministic Analysis` — per-tool status table + per-tool findings list (from `analysis-results.json`).
- `## LLM Semantic Review` — Critical / Warning / Suggestion organized by OWASP category (A01..A10) plus `architecture`, `fidelity`, and `integrity` non-OWASP buckets.
- Final line, exactly: `**Verdict: APPROVE**` or `**Verdict: REQUEST_CHANGES**` or `**Verdict: BLOCKED**`.

**Parent payload validation.** Before persisting, the parent context validates the fork output structure:
- `## Deterministic Analysis` section present.
- `## LLM Semantic Review` section present.
- Final line matches regex `^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$`.

**Malformed-payload handling.** On any of the above checks failing, the parent persists what it received with an explicit `[INCOMPLETE]` marker prepended to the report, and emits `verdict=BLOCKED` to `review-gate.sh`. Fork output untrustworthy → BLOCKED. The bats fixture covers this case explicitly (mirrors E65-S2 EC-9).

**Parent write to FR-402 locked path.** The parent context writes the rendered report to `.gaia/artifacts/implementation-artifacts/security-review-E<NN>-S<NNN>.md` per FR-402 naming convention. The path is **locked**: `security-review-{story_key}.md` — no slug, no date suffix.

**Re-run handling.** Parent **overwrites** the existing review file on re-run (latest verdict wins). No append, no version-suffix. The `review-gate.sh` row update is the source of truth for verdict history if needed.

**Gate row update.** Parent invokes the individual gate update (single-line form): `review-gate.sh update --story "{story_key}" --gate "Security Review" --verdict "{PASSED|FAILED}"`. Equivalent multi-line form for readability:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update \
  --story "{story_key}" \
  --gate "Security Review" \
  --verdict "{PASSED|FAILED}"
```

Mapping per Phase 5 table. Confirm exit code 0.

**Composite review gate check.** After the row update, parent invokes the composite check informationally:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
```

Capture stdout for the `Review Gate: COMPLETE|PENDING|BLOCKED` summary (per ADR-054). Do NOT halt on non-zero exit. Sprint-status.yaml may be out of sync — surface a hint to run `/gaia-sprint-status`.

**Fork allowlist sanity.** The frontmatter `allowed-tools` MUST remain exactly `[Read, Grep, Glob, Bash]`. The `evidence-judgment-parity.bats` AC1 assertion catches any post-merge regression that adds Write or Edit.

### Phase 7 — Finalize

- Surface the verdict to the orchestrator per ADR-063 (mandatory verdict surfacing).
- Persist findings to the per-skill checkpoint via `checkpoint.sh write` (already invoked in Phase 3A for the cache; final state recorded via the standard `finalize.sh` hook).
- The Phase 3A artifact is cached for the next run by the `.cache/{cache_key}.json` write performed in Phase 3A.

## Migration Checklist (E67 sibling consumption)

> **For E67-S1..S5 migration authors.** This section documents the V2 migration surface so each E67 story can pattern-match without ambiguity (AC9 / TC-RSV2-FOUND-SEC-07).

This file is the **canonical V2 sibling reference** (E66-S4 / ADR-077). When migrating a sibling review skill (`gaia-test-review`, `gaia-test-automate`, `gaia-review-qa`, `gaia-performance-review`, `gaia-review-security` Phase 3C privacy/data-protection restoration) to the V2 template, replicate each of the seven anchors below. Drift from this checklist is detected by `evidence-judgment-parity.bats` (E66-S5 / FR-RSV2-46).

| # | Anchor                              | V2 source / contract                                                                                                            | This file's reference                                  |
|---|-------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| 1 | Unifying principle (verbatim)       | "Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it." | Mission section, top of file                           |
| 2 | Seven-phase structure (in order)    | Setup → Story Gate → Phase 3A → Phase 3B → Phase 4 (Architecture Conformance + Design Fidelity) → Phase 5 Verdict → Phase 6 Output + Gate Update → Phase 7 Finalize | "Phases" section                                       |
| 3 | Persona via `agent-overlay.sh`      | `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill <skill-name>` resolves `(skill, stack)` to `(agent_id, sidecar_path)` per the ADR-077 wiring table | Phase 1 — Setup                                        |
| 4 | Three-state probe                   | `${CLAUDE_PLUGIN_ROOT}/scripts/tool-availability-probe.sh` wraps every Phase 3A tool invocation; states: `available` / `expected_and_missing` / `ran_and_errored` / `not_applicable` | Phase 3A — Toolkit invocation                          |
| 5 | Parameterized verdict resolver      | `${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh` consumes per-skill `analysis-results.json` (schema_version 1.0) | Phase 5 — Verdict                                      |
| 6 | Fork-write fix (Option A)           | Fork allowlist exactly `[Read, Grep, Glob, Bash]` (no Write/Edit). Parent context performs all persistence at the FR-402 locked path `<skill-prefix>-{story_key}.md` | Frontmatter + Phase 6 — Output + Gate Update          |
| 7 | TTL-aware cache key composition     | sha256 over `(story_key, tool_name, tool_versions, file_list_hash, resolved_config_hash, advisory_db_fingerprint)` — advisory-DB fingerprint mandatory for dep-audit-bearing skills | Phase 3A — Cache plumbing                              |
| 8 | Severity rubric examples per skill  | ≥2 examples per tier (Critical / Warning / Suggestion) covering the skill's domain categories (here: OWASP A01/A02/A03/A05/A07) | Severity Rubric section                                |
| 9 | Parity bats hook                    | Skill SKILL.md path appended to `REVIEW_SKILLS` array in `tests/evidence-judgment-parity.bats`; all assertion helpers must pass | `tests/evidence-judgment-parity.bats` (E66-S5)         |

**Pattern-matching guidance for E67 authors:**

- E67-S1 (`/gaia-review-test`) — Phase 3A toolkit specialization is test-runner status (`go test`, `jest`, `vitest`, `pytest`); persona is Sable; no advisory-DB fingerprint (omit row 7 fingerprint, retain rest of cache key).
- E67-S2/S3 (`/gaia-test-automate` skeleton + coverage-delta) — Same persona (Sable); Phase 3A focuses on coverage-delta computation; analysis-results.json carries `coverage_delta` field as evidence.
- E67-S4 (`/gaia-review-qa`) — Phase 3A toolkit is acceptance-criteria coverage matrix; persona is Vera; severity examples are AC-coverage-gap-flavored.
- E67-S5 (`/gaia-review-security` Phase 3C) — Privacy/data-protection restoration adds a Phase 3C stage on top of this file; reuses every anchor above unchanged.

> Once an E67 story lands, its SKILL.md MUST satisfy all `evidence-judgment-parity.bats` assertions and the V2 anchors in this checklist. CI catches drift on subsequent edits.

## References

- ADR-037 — Structured subagent return schema `{status, summary, artifacts, findings, next}`.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations.
- ADR-045 — Review Gate via Sequential `context: fork` Subagents.
- ADR-054 — Composite Review Gate.
- ADR-063 — Subagent Dispatch Contract — Mandatory Verdict Surfacing.
- ADR-064 — Threat-Model Context Plumbing for Security Skills.
- ADR-067 — YOLO Mode Contract — Consistent Non-Interactive Behavior.
- ADR-074 — Frontmatter Model Pin for Determinism.
- ADR-075 — Review-Skill Evidence/Judgment Split.
- ADR-077 — Review System V2: Three-Tier Pipeline + Shared `review-common/` Library.
- ADR-078 — Three-State Tool Availability Probe.
- ADR-082 — Composite Review Verdict GATING.
- FR-DEJ-1..12, NFR-DEJ-1..4 — Evidence/Judgment functional and non-functional requirements (PRD §4.37).
- FR-RSV2-1..4, FR-RSV2-44, NFR-RSV2-1, NFR-RSV2-5 — Review System V2 unifying principle, phase structure, verdict resolver parameterization, persona load, fork allowlist invariant.
- FR-402 — Locked review-file naming convention (`security-review-{story_key}.md`).

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-security-review/scripts/finalize.sh
