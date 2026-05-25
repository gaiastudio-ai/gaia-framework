# `reconcile.sh` — Phase 4b reconciliation pass (E104-S2 / FR-540 / ADR-124)

The barrel-file / dynamic-import **false-positive guard** for `/gaia-brownfield`. A
pure JSON-join that cross-references Phase 3 file-only findings against the dependency
graph and **demotes** (never removes) findings whose file is reachable from an
application entry point.

## Why

Phase 3 file-only scanners (dead-code, unused-export) routinely flag files that are
actually live — `src/index.ts` barrel re-exports, dynamically-imported modules,
framework entry shims. Reported as-is they inflate the gap count with false positives.
The dependency graph already knows what's reachable; this pass quiets the FPs while
keeping a full audit trail.

## Demote, don't remove

A demoted finding keeps every identity field and gains annotations:

```json
{
  "ruleId": "dead-code/js", "file_path": "src/index.ts", "source_tool": "dead-exports",
  "qualifier": "default", "start_line": 1,
  "severity": "info",
  "reconciled": true,
  "original_severity": "warning",
  "entry_points": ["src/app.tsx", "src/pages/index.tsx"],
  "reconciliation_reason": "file referenced from 2 call-graph entries"
}
```

**Identity fields — `file_path`, `qualifier`, `source_tool`, `ruleId`, `start_line` —
are preserved verbatim** (AC4/AC7). Reconciliation mutates only `severity` and adds
annotations. Files NOT reachable retain their original severity. Removing findings would
defeat audit-trail integrity and make the dedup count misleading — hence demote-not-remove.

## Inputs (pure JSON-join — no tool re-invocation)

- **Deduped finding stream** — E104-S1's `deduped-findings.json`
  (`{ruleId, file_path, severity, source_tool, qualifier, start_line}` per finding).
- **Per-stack call-graphs** — `callgraph-{js,go,python}.json` (dependency-cruiser /
  go-callvis / pyan), shape `{entry_points:[...], reachable:[{file, referenced_by:[...]}]}`.
  The union of `reachable[].file` is the reachable-set; `referenced_by` populates the
  `entry_points` annotation.
- cdxgen SBOM (E70-S7) + LCOV coverage (Phase 4) are the third/fourth declared streams;
  the call-graph reachable-set is the load-bearing one for the demotion decision.

**Single-level reachability suffices.** The call-graphs already encode transitivity, so
one membership test per finding against the precomputed reachable-set is enough — no
recursive walk, no tool re-invocation. < 5s on a 1M-line monorepo (AC5): jq index build
O(n log n) + O(n) per-finding lookup.

## Producer-path contract (relation to E104-S5)

`reconcile.sh` reads `callgraph-{js,go,python}.json`. E104-S5's `reconcile-cross-stack.sh`
is a **sibling consumer** of dependency-graph data (`depgraph.json`) and composes WITHIN
Phase 4b. Both degrade independently when their input is absent. The call-graph / dep-graph
**producer** (Phase 4 supplementary tooling) is not yet wired — both consumers no-op
cleanly until it lands (story Finding).

## Degrade (never abort)

- **Empty / missing call-graph** → WARN + findings pass through unchanged
  (`findings_demoted_by_reconciliation: 0`).
- **Missing deduped-findings input** → empty output stream, exit 0.
- **Flag-off** → raw deduped stream copied through unchanged.

## Flag gate (ADR-078)

Runs only when `brownfield.deterministic_tools: true` AND `brownfield.phase_4b_enabled:
true` (default true; flat spelling of `brownfield.tools.phase-4b.enabled`). Flag-off → INFO
skip + passthrough.

## Telemetry (NFR-85, single-author)

Via `brownfield-telemetry.sh`: `findings_demoted_by_reconciliation` (int),
`phase_runtime_seconds.phase_4b`, `deterministic_tool_seconds.phase_4b`,
`llm_token_count: 0`. The `gap_count_*` fields are **dedup-owned (E104-S1)** and are
preserved read-through — reconciliation does NOT re-author them (single-author invariant).

## Env seams (tests)

`RECON_FINDINGS` (deduped input), `RECON_CALLGRAPH_DIR` (dir of `callgraph-*.json`),
`RECON_OUTPUT` (`reconciled-findings.json`), `RECON_REPORT` (telemetry report).
