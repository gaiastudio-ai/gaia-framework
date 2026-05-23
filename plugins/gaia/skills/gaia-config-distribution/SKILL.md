---
name: gaia-config-distribution
description: Section-scoped editor for the `distribution:` block of `project-config.yaml` per FR-523 / ADR-112. Use when "edit distribution config" or /gaia-config-distribution. Comment-preserving per ADR-044. Four operations — `add`, `show`, `clear`, `set` — mirror the /gaia-config-env pattern.
argument-hint: "add | show | clear | set [--channel <c>] [--registry <url>] [--manifest <path>] [--release-workflow <name>] [--force] [other --field <value>]"
allowed-tools: [Read, Grep, Bash, Write, Edit]
orchestration_class: light-procedural
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/scripts/yolo-mode.sh is_yolo >/dev/null 2>&1 || true

## Mission

You are section-editing the top-level `distribution:` block of `project-config.yaml` per FR-523 + ADR-112 §(b). The skill is one of the `/gaia-config-*` family established by E71-S3 — comment-preserving per ADR-044, schema-validated against the E99-S2 closed 10-channel registry, path-canonicalized per E99-S3's SR-79 + SR-80, and gated against all-`deployable` projects per FR-523's `--force` rule.

This skill targets ONLY the `distribution:` section. Other top-level sections (`environments:`, `ci_cd:`, etc.) are invisible to the edit session and untouched.

## Critical Rules

- Only the `distribution:` section may be modified. All other sections, comments, and formatting outside it MUST be preserved byte-for-byte.
- The comment-preserving YAML editor at `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh` is the canonical mutation primitive per ADR-042 / ADR-044. NEVER round-trip the file through `yq -y` or `yaml.dump` — those strip comments.
- Pre-write validation gates (NON-NEGOTIABLE, in order):
  1. **E99-S2 schema validation** — channel must be one of the closed 10-channel enum; the 4 required common fields must be present; per-channel `if/then` allOf sub-fields enforced (mobile-app requires platform+store_id+review_required; container-registry requires image_name+tag_strategy; etc.).
  2. **E99-S3 path canonicalization (SR-79)** — `distribution.manifest` is realpath-canonicalized and string-prefix-checked against the project root; HALT on traversal.
  3. **E99-S3 shell-metachar denylist (SR-80)** — `gaia_distribution_validate_string` rejects any value containing `;`, `&&`, `||`, `|`, backtick, `$(`, `>`, `<`, newline across ALL `distribution.*` string fields.
  4. **E99-S3 URL-shape (SR-80)** — `distribution.registry` MUST match `^https://<host>[/<path>]$`.
- **FR-523 `--force` gate**: when ALL environments[] entries resolve to `kind: deployable` (per E99-S1 resolver), `add` and `set` REFUSE the write without `--force`. The guidance: "distribution typically pairs with `branch-only` or `distribution-only` environments — set at least one environment to non-deployable first, or pass `--force` to override". With `--force`, the write proceeds.
- The `add` op REFUSES when a `distribution:` section already exists (use `set` instead).
- The `set` op REFUSES when no `distribution:` section exists (use `add` instead).
- The `clear` op removes the entire `distribution:` block; surrounding sections + comments preserved byte-identical.
- Edits MUST go through a diff-preview confirmation gate — never write without an explicit user `y` response. In YOLO mode, auto-confirm per ADR-067.

## Sub-commands (per FR-523)

### `add`

Add a fresh `distribution:` block. REFUSES when one already exists.

Required flags (4 canonical common fields per FR-521):
- `--channel <claude-marketplace|npm|pypi|maven|homebrew|github-releases|mobile-app|container-registry|static-site|custom>`
- `--registry <https-url>`
- `--manifest <relative-path>`
- `--release-workflow <name-or-relpath>`

Per-channel required sub-fields (validated by the E99-S2 if/then allOf):
- `mobile-app`: `--platform ios|android|both --store-id <id> --review-required <true|false>`
- `container-registry`: `--image-name <name> --tag-strategy semver|sha|latest`
- `static-site`: `--provider cloudflare-pages|s3|netlify|vercel|github-pages|custom --domain <host>`
- `maven`: `--group-id <id> --artifact-id <id>`
- `homebrew`: `--tap <tap>`
- `github-releases`: `--repo <owner/repo>`
- `custom`: `--adapter-name <name>` (matches `.gaia/custom/adapters/publish-<adapter_name>/`)

