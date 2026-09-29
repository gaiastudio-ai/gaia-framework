# Security Review — Sample Story

> **Story:** Sample Story — End-to-end real-story fixture (security review)
> **Model:** claude-opus-4-7
> **Temperature:** 0
> **prompt_hash:** sha256:0000000000000000000000000000000000000000000000000000000000000000

## Deterministic Analysis

| Tool       | Scope   | Status | Findings |
|------------|---------|--------|----------|
| semgrep    | file    | passed | 0        |
| gitleaks   | file    | passed | 0        |
| npm-audit  | project | passed | 0        |

No deterministic findings.

## LLM Semantic Review

### Critical

(none)

### Warning

- **A03 Injection** — `src/api/users.ts:42` — User input flows into a SQL-like string concatenation; bounded input mitigates immediate exploit, but an explicit parameterized query is preferred. (see T3 in threat model if applicable)
- **A05 Security Misconfiguration** — `src/server.ts:12` — Default CORS configuration permits all origins on a non-public route; tighten to the documented allowlist before merge.

### Suggestion

- **A02 Cryptographic Failures** — `src/utils/hash.ts:7` — Comment-only TODO referencing migration to a stronger hash; tracked via existing tech-debt finding.

## Architecture Conformance

- Component placement matches `architecture.md` §Layered Architecture: API handlers under `src/api/`, server bootstrap under `src/server.ts`. PASS.
- Authn/authz boundary placement aligns with documented gateway pattern. PASS.

**Verdict: APPROVE**
