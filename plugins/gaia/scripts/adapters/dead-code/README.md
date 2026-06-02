# Per-stack dead-code adapters (E70-S8 / FR-545 / NFR-87)

Three deterministic per-stack dead-code adapters that replace the LLM dead-code
heuristic in `/gaia-brownfield` Phase 3. Each adapter wraps a sound, stack-native
tool and emits findings at that tool's **native precision** — the framework does
**NOT** synthesize a unified cross-stack confidence score.

| Adapter | Tool | Precision model | qualifier shape |
|---------|------|-----------------|-----------------|
| `go-deadcode/` | `golang.org/x/tools/cmd/deadcode` | whole-program reachability (Rapid Type Analysis) — **binary verdict**, zero false positives by construction | `<package>.<Function>` |
| `python-vulture/` | `vulture --min-confidence 80` | **confidence %** (vulture filters sub-threshold itself) | `<line>:<symbol>@<confidence>` |
| `jvm-spotbugs/` | SpotBugs, `priority=1 AND rank<=4` | **priority × rank ordinal** (conservative proven-dead-equivalent default) | `<FQCN>.<method>(<signature>)` |

## Per-stack precision is the design intent — not a bug

Each tool reports deadness at a fundamentally different granularity. A Go function
is either reachable or not (RTA proves it); a Python symbol carries a heuristic
confidence; a SpotBugs finding carries a priority/rank ordinal. **Collapsing these
onto one synthesized "confidence" scale would fabricate precision the tools never
claimed** — the exact failure mode this story exists to prevent
(meeting-2026-05-23, Sable turn 12; AI-2026-05-23-3). The unified "Test Quality"
report section therefore renders **three labeled per-stack sub-sections**, each
showing its own qualifier verbatim — never one flat list with a cross-stack score.

## Universal `file_path` JOIN key

`file_path` is the single cross-stack normalization point — repo-root-relative for
every adapter. Stack-native `qualifier` is preserved verbatim in the detail column.
E104-S2 Phase 4b reconciliation reads this contract.

## Two outputs per adapter

Each adapter writes BOTH:

1. **Flat normalized JSON** → `<audit>/dead-code/<tool>.json`
   (`{file_path, qualifier, severity, source_tool}`) — consumed by the Phase 7
   `render-test-quality.sh` writer (report rendering, AC4).
2. **SARIF run** → `<audit>/sarif/<tool>.sarif` with `qualifier` in
   `.properties.symbol` and `file_path` in the location `artifactLocation.uri` —
   so the finding flows into the E104-S1 cross-tool dedup precision ladder
   (`deadcode-go > spotbugs > vulture`, grouped on `(file_path, qualifier)`).

`render-test-quality.sh --out-dir <audit> --report <md>` splices the unified
section (idempotently) into `consolidated-gaps.md`.

## Flag gating (ADR-078)

Master flag `brownfield.deterministic_tools: true` AND the per-tool override gate
each adapter:

- `brownfield.deadcode_go_enabled` (default true)
- `brownfield.deadcode_python_enabled` (default true)
- `brownfield.deadcode_jvm_enabled` (default true)

Flat key spelling maps the AC's hyphenated `brownfield.tools.deadcode-{go,python,jvm}.enabled`
(`resolve-config.sh`'s nested-key parser accepts only ASCII-underscore segments —
semantics unchanged). Default true is applied at the adapter consumer layer
(`GAIA_BROWNFIELD_DEADCODE_*_ENABLED:-true`); the resolver emits empty when unset.

**Two distinct skip cases:** `enabled: false` → adapter NOT invoked (zero work,
field absent in report frontmatter). Enabled but toolchain absent → adapter runs and
degrades gracefully (WARN + exit 0; field present with `0` + an absent-toolchain
annotation). Master flag off → all three skipped regardless of per-tool overrides.

## Telemetry (NFR-85, single-author per field)

Via the shared `../brownfield/brownfield-telemetry.sh`. Each adapter owns ONLY its
own sibling fields — `phase_runtime_seconds.deadcode_{go,python,jvm}`,
`deterministic_tool_seconds.deadcode_{go,python,jvm}`, `llm_token_count: 0`
(deterministic). The `gap_count_before_dedup` / `gap_count_after_dedup` fields are
E104-S1-owned and are NOT touched here.

## Binary supply-chain pinning (AC-X4 / NFR-86) — DEFERRED

Per the Trivy March 2026 supply-chain compromise precedent (Microsoft IR + Aqua
Security + CrowdStrike triple-source), the `deadcode`, `vulture`, and `spotbugs`
binaries SHOULD be version-pinned via checksum verification in the CI image.

**Status: deferred.** This repo has no CI-image build / dependency-pinning workflow
to pin against today (`gaia-framework/.github/workflows/` carries only `adr-048-guard`,
`commitlint`, `plugin-ci`, `release`). The pinning is a shared infra gap also
tracked by E70-S7 (grype/cdxgen) and E104-S4 (SARIF Multitool) — see those stories'
Findings. It lands when the brownfield CI-image build step is built as a dedicated
infra story. The adapters themselves are toolchain-agnostic and degrade gracefully
when a binary is absent, so the deferral does not block the verifiable adapter core.

## Tests

- `tests/adapters/dead-code-go.bats`, `dead-code-python.bats`, `dead-code-jvm.bats`
  — per-adapter (qualifier shape, SARIF emission, graceful degrade, flag gating,
  resolver wiring). Toolchains mocked via stub binaries on `PATH`.
- `tests/dead-code-join.bats` — multi-stack integration: all three adapters against
  one polyglot fixture, universal `file_path` JOIN, three SARIF inputs, and the
  unified-three-sub-section render (with the synthesized-confidence anti-pattern guard).
- Fixtures: `tests/fixtures/dead-code-{go,python,jvm,multi-stack}/` (engineered
  sources + pre-captured tool output).