Optional: `--force` to bypass the all-`deployable` gate.

Placement: the new section goes between `ci_cd:` and `environments:` per the documented canonical ordering.

### `show`

Render the current `distribution:` block to stdout. Prints "(no distribution section)" if absent. Read-only.

### `clear`

Remove the entire `distribution:` section. Preserves surrounding comments + formatting.

### `set`

Update one or more fields of an existing `distribution:` section. REFUSES when no section exists. Same flag vocabulary as `add`; only the provided flags are mutated, the others stay as-is.

## Steps

### Step 1 — Locate project-config.yaml

Resolve via `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-config.sh project_config_path` (or fall back to `.gaia/config/project-config.yaml`). HALT if missing — point the user at `/gaia-init`.

### Step 2 — Dispatch sub-command

Read the first positional argument: must be one of `add`, `show`, `clear`, `set`. Reject any other value with a usage error.

### Step 3 — Extract the distribution section

Run `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh extract <path> distribution`. Exit 0: capture; exit 2 (absent): handle per sub-command (`add` proceeds; `set` / `clear` / `show` print "(no distribution section)" and exit 0 for show, exit non-zero for set/clear).

### Step 4 — Apply pre-write validation gates

For `add` and `set`:
1. Compose the candidate block from CLI flags merged into the extracted section.
2. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/distribution-canonicalize.sh`:
   - `gaia_distribution_canonicalize_manifest <project-root> <manifest-value>` on the `manifest` field.
   - `gaia_distribution_validate_url <registry-value>` on the `registry` field.
   - `gaia_distribution_validate_string <value>` on EACH OTHER `distribution.*` string field (release_workflow, store_id, image_name, domain, group_id, artifact_id, tap, repo, adapter_name).
3. Source `${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve-env-kind.sh` and probe each `environments[]` entry for `kind`; if ALL resolve to `deployable` AND `--force` is NOT set, REFUSE with the FR-523 guidance.
4. Run `${CLAUDE_PLUGIN_ROOT}/scripts/validate-project-config.sh <path>` against the prospective merged file in a temp location; on schema failure, REFUSE with ajv-cli's error block.
5. ANY failure → REFUSE the write, exit non-zero, file is byte-identical to pre-invocation state.

### Step 5 — Diff-preview + confirm

Render `diff -u <original> <prospective>` to the user. Prompt `[y]es / [n]o / [d]iff again / [a]bort`. In YOLO mode auto-confirm per ADR-067.

### Step 6 — Atomic write

On confirmation, invoke `${CLAUDE_PLUGIN_ROOT}/scripts/config-yaml-editor.sh replace <path> distribution <new-section>` (or `delete` for the `clear` op). The editor uses per-PID temp + `mv` rename for atomicity.

### Step 7 — Post-write verification

Re-extract and confirm the round-trip parses. Report success with the new section's line range. Note sprint-status.yaml may be out of sync — point the user at `/gaia-sprint-status`.

## `/gaia-config-show` integration (AC9)

`/gaia-config-show` (TOC mode) lists `distribution` as a present section. `/gaia-config-show distribution` (single-section mode) dispatches via `config-yaml-editor.sh extract` and renders the section verbatim. The dotted-path drill-down convention (e.g., `/gaia-config-show distribution.channel`) is supported via `yq eval` per the E98-S4 pattern documented in the `/gaia-config-show` SKILL.md.

## References

- FR-523 — `/gaia-config-distribution` section editor.
- FR-521 / FR-522 — 4 required common fields + closed 10-channel enum (E99-S2).
- SR-79 / SR-80 — path canonicalization + shell-metachar denylist + URL-shape (E99-S3).
- ADR-044 — comment-preserving section-scoped editors.
- ADR-112 — project-shape config model.
- ADR-067 — YOLO mode contract.
- ADR-042 — Scripts-over-LLM.
