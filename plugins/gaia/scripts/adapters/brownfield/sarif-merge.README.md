# `sarif-merge.sh` — Phase 7 SARIF Multitool merge

Merges all scanner SARIF outputs into one merged SARIF so `/gaia-brownfield`
Phase 7's 6-step gap-consolidation recipe (load → validate → dedup → rank →
budget → write) consumes a single uniform interchange format instead of bespoke
per-tool JSON.

## Why SARIF as the interchange format

SARIF 2.1.0 is the consensus interchange format for static-analysis output —
named independently by Zara (security), Soren (DevOps), Hugo (Java), and Derek
(PM) in the 2026-05-23 brownfield deterministic-tools meeting. Microsoft's
`Sarif.Multitool` CLI is the canonical merger: it supports the full SARIF 2.1.0
schema and preserves per-tool attribution by concatenating one `run` object per
scanner (each carrying its `tool.driver.name`). Migrating bespoke per-tool JSON
to merged SARIF removes per-tool parser maintenance and enables uniform
downstream consumption (dedup, reconciliation, ranking).

## Contract

- **Flag gate.** Runs only when `brownfield.deterministic_tools: true`
  AND `brownfield.sarif_merge_enabled: true`. `/gaia-brownfield` resolves these via
  `resolve-config.sh --field brownfield.<key>` and exports `GAIA_BROWNFIELD_DETERMINISTIC_TOOLS`
  / `GAIA_BROWNFIELD_SARIF_MERGE_ENABLED`. Flag-off → INFO skip; the 6-step recipe
  falls back to per-tool JSON via the migration shim.
- **Migration shim (1-sprint deprecation).** Zero `*.sarif` inputs under the input dir →
  `WARN: no SARIF inputs detected … falling back to per-tool JSON consumption (deprecation: 1 sprint)`,
  exit 0. The legacy per-tool JSON path is slated for removal in the next sprint.
- **Graceful degrade.** `sarif` CLI absent → WARN + exit 0 (Phase 7 continues).
- **Deterministic.** Merged `runs` are post-sorted alphabetically by `tool.driver.name`
  via `jq` so output is byte-identical across re-runs.
- **Schema validation.** Non-conformant SARIF input → non-zero exit (surfaced to operator).
- **Output.** `.gaia/artifacts/planning-artifacts/brownfield-sarif-merged.json` (an
  artifact — the contract surface for downstream consumers — NOT transient `.gaia/memory/`).

## Config flag naming (key-spelling note)

The story AC text spells the per-tool override `brownfield.tools.sarif-merge.enabled`
(hyphenated, depth-4). The `resolve-config.sh` nested-key parser supports only
depth-3 ASCII-underscore segments, so the shipped key is the flat depth-2
`brownfield.sarif_merge_enabled` (and `brownfield.defectdojo_enabled` for the
DefectDojo opt-in). The master-flag + per-tool-override semantics are
unchanged — only the dotted-key spelling adapts to the resolver. Same constraint
applies to `brownfield.prewarm_enabled`.

## Binary supply-chain pinning

The `sarif` (Microsoft `Sarif.Multitool`) CLI MUST be version-pinned via checksum
verification in the CI image, per the **Trivy March 2026** supply-chain compromise
precedent (Microsoft IR + Aqua Security + CrowdStrike triple-source): never pull a
security tool unpinned; verify the published SHA-256 of the release artifact before
adding it to the runner image; fail the build on mismatch.

> **Status:** This repo has no dedicated dependency-pinning CI workflow
> (`.github/workflows/dependencies.yml`). The rationale + recipe are documented here;
> wiring the checksum-verified `sarif` install into CI is tracked as a finding for
> the infra owner (shared with the grype/cdxgen pinning work).
