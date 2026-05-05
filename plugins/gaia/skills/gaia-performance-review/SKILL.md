---
name: gaia-perf-deepdive
description: Run anytime performance bottleneck analysis on a story — N+1 queries, memory/bundle impact, caching, and algorithmic complexity. Emits a machine-readable PASSED/FAILED verdict and updates the Review Gate. Use when "performance review" or /gaia-perf-deepdive (formerly /gaia-performance-review).
argument-hint: "[story-key]"
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
deprecated_aliases: [gaia-performance-review]
deprecated_since: sprint-37
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-performance-review/scripts/setup.sh

## Mission

**Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.**

This is the unifying principle of every GAIA review skill (FR-DEJ-1, ADR-075). For `gaia-performance-review` it means: deterministic tools (per-stack ORM-pattern N+1 detector, complexity analyzer, static bundle/memory budget checks) run first and emit a structured `analysis-results.json` artifact. The LLM then performs a semantic review **on top of** that artifact — it cannot disregard a high-confidence N+1 finding inside a hot-path loop, and it cannot relabel a tool failure as APPROVE. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill pattern-matches against `gaia-code-review` (E65-S2) as the canonical reference. Per-skill specialization here = (a) the performance toolkit (N+1 query detection + cyclomatic/cognitive complexity + bundle/memory budget checks) and (b) the performance-specific severity rubric examples (hot-path I/O, N+1, memory growth, complexity). Structural plumbing — fork dispatch, cache key, parent-mediated write — is identical to E65-S2.

**NFR-DEJ-1 budget pressure is highest among siblings.** Per-tool wall-clock caps are mandatory: N+1 ≤15s, complexity ≤15s, bundle ≤30s, memory pattern ≤10s (cumulative ≤60s P95 cold). On individual tool timeout, status=`errored` for that tool only — overall verdict resolves via remaining tools + LLM. See Phase 3A.

**Fork context semantics (ADR-041, ADR-045, NFR-DEJ-4):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify files — the tool allowlist enforces no-write isolation. Persistence of the rendered review report is parent-mediated (Option A per ADR-075): the fork returns the rendered report payload to the parent context, and the parent writes the file. `Write` and `Edit` are NEVER added to the fork allowlist.

