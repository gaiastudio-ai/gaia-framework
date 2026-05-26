# `reconcile-cross-stack.sh` — Phase 4b cross-stack WARNING emission (E104-S5 / FR-547)

A Phase 4b sub-step that catches **unintended coupling** between stacks in a
multi-stack monorepo. It (a) respects `stacks[].path` partitioning (per-stack
reconciliation runs in isolation — no cross-contamination), and (b) inspects the
dependency-graph for edges that cross a stack boundary, emitting a WARNING when the
edge is not sanctioned by the source stack's `cross_refs[]` allowlist.

Composition-not-dependency with E104-S2 reconciliation: it ships as a **sibling**
(`reconcile-cross-stack.sh`) so `reconcile.sh` stays focused on SBOM/LCOV/call-graph
join. In production both run in the same Phase 4b orchestration.

## Canonical WARNING vocabulary (ADR-063)

```
unsanctioned-cross-stack-reference: <source_stack>:<file> -> <target_stack>:<file>
```

The message MUST be exact — downstream operators / CI may grep for it. It is a
**WARNING**, not an ERROR: the run completes, the report records the warning, and CI
may gate at the pipeline level (not this script's responsibility).

## `cross_refs[]` allowlist semantics

A per-stack **outbound** allowlist. Stack A's `cross_refs: [B, C]` means "A may
reference B and C". Inbound allowlists are not supported (would require bidirectional
declaration — over-engineering). Evaluation is per-source-stack: an edge `A→B` is
allowed iff `B ∈ A.cross_refs`.

### Shared-subdir handling (ADR-126 §Corner Cases)

There is no "shared resource" concept — every cross-stack reference is unidirectional
and must be sanctioned per source stack. A `/shared` subdir imported by both
`/services/api` and `/services/web` requires `cross_refs: [shared]` on **each**
consuming stack. **Asymmetric allowlists are valid**: if `api` declares `[shared]` but
`web` does not, only `web→shared` warns — `api→shared` is silent.

## Reverse-index + performance (NFR-89)

A `{file → stack}` map is built once via longest-path-prefix match over `stacks[].path`
(the same prefix derivation the E70-S10 orchestrator uses). Each dep-graph edge is then
an O(1) stack lookup — **no per-edge graph walk**. Per-stack-pair detection is well
under the 100ms NFR-89 budget; the 5-stack/8-edge fixture runs in milliseconds.

> **Note on the E70-S10 mapping source.** The orchestrator persists no reusable
> in-memory cache — it writes ephemeral per-stack `<stack>.files` lists. This script
> therefore **recomputes** the `{file→stack}` prefix map deterministically (identical
> derivation, no shared mutable state) rather than reading a cache. (Val F3.)

## Bypass (ADR-120) + SR-86

`--bypass cross-stack-refs --reason "<text>"` suppresses the WARNINGs for the run and
appends an audit row to the bypass-log. The flag is parsed by the **shared**
`scripts/lib/parse-bypass-flag.sh` (E85-S14) — required-reason + length 10–500.

**SR-86 (reason allowlist).** The shared helper validates length only; the regex half
of SR-86 (threat-model §18) was not landed framework-wide (see story Finding #2). This
adapter enforces it as the SR-86 point: the reason must match `^[A-Za-z0-9 ._-]+$`
(alphanumerics, space, `.`, `_`, `-`). Shell metacharacters are REJECTED — e.g.
`--reason "; rm -rf /"` is refused with exit non-zero. Space-bearing reasons like
`"needed for migration step"` are accepted.

### Bypass-log schema (append-only JSONL)

`.gaia/memory/brownfield-audit/bypass-log.json`:

```json
{"timestamp":"<ISO-8601>","bypass":"cross-stack-refs","reason":"<text>","suppressed_count":<int>,"session_id":"<id>"}
```

## Flag gate (ADR-078)

Runs only when `brownfield.deterministic_tools: true` AND
`brownfield.phase_4b_cross_stack_enabled: true` (default true; flat spelling of the
hyphenated `brownfield.tools.phase-4b-cross-stack.enabled`). Flag-off → INFO skip.

## Degrade (never abort, NFR-84)

- **Missing dep-graph** → INFO skip + exit 0. The dep-graph producer
  (dependency-cruiser / go-callvis / pyan output) is wired by E104-S2; until then the
  configurable `XSTACK_DEPGRAPH` path is absent and the check no-ops cleanly.
- **Single-stack** (`stacks[].path: null`) → the catch-all stack owns every file, so
  there are zero cross-stack edges — behavior is byte-identical to the E104-S2 baseline
  (ADR-126 zero-regression).

## Telemetry (NFR-85, single-author)

Via `brownfield-telemetry.sh`: `cross_stack_warnings` (array of
`{source_stack,source_file,target_stack,target_file}`), `cross_stack_bypass_applied`
(bool), `phase_runtime_seconds.phase_4b_cross_stack`,
`deterministic_tool_seconds.phase_4b_cross_stack`, `llm_token_count: 0`. The
`gap_count_*` fields are E104-S1-owned and not touched here.

## Env seams (tests)

`XSTACK_CONFIG` (project-config), `XSTACK_DEPGRAPH` (dep-graph JSON),
`XSTACK_REPORT` (telemetry report), `XSTACK_BYPASS_LOG` (bypass-log path).
