---
name: gaia-publish
description: Phase 5 action command for non-deployable (distribution-only / branch-only) projects. Runs the canonical five-step orchestrator — pre-publish gate, manifest version check, trigger publish, post-publish verify, final verdict — with no auto-retry, no auto-rollback. Use when "publish this version" or /gaia-publish.
argument-hint: "--version <semver> [--dry-run] [--skip-verify] [--strict-builtin]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are running the Phase 5 publish action for a non-deployable project. The skill mirrors `/gaia-deploy` semantics — sequential, transparent, no auto-retry, no auto-rollback — but targets `distribution.channel` adapters instead of deploy adapters. The orchestrator is the canonical five-step sequential flow. This command is the recommended Phase 5 action for projects whose detector token is `publish-primary` or `deploy-and-publish` (see `gaia-help` SKILL.md).

## Relationship to `distribution.release_workflow` (which mechanism ships the artifact?)

Two publish mechanisms can coexist; this section defines which is canonical so an operator following the docs is never surprised by "the release was driven by something other than `/gaia-publish`."

- **When `distribution.release_workflow` is set** (e.g. `release.yml`) AND the channel is a path-based marketplace where the workflow itself cuts the tag + GitHub Release on the merged `chore(release): vX.Y.Z` commit: **the `release_workflow` IS the publish.** It is triggered by the human-merged release PR, not by this skill. In that configuration, `/gaia-publish`'s role is to **await and verify** that workflow's outcome — Step 3 (trigger) confirms/awaits the `release_workflow` run rather than dispatching a `distribution.channel` adapter, and Steps 4-5 perform the post-publish registry probe + verdict against the published tag/Release. `/gaia-publish` does NOT open or merge the release PR (the Actions-token PR-create restriction means a human or a `RELEASE_PAT` opens it — see the release workflow's job summary).
- **When `distribution.release_workflow` is unset** (a direct registry channel such as `npm`, `pypi`, `app-store-connect`): `/gaia-publish` Step 3 dispatches the `distribution.channel` adapter directly — this is the original five-step flow.

`/gaia-help` routes branch-only + `release_workflow` projects with this contract in mind: the auto path is `release.yml` (merge the release PR → tag + Release), and `/gaia-publish` is the post-hoc verify/verdict gate, not a second, competing publish trigger. Never drive both as independent publishers of the same version.

## Critical Rules

- The five-step order is **non-negotiable**: (1) pre-publish gate → (2) manifest version check → (3) trigger publish → (4) post-publish verify → (5) final verdict. No reordering, no step skipping (except `--dry-run` and `--skip-verify` per the documented opt-out).
- No auto-retry. No auto-rollback. Recovery is user-initiated. A FAILED step records the failure in the assessment doc and HALTs the remaining gating steps.
- The orchestrator script at `${CLAUDE_PLUGIN_ROOT}/skills/gaia-publish/scripts/gaia-publish.sh` is the deterministic single source of truth for the flow control + step bookkeeping. The SKILL.md prose surfaces user-facing concepts; the script enforces the contract.
- `distribution.channel`, `distribution.manifest`, `distribution.registry`, `distribution.release_workflow` are consumed via the schema (no re-implemented config parsing). `environments[].kind` is consumed via the resolver.
- The skill is gated against deployable-only projects at the routing layer (`/gaia-help` recommends `/gaia-publish` only when the detector token is `publish-primary` or `deploy-and-publish`). When invoked directly on a deploy-only project, the orchestrator still runs (no gate inside the script — that gate belongs to `/gaia-help`), but the assessment doc will note the mismatch.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## CLI Flags

| Flag | Required | Description |
|---|---|---|
| `--version <semver>` | yes | The version to publish. Must match the version in `distribution.manifest` (step 2 check). Leading `v` is stripped before comparison. |
| `--dry-run` | no | Exit cleanly after step 3 with steps 4-5 SKIPPED + the "dry-run mode — verify/post-publish skipped" marker. Adapter dispatch (step 3) runs in DRY-RUN mode — no actual publish. Audit-trail records the dry-run. |
| `--skip-verify` | no | Bypass step 4 (post-publish registry probe) with a WARNING. Use sparingly — the registry probe catches publish failures that would otherwise surface only when downstream consumers try to fetch. |
| `--strict-builtin` | no | Refuse custom-adapter shadows for sensitive channels. Forces the built-in adapter even when a `.gaia/custom/adapters/publish-{channel}/` directory shadows it. Default-sensitive list: `npm, pypi, app-store-connect, play-console, marketplace`. Operators can pin a project-specific list via `publish.strict_builtin_channels:` in project-config.yaml (forwarded to the resolver via `--strict-sensitive`). |

## Custom adapter discovery + shadowing

Custom adapters at `<project-root>/.gaia/custom/adapters/publish-<adapter_name>/` shadow built-in adapters at `<plugin-root>/scripts/adapters/publish-<channel>/` per the precedence rules. The `scripts/lib/resolve-publish-adapter.sh` helper implements the discovery + containment + warning flow:

- **Discovery:** filesystem scan of `.gaia/custom/adapters/publish-<adapter_name>/run.sh` (no registration file — the filesystem IS the registry).
- **Path-traversal mitigation:** `adapter_name` MUST match regex `^[a-z0-9-]{1,64}$` (no slashes, no dots, no uppercase). Schema rejects violations at `/gaia-config-validate` time. Resolver re-checks at runtime. Post-resolution canonicalization via `realpath` ensures the resolved path is inside `.gaia/custom/adapters/`.
- **Shadow warning:** when a custom adapter shadows a built-in, the resolver emits the canonical stderr line `WARN: custom adapter at .gaia/custom/adapters/publish-<channel>/ shadows built-in adapter`. This is the SOLE shadow-surfacing message; downstream skills MUST NOT emit alternative variants.
- **`--strict-builtin` HALT:** when `--strict-builtin` is passed AND the resolved channel is in the sensitive list, the resolver exits 3 with `HALT: --strict-builtin refuses custom shadow for sensitive channel`.

### Trust model

Custom adapters execute with publish-time credentials — by design under the precedence rules. This is a deliberate trade-off:

- **(a) Credential-exfiltration risk:** A malicious custom adapter under `.gaia/custom/adapters/publish-npm/` could exfiltrate the operator's `NPM_TOKEN` at the moment `/gaia-publish --version v1.0.0` runs.
- **(b) `--strict-builtin` is the opt-out** for risk-averse operators on sensitive channels.
- **(c) CODEOWNERS recommendation:** extend the CODEOWNERS pattern to `.gaia/custom/adapters/publish-*/` for sensitive-channel custom shadows so review is required before any change to the shadow adapter lands.
- **(d) Defense-in-depth:** the bats credential-isolation audit extends to custom adapters as a structural control (proves no shell read of `~/.npmrc`, `~/.pypirc`, etc.).

## Five-step orchestration (canonical order)

### Step 1 — Pre-publish gate
Verify all required `ci_cd.promotion_chain[].ci_checks` are green on the source branch. Implementation:

1. Resolve source branch — git HEAD if HEAD matches any `promotion_chain[].branch`, else the first chain entry (typically `staging`).
2. Read required checks from `ci_cd.promotion_chain[<resolved-entry>].ci_checks[]`.
3. Probe `gh run list --branch <src> --limit 50 --json status,conclusion,name,headSha` (single invocation).
4. For each required check, find the most-recent run; verify `status: completed` AND `conclusion: success`. Anything else (`failure`, `cancelled`, `null`, missing entry) FAILs the gate.
5. **Failure mode:** stderr names red checks, the source branch, the HEAD commit SHA, and the remediation hint "re-run after CI is green". The assessment doc records `reason: pre-publish-gate-failed`. Steps 2-5 are SKIPPED — no adapter trigger.

Backward-compat: when no `ci_cd.promotion_chain[].ci_checks` is configured, step 1 emits PASSED with the `stub-fallback` marker so projects that haven't wired CI checks yet still progress.

### Step 2 — Manifest version check
Read the path named by `distribution.manifest` (e.g., `plugin.json`, `package.json`, `pyproject.toml`, `Cargo.toml`, `pom.xml`), parse the version field, and confirm it matches the `--version` argument. Leading `v` is stripped on both sides for comparison only — reporting retains the operator's raw value.

**Failure mode:** stderr emits the verbatim "manifest version <X> does not match --version <Y>" line — raw manifest value on the left, raw `--version` (including leading `v`) on the right. The assessment doc records `reason: manifest-version-mismatch`. Steps 3-5 are SKIPPED — no adapter trigger.

### Step 3 — Trigger publish
Resolve and dispatch the adapter per `distribution.channel`. The adapter contract is fully defined in `plugins/gaia/scripts/adapters/PUBLISH-CONTRACT.md`. Adapter binary discovery: `${CLAUDE_PLUGIN_ROOT}/scripts/adapters/publish-<channel>/run.sh` first, then PATH-namespaced `gaia-adapter-publish-<channel>` as fallback.

Under `--dry-run`, the adapter is dispatched in DRY-RUN mode — the adapter returns the would-have-published payload without actually invoking the registry. The orchestrator then SKIPs steps 4-5.

### Step 4 — Post-publish verify (MANDATORY by default)
Invoke the adapter's `verify` action against the registry. The orchestrator:

1. Reads `verify_retry_window_seconds` from `adapter-manifest.yaml` (custom adapter under `.gaia/custom/adapters/publish-<channel>/` takes precedence over plugin built-in). The window is per-adapter — the orchestrator NEVER imposes its own retry policy.
2. Applies the defensive cap: if the declared window exceeds 3600s, clamps to 3600s and logs a WARNING. Mitigates local DoS via a malicious manifest declaring e.g. 86400s.
3. Resolves the adapter binary: `${CLAUDE_PLUGIN_ROOT}/adapters/publish-<channel>/adapter` first, then PATH-namespaced `gaia-adapter-publish-<channel>` as fallback. Never raw PATH lookup.
4. Polls in an exponential back-off loop (start 1s, double, cap 30s per iteration) bounded by the window. Each iteration re-invokes the adapter with `--action verify --version <V> --registry <R> --manifest <M> --output <findings.json>`. The orchestrator validates the envelope shape via `scripts/lib/validate-adr037-envelope.sh` BEFORE reading `verdict`. Three failure modes are distinct (see PUBLISH-CONTRACT.md "Exit-code discipline"):
   - `adapter-internal-failure` — adapter exits non-zero BEFORE writing findings.json.
   - `envelope-schema-violation` — findings written but malformed (missing `verdict`, outside enum, etc.). Stderr names the JSONPath.
   - `verdict-failed` — well-formed envelope with `verdict: FAILED`. Adapter `summary` surfaces in the assessment doc under "Publish Adapter Findings".
5. **PASSED** → step 4 PASSED, proceed. **UNVERIFIED** (the `null` sentinel reserved for `mobile-app`) → step 4 PASSED with human-review note. **FAILED throughout** → step 4 FAILED with stderr naming the exhausted window + last verdict + adapter summary; audit reason `post-publish-verify-failed`.

Backward-compat: when no `adapter-manifest.yaml` AND no adapter binary are resolvable, step 4 emits PASSED with `stub-fallback` marker (preserves the happy path for projects that have not wired adapters yet).

**Bypassed under `--skip-verify` (opt-out)** with a documented WARNING surfaced to stderr ("MANDATORY post-publish registry probe bypassed; only documented use case is unbounded-lag registries"). The assessment doc records `verify-skipped: yes`. The `--skip-verify` flag is opt-in only — never the default.

Bypassed under `--dry-run` (SKIPPED with the dry-run marker).

### Step 5 — Final verdict
Emit the assessment doc to `.gaia/artifacts/implementation-artifacts/assessment-publish-{channel}-{timestamp}.md` (fallback to legacy `docs/implementation-artifacts/` on older projects). The doc records per-step status + detail + the configuration snapshot. The orchestrator's exit code reflects the verdict (0 = PASSED or DRY_RUN; 1 = FAILED).

## Steps

### Step 1 — Resolve project config + arguments

- Resolve `${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo` to determine whether interactive prompts auto-confirm.
- Resolve `project-config.yaml` via the canonical `${CLAUDE_PROJECT_ROOT}/.gaia/config/project-config.yaml` path (or `PROJECT_CONFIG` env override).
- Parse the user's `--version` + flag args. If `--version` is missing, HALT with the canonical usage message.

### Step 2 — Validate the config-shape gate (advisory)

- Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/config-shape-detect.sh` and call `gaia_config_shape_detect <config>`.
- When the detector returns `deploy-only` (no `distribution:` block), surface a warning: "this project has no `distribution:` block — `/gaia-publish` requires one. Run `/gaia-config-distribution add` first."
- Otherwise (publish-primary / deploy-and-publish / unknown), proceed.

### Step 3 — Dispatch the five-step orchestrator script

Run `${CLAUDE_PLUGIN_ROOT}/skills/gaia-publish/scripts/gaia-publish.sh --version <version> [flags...]`. Forward all user-supplied flags verbatim. Capture stdout (per-step progress markers + assessment-doc path) and the exit code.

### Step 4 — Surface the verdict

- Re-emit each per-step marker line from the script's stdout to the user.
- On exit 0 (PASSED or DRY_RUN): report success + the assessment-doc path.
- On exit 1 (FAILED): report which step(s) failed (from the assessment doc), point the user at the per-channel adapter's troubleshooting section, and remind them recovery is user-initiated (no auto-retry, no auto-rollback).

### Step 5 — Reconciliation hint

After a successful publish, suggest the user run `/gaia-sprint-status` to refresh the sprint dashboard with the new release marker (if the publish corresponds to a sprint deliverable).

## References

- `/gaia-publish` five-step canonical orchestrator.
- Publish adapter contract.
- Closed 10-channel registry consumed via `distribution.channel`.
- `/gaia-help` Phase 5 routing that recommends `/gaia-publish` based on the config-shape detector token.
- `--skip-verify` opt-out path documentation.
- `--strict-builtin` defense against malicious custom-adapter shadows for sensitive channels.
- Atomic file writes (assessment doc).
- YOLO mode contract.
