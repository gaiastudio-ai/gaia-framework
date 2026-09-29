# Code Review — Sample Story

> **Story:** Sample Story — End-to-end real-story fixture
> **Model:** claude-opus-4-7
> **Temperature:** 0
> **prompt_hash:** sha256:0000000000000000000000000000000000000000000000000000000000000000

## Deterministic Analysis

| Tool     | Scope   | Status | Findings |
|----------|---------|--------|----------|
| eslint   | file    | passed | 0        |
| prettier | file    | passed | 0        |
| tsc      | project | passed | 0        |

No deterministic findings.

## LLM Semantic Review

### Critical

(none)

### Warning

- **correctness** — `src/handler.ts:42` — Edge case unhandled but documented as out-of-scope; consider an explicit guard or comment cross-referencing the documentation.
- **readability** — `src/utils.ts:18` — Function `processInput` exceeds the team length threshold (52 lines); consider extracting `validateShape` and `normalizeKeys` helpers.

### Suggestion

- **readability** — `src/handler.ts:7` — Variable `tmp` could be named more descriptively (`pendingRequest`?).

## Architecture Conformance

- Component placement matches `architecture.md` §Layered Architecture: handlers under `src/handlers/`, utils under `src/utils/`. PASS.
- Dependency direction: handler → utils → core; no inversions. PASS.
- ADR references cited; status Accepted. PASS.

## Design Fidelity

(no design-record reference; not applicable)

**Verdict: APPROVE**