**Runtime profiling is out-of-scope (EC-4, EC-5).** Lighthouse perf-budget checks need a browser; Go heap analysis (`pprof`) and the heap profiler are out-of-scope because they require running the binary. Both are forbidden by the read-only allowlist. The toolkit instead parses static budget configs (`lighthouserc.json`, `bundlesize` in `package.json`, etc.) and consumes cached results from `.lighthouseci/` or `pprof/` when present. This is a documented scope boundary, not an oversight.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-perf-deepdive [story-key]".
- The story file MUST exist at `docs/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug. If zero matches, fail with "story file not found for key {story_key}".
- The story MUST be in `review` status. If not, fail with "story must be in review status before performance review".
- This skill is READ-ONLY in the fork. Do NOT attempt to call Write or Edit — the allowlist enforces this. Persistence is routed through the parent context.
- The verdict is `verdict-resolver.sh`'s output (APPROVE | REQUEST_CHANGES | BLOCKED). The LLM MUST NOT compute or override it.
- Mapping to Review Gate canonical vocabulary (inline, no separate script): APPROVE → PASSED; REQUEST_CHANGES → FAILED; BLOCKED → FAILED.
- Determinism settings: `temperature: 0`, `model: claude-opus-4-7` (per ADR-074), `prompt_hash` recorded in the report header. Re-running with identical `analysis-results.json` MUST yield findings that match by category and severity (NFR-DEJ-2); textual variation is allowed.
- **Percentiles, not averages:** when citing performance measurements, use P50/P95/P99 percentiles. Never cite arithmetic means for latency or throughput — percentiles surface tail behavior.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Determinism Settings

```
temperature: 0
model: claude-opus-4-7        # per ADR-074, frontmatter-pinned at fork dispatch
prompt_hash: sha256:<hex>     # recorded in report header at Phase 6
```

`prompt_hash` is the sha256 of (system prompt || `analysis-results.json` content). Two runs against unchanged inputs MUST produce findings that match by `{category, severity}` (NFR-DEJ-2). Textual message variation is allowed; category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch.

## Stack Toolkit Table

The toolkit invoked by Phase 3A is selected by the canonical stack name emitted by `load-stack-persona.sh`. Stack-key vocabulary is canonical across this skill and the script — they MUST match (EC-9). Performance signals split into four sub-toolkits per stack: ORM-pattern matcher (N+1 detection), complexity analyzer, bundle analyzer, and memory-pattern scanner. The blocking-sync-I/O patterns are stack-specific and tabulated alongside.

| Stack key (canonical) | N+1 ORM patterns                                          | Complexity tool                | Bundle/budget tool                              | Memory pattern scan                     | Blocking sync I/O patterns                 |
|-----------------------|-----------------------------------------------------------|--------------------------------|-------------------------------------------------|-----------------------------------------|--------------------------------------------|
| `ts-dev`              | Prisma `prisma.x.findMany` inside loop; TypeORM repo calls | `eslint-plugin-sonarjs` / `eslint-plugin-complexity` | `bundlesize` / `webpack-bundle-analyzer --json` / `lighthouserc.json` (static config check) | `arr.push` in unbounded loop; closure DOM-ref retention | `fs.*Sync` (e.g., `fs.readFileSync`); `child_process.execSync`; `requests` sync HTTP libs |
| `java-dev`            | JPA `@OneToMany` lazy fetch inside loop; Hibernate criteria | `PMD` / `Checkstyle`           | `gradle bundle-tool` / static budget config     | unbounded `ArrayList` growth; thread-leak in pool   | `Thread.sleep` in request handler; blocking JDBC sync calls |
| `python-dev`          | SQLAlchemy `relationship()` per-row access; Django without `select_related` / `prefetch_related` | `radon` (cyclomatic + cognitive) | `lighthouserc.json` (if frontend) / static budget config | unbounded list `.append` in loop; closure-retained iterators | `requests.get()` (sync) inside async route; `urllib` blocking; `time.sleep` in async fn |
| `go-dev`              | GORM `db.Model().Association()` inside loop; raw `database/sql` query inside loop (raw-SQL fallback heuristic, EC-1) | `gocyclo`                        | `go-bindata`/static budget config; cached `pprof/` consumption only | goroutine spawn without recv-side close; unbounded slice `append(s, x...)`; unbounded channel buffer (`make(chan T, math.MaxInt32)`) | blocking channel send without `select+default`; sync I/O in goroutine without context |
| `flutter-dev`         | drift / floor ORM patterns inside loop                    | `dart_code_metrics`              | `flutter analyze --no-fatal-warnings`; static bundle config | unbounded `List` growth; stream subscription leaks  | blocking sync `File.readAsStringSync`; `sleep()` in async fn |
| `mobile-dev`          | Core Data `NSFetchRequest` inside loop (iOS); Room `Dao` access in loop (Android) | XCTest perf hints (limited static analysis); Android profiler (limited) | static budget config only                       | NSCache miss patterns; Android Bitmap leaks         | `Thread.sleep` (Android); `dispatch_sync` on main queue (iOS) |
| `angular-dev`         | rxjs subscription per-iteration without `takeUntil`; HTTP `forkJoin` misuse | `eslint-plugin-sonarjs` / `eslint-plugin-complexity` | `bundlesize` / Angular CLI budgets (`angular.json`) / `lighthouserc.json` (static) | unbounded subject growth; subscription leaks       | sync XHR (legacy); blocking template expressions |

The table is authoritative for Phase 3A toolkit selection. Phase 3A scope per FR-DEJ-3 is **strict**: N+1 query detection + complexity analysis + static bundle/memory budget checks. Phase 3A does NOT invoke linters, formatters, type checkers (those belong to `gaia-code-review`), Semgrep / secret scan / dep audit (those belong to `gaia-security-review`), or test runners (those belong to `gaia-qa-tests` / `gaia-test-automate`).

**Raw-SQL fallback (EC-1).** Projects without a recognised ORM (e.g., Go using `database/sql` directly, Python using `psycopg2` raw cursor) trigger the raw-SQL fallback heuristic: detector flags any function-call-inside-loop pattern where the call signature suggests a query (`db.Query`, `db.Exec`, `cursor.execute`). Raw-SQL findings carry lower confidence and Phase 3B classifies them at Suggestion-tier unless the loop bound is statically large.

**Mismatched stack name** (vocabulary drift between `load-stack-persona.sh` output and the table key) → silent skip on tool selection per FR-DEJ-4 case 3 with `skip_reason` populated.

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The LLM Phase 3B review applies the rubric below. Findings are organized by performance category (`n+1`, `complexity`, `bundle`, `memory`, `blocking-io`, `index-hint`). The category+severity sets MUST match across two runs of identical inputs (NFR-DEJ-2 determinism contract); textual message variation is allowed. Category+severity divergence escalates as a model-pin or temperature regression.

### Critical

> Blocking. Produces `REQUEST_CHANGES` if the deterministic resolver did not already block. Critical-promotion threshold for N+1: detector confidence high AND the call is inside an unbounded loop on a hot path (path matches `*/api/*`, `*/handlers/*`, `*/routes/*`, `*/resolvers/*`, `*/render*`, or `*/components/*` per EC-8 hot-path heuristic).

Examples (per category):

- **n+1** — Prisma `prisma.posts.findMany` inside `for (const u of users) { await ... }` on `src/api/users.ts` (HTTP handler — hot path). Canonical N+1 pattern (EC-6); detector flags ORM call inside any loop construct.
- **n+1** — JPA `@OneToMany` lazy fetch dereferenced inside a request-handler `for` loop on `src/handlers/OrderController.java` — N+1 fan-out to the order_items table per-iteration.
- **blocking-io** — `fs.readFileSync('/etc/config.json')` inside `src/api/handler.ts` HTTP handler — blocks the Node event loop on hot path (EC-10).
- **blocking-io** — `requests.get(...)` (sync) called inside `async def handler(...)` on `src/routes/payment.py` — blocks the asyncio event loop on hot path (EC-10).
- **memory** — Unbounded `arr.push(item)` in a streaming loop without bound check, on a request-handler hot path — drives RSS to OOM territory under sustained load.

### Warning

> Non-blocking but worth surfacing. Persisted to the report.

Examples (per category):

- **complexity** — Function `processOrders()` exceeds the team cyclomatic complexity threshold by >5x (radon C-rank) in non-hot-path code (EC-3). High complexity is flagged; recursive single-call functions are exempt and downgrade to Suggestion.
- **index-hint** — Missing index hint: Prisma `prisma.user.findMany({ where: { email: someEmail } })` against a `User` schema where `email` has no `@unique` or `@@index` decorator (EC-12). Schema-gated: only flagged when schema files are present in the File List.
- **bundle** — Large dep import: `import _ from 'lodash'` (full library, ~70KB minified) where `import { debounce } from 'lodash-es'` would suffice. Threshold breach >30KB minified delta per EC-13.
- **blocking-io** — `Thread.sleep(1000)` in a non-hot-path background worker (cron-only) — blocking sync I/O off hot path is Warning-tier per EC-8 hot-path differential.
- **memory** — Unbounded `arr.push(x)` inside a non-hot-path scheduled job loop without bound check (EC-11). Bounded growth idiom (`push` followed by length check + `shift`, or LRU/circular-buffer wrapper) downgrades to Suggestion.

### Suggestion

> Non-blocking. Style/comment polish; no behavior implications. Includes context-aware downgrades.

Examples (per category):

- **complexity** — Recursive function with high cyclomatic complexity, but the recursion site is single-call and traversal is mechanically clear (parsing AST, walking JSON tree). EC-3 recursive-exemption: classified Suggestion, not Warning.
- **n+1** — Known-small-collection iteration with ORM call: `for (const role of ['admin', 'user', 'guest']) { await db.role.find({where: {name: role}}); }` — only 3 iterations (EC-7). LLM Phase 3B downgrades to Suggestion when the collection bound is statically provable as small (literal array <10 items, enum iteration, fixed-size const).
- **bundle** — Missing perf budget config (no `bundlesize` config in `package.json`, no `lighthouserc.json`). Cannot enforce a budget that does not exist — flagged for cleanup, not blocking (EC-4).
- **memory** — Bounded `arr.push(x); if (arr.length > MAX) arr.shift();` — push followed by length check + shift idiom (EC-11). Detector AST-aware enough to recognize bounded-growth pattern; LLM downgrades when bound is present.
- **n+1** — Raw-SQL fallback finding without large-N evidence: `for ... { db.Query(...) }` in a Go file using `database/sql` directly (EC-1). Lower confidence than ORM-detected N+1; statically-bounded loops downgrade further.

**Context-aware downgrade rules (rubric-driven):**
- Hot-path classification (EC-8) drives Critical-vs-Warning split for I/O findings — same finding in `*/api/*` is Critical; same finding in `*/cron/*`, `*/scripts/*`, `*/migrations/*` is Warning.
- Bound-analysis (EC-7, EC-11) drives N+1 and memory downgrades — provable-small-N or bounded growth idiom downgrades to Suggestion.
- Absent bundle data (EC-2 timeout, EC-4 no cached results) caps Critical promotion — LLM Phase 3B treats absent bundle data as Suggestion-tier (cannot promote to Critical without evidence).
- Recursive-function exemption (EC-3): single self-call recursion with clear traversal pattern downgrades to Suggestion even when cyclomatic complexity is high.

LLM-cannot-override invariant: a high-confidence deterministic finding cannot be downgraded by the LLM into APPROVE territory. The rubric downgrades above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output + Gate Update → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable.

### Phase 1 — Setup

- If no story key was provided as an argument, fail with: "usage: /gaia-perf-deepdive [story-key]"
- Resolve the story file path using the canonical glob: `docs/implementation-artifacts/{story_key}-*.md`. If zero matches: fail. If multiple matches: fail with "multiple story files matched key {story_key}".
- Read the resolved story file; parse YAML frontmatter to extract `status` and `figma:` block (if any).
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name (`ts-dev`, `java-dev`, `python-dev`, `go-dev`, `flutter-dev`, `mobile-dev`, `angular-dev`) and lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch (NFR-DEJ-4 preserved). Forward the persona payload + canonical stack name into the fork.
- **Tool prereq probe.** For each tool listed in the stack-toolkit table row matched by the canonical stack name (complexity tool, bundle tool, ORM-pattern matcher, memory-pattern scanner): probe via `command -v <tool>` first; fall back to `node_modules/.bin/<tool> --version` (TS/Angular). NEVER use `npx <tool> --version` (triggers npm install and breaks the NFR-DEJ-1 60s P95 budget). Cap each probe at 5s wall-clock; on timeout, log a Warning and continue (assume tool present). Capture each tool's reported version into `tool_versions` for the cache key. Probe for cached perf data: presence of `.lighthouseci/` (Lighthouse JSON output) and `pprof/` (Go heap profiles).
- **Per-tool wall-clock caps (EC-14):** N+1 detection ≤15s, complexity ≤15s, bundle ≤30s, memory pattern scan ≤10s. Cumulative Phase 3A budget ≤60s P95 cold (NFR-DEJ-1). On individual tool timeout, that tool's `status: errored` (NOT `failed` — timeout is not a finding); resolver maps to BLOCKED for that tool only. The cap is enforced via bash `timeout 15s <cmd>` per tool invocation.
- **Expected-missing-tool (FR-DEJ-4 case 1).** If a required toolkit binary is absent and not optional for the stack (e.g., no complexity tool installed for `ts-dev` when File List has `*.ts`): emit Phase 1 BLOCKED with an actionable error message naming the missing tool and the install hint. Do NOT dispatch the fork. For non-critical tool absence (e.g., no `dart_code_metrics` on a Flutter project), emit `status: skipped` with `skip_reason` populated and continue.

### Phase 2 — Story Gate

- Status check: if `status` is not `review`, fail with "story {story_key} is in '{status}' status — must be in 'review' status for performance review".
- Extract the File List section under "Dev Agent Record".
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path> --base <branch> --repo <repo>`. The script returns a JSON-shaped report; surface divergence as a Warning to the user. **Story Gate semantics are advisory per FR-DEJ-2 — divergence does NOT halt the review.** Honor `no-file-list`, `empty-file-list`, and `divergence` reasons.
- Record divergence findings in `gate_warnings[]` of the eventual `analysis-results.json`.
- Missing-file handling: if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`. Do NOT crash; Phase 3A handles it gracefully.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` written to `.review/gaia-performance-review/{story_key}/analysis-results.json` validating against `plugins/gaia/schemas/analysis-results.schema.json` (`schema_version: "1.0"`).

**Toolkit invocation.** Look up the toolkit row in the Stack Toolkit Table above using the canonical stack name from Phase 1. Run the four sub-toolkits in this order:

1. **N+1 detection (per-stack ORM AST patterns).** Pattern-match per-stack ORM call signatures inside any loop construct (`for`, `while`, `forEach`, `map`, async iteration). TS/Prisma `prisma.x.findMany`, Java/JPA `@OneToMany`, Python/SQLAlchemy `relationship()` / Django without `select_related`, Go/GORM `db.Model().Association()`. Raw-SQL projects fall back to the generic 'query call inside loop' heuristic with lower confidence (EC-1). Wall-clock cap: 15s.
2. **Complexity analysis (per-stack tool).** Invoke the per-stack complexity tool from the table (eslint-plugin-sonarjs, radon, gocyclo, PMD/Checkstyle, dart_code_metrics). Parse output. Tag recursive-function exemption in metadata for LLM context (EC-3) — flag functions with single-call recursion so Phase 3B can downgrade. Wall-clock cap: 15s.
3. **Bundle analysis (cache-first).** Parse the static bundle/budget config (`lighthouserc.json`, `bundlesize` in `package.json`, Angular `budgets`). On cache miss, run the bundle tool with a 30s timeout (EC-2); on timeout, status=`skipped` with `skip_reason='bundle analysis exceeded 30s timeout'` — not blocking. Consume cached `.lighthouseci/` JSON if present (EC-4); Lighthouse runtime itself is OUT of fork-context scope. Wall-clock cap: 30s.
4. **Memory pattern scan.** Static patterns for unbounded growth (`arr.push` in unbounded loop without bound check, EC-11), goroutine leaks (goroutine spawn without recv-side close, EC-5), unbounded channel buffers (`make(chan T, math.MaxInt32)`, EC-5). Bounded-growth idiom recognition: `push` followed by length check + `shift`, or LRU/circular-buffer wrapper — flagged with `bounded: true` metadata for LLM downgrade. Wall-clock cap: 10s.

After the four core sub-toolkits, two annotation passes run:

- **Hot-path tagging (EC-8).** Mark each finding with `hot_path: true|false` based on path heuristics. Hot paths: paths matching `*/api/*`, `*/handlers/*`, `*/routes/*`, `*/resolvers/*` (HTTP/GraphQL handlers); `*/render*`, `*/components/*` (frontend critical render). Cold paths: `*/cron/*`, `*/scripts/*`, `*/migrations/*`. LLM Phase 3B uses the `hot_path` tag to drive Critical-vs-Warning split for I/O findings.
- **Index-hint analysis (EC-12).** If schema files (`prisma.schema`, Django `models.py`, JPA `*.entity.ts`, Go struct tags `*.go`) are present in the File List, parse `@index` / `@unique` / `Index` decorators / lines. Query-finding records include a `has_index: bool` field. If schema files absent, status=`skipped` with `skip_reason='no schema files in scope'`. LLM Phase 3B classifies missing-index findings.

**Status taxonomy (FR-DEJ-4).** Each tool invocation produces exactly one of:
- `status: passed` — tool ran to completion, no findings, exit code zero.
- `status: failed` — tool ran to completion AND emitted findings (e.g., N+1 detector found ORM call inside loop; complexity tool reported function exceeding threshold). Maps to REQUEST_CHANGES via verdict-resolver precedence rule 2 (LLM-cannot-override).
- `status: errored` — tool crashed mid-run, returned an unclassified non-zero exit code, OR exceeded its wall-clock cap (EC-14). Maps to BLOCKED via precedence rule 1. Examples: complexity-tool parse error on malformed source; bundle tool timeout (>30s); per-tool wall-clock timeout. Even when partial findings were emitted before the crash, `errored` wins over partial findings.
- `status: skipped` — tool not applicable; `skip_reason` populated verbatim. Examples: `skip_reason='bundle analysis exceeded 30s timeout'` (EC-2); `skip_reason='no schema files in scope'` (EC-12); `skip_reason='no complexity tool installed for {stack}'` (EC-9 case 3).

**Distinguish `failed` vs `errored` by exit-code semantics, not by exit code alone** (consistent with E65-S2 EC-6). The bats fixtures assert the EXACT `status` field, not the exit code.

**Per-tool timeout enforcement (EC-14).** Each sub-toolkit is wrapped in `timeout <cap>s <cmd>`. On individual tool timeout, that tool's status=`errored` only — the other tools continue. Cumulative budget enforcement: if combined wall-clock exceeds 60s P95 cold, escalate as a regression signal but do not blanket-fail. Cache hit ≤3s P95 still required.

**Cache plumbing (FR-DEJ-11).** Cache lives at `.review/gaia-performance-review/{story_key}/.cache/`. Cache directory created via `mkdir -p` (idempotent and concurrency-safe).

Cache key:
```
sha256(
  File List contents
  || file_hashes (sha256 per File List entry, sorted)
  || tool_config blob
  || tool_versions (sorted "tool:version" lines)
  || resolved_config_hash
  || bundle_config_hash
  || schema_hash
)
```

`bundle_config_hash` is the sha256 of the rendered bundle/budget config (`lighthouserc.json` + `bundlesize` block + Angular `budgets` if present). `schema_hash` is the sha256 of all schema files in the File List (`prisma.schema`, Django `models.py`, JPA entity files, Go struct-tag files). Both are EC-12 / EC-2 mitigations: bundle-analyzer config or schema changes must invalidate the cache (similar to E65-S3's `advisory_db_fingerprint` pattern). Without these fingerprints, a story marked safe yesterday can have new perf-budget violations or new missing-index findings today and the cache would return a stale safe verdict.

`resolved_config_hash` is the sha256 of the rendered complexity-tool configuration (e.g., `eslint --print-config <file>` output for ESLint-based complexity rules) — NOT the raw config file content.

Cache lookup:
1. Compute the candidate cache key from current File List + tool versions + resolved configs + bundle_config_hash + schema_hash.
2. Look up `.review/gaia-performance-review/{story_key}/.cache/{cache_key}.json`. On miss: run tools.
3. On candidate hit, **revalidate file_hashes** against current on-disk file hashes. A file in the File List can be edited externally without changing any cache-key input — if any cached `file_hashes` entry diverges from the current on-disk hash, treat as miss.

Cache write (same-story parallel-invocation safety):
- Write `analysis-results.json` to a per-PID temp path: `.review/gaia-performance-review/{story_key}/.cache/.tmp.<pid>.<timestamp>.json`.
- `mv` (atomic rename) to the final `.cache/{cache_key}.json` path. Atomic rename gives last-writer-wins without corruption.
- Cross-story parallel invocations are safe by per-story directory partitioning.
- Persist via `${CLAUDE_PLUGIN_ROOT}/scripts/checkpoint.sh write --workflow performance-review --step 3 --file <results.json> --var cache_key=<hash>` so `checkpoint.sh validate --workflow performance-review` can detect drift later.

Phase 3A also emits a rendered `.md` companion alongside `analysis-results.json` — a human-readable summary of per-tool status and findings count for log inspection.

### Phase 3B — LLM Semantic Review

Phase 3B is the **judgment layer**. The fork subagent reads `analysis-results.json` as evidence and applies the performance-specific severity rubric to produce category-organized Critical / Warning / Suggestion findings.

**Fork dispatch contract.**
- `context: fork`
- `allowed-tools: [Read, Grep, Glob, Bash]` (frontmatter-enforced; no Write/Edit ever)
- `model: claude-opus-4-7` (frontmatter-pinned per ADR-074)
- `temperature: 0`
- Inputs forwarded into the fork: persona payload (from Phase 1), `analysis-results.json` content, story file path, severity rubric (this section), hot-path tags from Phase 3A.

**Output contract.** Fork returns a structured findings JSON with shape `{ "findings": [{"category", "severity", "file", "line", "message", "hot_path?", "bounded?", "has_index?"}, ...] }`. The fork ALSO returns the rendered report payload as its conversational output — the parent will validate the structure in Phase 6 before persisting.

**Performance categorization.** Each finding carries a `category` value from the closed set: `n+1`, `complexity`, `bundle`, `memory`, `blocking-io`, `index-hint`. Findings outside the perf top categories are classified as `category: integrity` for missing-file divergence or `category: fidelity` for design-token drift, consistent with the cross-skill convention.

**Determinism contract (NFR-DEJ-2).** Two runs against unchanged `analysis-results.json` MUST produce findings that match by `{category, severity}`. Textual message variation is allowed. Category+severity divergence is an escalation signal — investigate model pin, temperature, or prompt-hash mismatch. The bats determinism regression test compares ONLY `{category, severity}` sets across two runs.

**Prompt hash recording.** The fork records `prompt_hash` (sha256 of system prompt || `analysis-results.json` content) in the report header. This is the audit trail for determinism debugging.

**Context-aware classification (rubric-driven).** Per the Severity Rubric above:
- Hot-path tag (EC-8) drives Critical-vs-Warning split for I/O findings — `hot_path: true` + blocking sync I/O = Critical; `hot_path: false` + blocking sync I/O = Warning.
- Bound-analysis (EC-7, EC-11) drives N+1 and memory downgrades — `bounded: true` (provable-small-N or push-shift idiom) downgrades to Suggestion.
- Recursive-function exemption (EC-3): single-call recursion with mechanically clear traversal downgrades to Suggestion.
- Absent bundle data (EC-2 timeout, EC-4 no cached results): LLM Phase 3B treats absent bundle data as Suggestion-tier (cannot promote to Critical without evidence).
- N+1 detector confidence high AND `hot_path: true` AND loop bound not provably small → promote to Critical (EC-6 canonical N+1).

LLM-cannot-override invariant: a high-confidence deterministic finding cannot be downgraded by the LLM into APPROVE territory. The rubric downgrades above apply to LLM tier classification (Suggestion vs Warning vs Critical) — NOT to the verdict-resolver.sh blocking decision when the deterministic tool emits `status: failed` with a blocking finding.

**Percentile extraction.** When profiling output, benchmark files, or test artifacts in the changed-file set carry latency / memory / throughput measurements, extract the P50 / P95 / P99 percentile values and quote them in each load-sensitive finding. Never cite arithmetic means in their place — averages mask the tail behaviour the finding is meant to flag.

### Phase 4 — Architecture Conformance + Design Fidelity

The fork extends Phase 3B's findings with architecture and design checks; findings flow into the Phase 3B category buckets.

- **Performance-architecture conformance.** Fork reads `docs/planning-artifacts/architecture.md`. For each File List entry, verify component placement follows the documented hierarchy (e.g., DB-access modules below the handler tier; caching layers as documented), dependency direction matches the architecture, and any ADRs referenced by the story exist with status Accepted. Findings under `category: architecture`.
- **Design fidelity.** If the story frontmatter has a `figma:` block, fork compares design-token references in the changed code against `docs/planning-artifacts/design-system/design-tokens.json` (relevant when bundle-bloat findings touch design-token import paths). Findings under `category: fidelity`. If no `figma:` block: skip silently (no Warning, no finding).

### Phase 5 — Verdict

The verdict is computed by `verdict-resolver.sh`. The LLM never computes or overrides it.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verdict-resolver.sh \
  --analysis-results .review/gaia-performance-review/{story_key}/analysis-results.json \
  --llm-findings .review/gaia-performance-review/{story_key}/llm-findings.json
```

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
- `## Deterministic Analysis` — per-tool status table + per-tool findings list (from `analysis-results.json`). Includes per-tool wall-clock timings.
- `## LLM Semantic Review` — Critical / Warning / Suggestion organized by performance category (`n+1`, `complexity`, `bundle`, `memory`, `blocking-io`, `index-hint`) plus `architecture`, `fidelity`, and `integrity` non-perf buckets.
- Final line, exactly: `**Verdict: APPROVE**` or `**Verdict: REQUEST_CHANGES**` or `**Verdict: BLOCKED**`.

**Parent payload validation.** Before persisting, the parent context validates the fork output structure:
- `## Deterministic Analysis` section present.
- `## LLM Semantic Review` section present.
- Final line matches regex `^\*\*Verdict: (APPROVE|REQUEST_CHANGES|BLOCKED)\*\*$`.

**Malformed-payload handling.** On any of the above checks failing, the parent persists what it received with an explicit `[INCOMPLETE]` marker prepended to the report, and emits `verdict=BLOCKED` to `review-gate.sh`. Fork output untrustworthy → BLOCKED. The bats fixture covers this case explicitly (mirrors E65-S2 EC-9).

**Parent write to FR-402 locked path.** The parent context writes the rendered report to `docs/implementation-artifacts/performance-review-E<NN>-S<NNN>.md` per FR-402 naming convention. The path is **locked**: `performance-review-{story_key}.md` — no slug, no date suffix.

**Re-run handling.** Parent **overwrites** the existing review file on re-run (latest verdict wins). No append, no version-suffix. The `review-gate.sh` row update is the source of truth for verdict history if needed.

**Gate row update.** Parent invokes the individual gate update (single-line form): `review-gate.sh update --story "{story_key}" --gate "Performance Review" --verdict "{PASSED|FAILED}"`. Equivalent multi-line form for readability:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update \
  --story "{story_key}" \
  --gate "Performance Review" \
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

## References

- ADR-037 — Structured subagent return schema `{status, summary, artifacts, findings, next}`.
- ADR-041 — Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042 — Scripts-over-LLM for Deterministic Operations.
- ADR-045 — Review Gate via Sequential `context: fork` Subagents.
- ADR-054 — Composite Review Gate.
- ADR-063 — Subagent Dispatch Contract — Mandatory Verdict Surfacing.
- ADR-067 — YOLO Mode Contract — Consistent Non-Interactive Behavior.
- ADR-074 — Frontmatter Model Pin for Determinism.
- ADR-075 — Review-Skill Evidence/Judgment Split.
- FR-DEJ-1..12, NFR-DEJ-1..4 — Evidence/Judgment functional and non-functional requirements (PRD §4.37).
- FR-402 — Locked review-file naming convention (`performance-review-{story_key}.md`).
- E65-S2 — canonical reference implementation this skill pattern-matches against.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-performance-review/scripts/finalize.sh
