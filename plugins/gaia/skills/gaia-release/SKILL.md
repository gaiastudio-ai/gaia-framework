---
name: gaia-release
description: Execute a project-generic release procedure — version bump (reading release.version_files[] from config), commit, tag, push, and GitHub Release. Wraps `skills/gaia-release/scripts/version-bump.js` and the `main`-only release branch policy. Use when "cut a release", "bump the version", or /gaia-release.
argument-hint: "[patch|minor|major|X.Y.Z] [--dry-run]"
allowed-tools: [Read, Bash, Grep]
orchestration_class: light-procedural
---

## Mission

You are producing a repeatable, project-generic release. The release procedure has five deterministic phases — **version bump → commit → tag → push → GitHub Release** — and they are executed only on `main` after a sprint merge. This skill is the discoverable source of truth for that procedure.

## Critical Rules

- **Release from `main` only.** Version bumps never happen on a feature branch or on `staging`. Cut a release only after the sprint PR has merged to `main`.
- **No Claude/AI attribution** in commit messages, tag messages, or the GitHub Release body. Every artifact must read as if a human release engineer authored it.
- **Never hand-edit the version strings.** Always invoke the version-bump script — it reads `release.version_files[]` from project-config.yaml and bumps every listed file in its native format.
- **Always dry-run first.** Run the bump with `--dry-run` to preview the new version and the files that would change; only then execute the real bump.
- **Inspect the script's reported output.** The version-bump script emits a machine-readable JSON summary listing every file it bumped and the old/new versions. Use that output as the authoritative file list when staging the commit.

## How the version-bump script works

The script (`skills/gaia-release/scripts/version-bump.js`) is a **project-generic, zero-dependency** Node.js script. It does not assume any particular project structure — it reads the list of version-carrying files from the project's own configuration.

### Configuration

Add a `release` block to your `project-config.yaml`:

```yaml
release:
  strategy: conventional-commits   # or: manual | calendar
  version_files:
    - package.json
    - plugin.json
    - VERSION
```

Each `version_files` entry is a file path **relative to the project root**. The script resolves them against `--project-root`.

### Release strategy — `release.strategy`

The `release.strategy` key controls how `/gaia-release` determines the next version. Three modes are supported:

| Strategy | Behavior |
| --- | --- |
| `conventional-commits` | Classify commits since the last `v*` tag using the Conventional Commits spec. `feat` → minor bump, `fix` → patch bump, `BREAKING CHANGE` or `!` suffix → major bump. The highest-precedence bump wins. When no qualifying commits exist in the range, the release exits cleanly (exit 0) with a "no releasable changes" message and no version bump. |
| `manual` | Signal the caller to prompt for the target version. No commit-derivation is performed — the user supplies `patch`, `minor`, `major`, or an explicit `X.Y.Z`. |
| `calendar` | Derive a CalVer version from the current date: `YYYY.MM.PATCH` where PATCH auto-increments based on existing tags for the current month. |

When `release.strategy` is **absent**, the behavior defaults to `manual` — this preserves backward compatibility for projects that do not set the key.

The strategy resolver (`skills/gaia-release/scripts/resolve-release-version.sh`) reads the strategy from config, dispatches to the appropriate derivation, and emits a machine-readable output that Step 3 (below) consumes to determine the bump specifier for `version-bump.js`.

### Supported file formats

| Format | Detection | Read | Write |
| --- | --- | --- | --- |
| **JSON** | Valid JSON with a top-level `"version"` key | `parsed.version` | Re-serializes with original indentation preserved |
| **Plain text** | File content is a bare semver string | `content.trim()` | Writes the version string + trailing newline |

Files that do not match either format (binary files, JSON without a `version` key, non-semver plain text) produce a clear error and abort — no silent corruption.

### Bump types

| Specifier | Example |
| --- | --- |
| `patch` | `1.2.3` → `1.2.4` |
| `minor` | `1.2.3` → `1.3.0` |
| `major` | `1.2.3` → `2.0.0` |
| `X.Y.Z` | Sets an explicit version |

### Per-component scoping

By default, the version-bump script bumps **all** files listed in `release.version_files[]` to the same target version (lockstep mode). When a project contains independently-versioned components, two flags enable per-component bumps:

- **`--scope <prefixes>`** — comma-separated path prefixes. Only version files whose relative path starts with one of the listed prefixes participate in the bump. Each participating file bumps from its **own** current version — not a shared reference. Files outside the scope are left untouched. Prefix matching is directory-boundary-safe: `packages/front` does **not** match `packages/frontend/`.
- **`--scope-map <json>`** — a JSON object mapping path prefix to bump type, e.g. `'{"packages/api":"minor","packages/ui":"patch"}'`. Each component group bumps from its own current version by its own bump type. The positional bump specifier is not required when `--scope-map` is used — the map supplies per-component bump types.

### Monotonic no-downgrade guard

Before writing a bumped version, the script compares the computed target to the file's current version using numeric semver comparison. If the target is **less than or equal to** the current version, the write is skipped and a warning is emitted to stderr. This prevents accidental downgrades when components have divergent versions.

The guard applies in both scoped and lockstep (unscoped) mode. In lockstep mode, the reference version comes from the first listed file — if another file is already ahead of that computed target, it is silently skipped (with the skip surfaced in the `skipped` array and stderr).

If **every** candidate file is a monotonic no-op (nothing to bump), the script exits with code **4**.

### Error handling

- **Missing `release.version_files`**: exits non-zero with an error that explicitly names the missing config key `release.version_files`.
- **Missing version file on disk**: exits non-zero naming the file.
- **Unsupported format**: exits non-zero naming the file and the detected format problem.
- **All candidates already at or above target**: exit code 4 — no files were written.

### Machine-readable output

On success (exit 0), stdout contains a single JSON object:

```json
{
  "old_version": "1.2.3",
  "new_version": "1.2.4",
  "bump_type": "patch",
  "bumped": [
    { "file": "package.json", "format": "json", "old": "1.2.3", "new": "1.2.4" },
    { "file": "VERSION", "format": "text", "old": "1.2.3", "new": "1.2.4" }
  ],
  "skipped": []
}
```

The top-level `old_version`, `new_version`, and `bump_type` keys are present in lockstep (unscoped) mode for backward compatibility. In per-component (scoped) mode, only `bumped` and `skipped` are emitted.

The `skipped` array contains one entry per file that the monotonic guard prevented from being written:

```json
{ "file": "lib/package.json", "reason": "monotonic-guard", "current": "2.0.0", "target": "1.2.4" }
```

On exit code 4 (all candidates were no-ops), the same JSON structure is emitted with an empty `bumped` array and a populated `skipped` array.

### Config resolution

The script requires `--config <path>` pointing at the project-config.yaml. In practice, the release workflow resolves this path via `scripts/resolve-config.sh` (the existing foundation script with walk-up discovery), which locates the config from any working directory.

## Inputs

- `$ARGUMENTS`: the bump specifier and optional flags:
  - `patch | minor | major` — standard semver bump.
  - `X.Y.Z` — set an explicit version.
  - `--dry-run` — print the planned changes as JSON and exit without writing.
  - `--scope <prefixes>` — comma-separated path prefixes to limit the bump to named components.
  - `--scope-map <json>` — JSON object mapping path prefix to bump type for independent per-component bumps.

## Instructions

### Step 1 — Verify you are on `main`

```
!git rev-parse --abbrev-ref HEAD
!git status --porcelain
```

HALT if the current branch is not `main` or the working tree is dirty. Releases are cut from a clean `main` only; pull with `git pull --ff-only` if the local branch is behind `origin/main`.

### Step 2 — Resolve the config path

```
!CONFIG_PATH=$("$CLAUDE_PLUGIN_ROOT/scripts/resolve-config.sh" project_config_path)
!PROJECT_ROOT=$("$CLAUDE_PLUGIN_ROOT/scripts/resolve-config.sh" project_root)
```

### Step 3 — Resolve the release strategy

```
!bash "$CLAUDE_PLUGIN_ROOT/skills/gaia-release/scripts/resolve-release-version.sh" --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT"
```

The resolver reads `release.strategy` from config (defaulting to `manual` when absent) and emits a machine-readable output:

- **`conventional-commits`**: emits `bump=<major|minor|patch|none>`. When `bump=none`, report "no releasable changes" to the user and stop — do not proceed to version-bump. This is a clean exit (exit 0), not an error.
- **`manual`**: emits `strategy=manual`. Prompt the user for a bump specifier (`patch`, `minor`, `major`, or `X.Y.Z`).
- **`calendar`**: emits `version=YYYY.MM.PATCH`. Pass that version string directly to version-bump.js as an explicit version.

### Step 4 — Dry-run the bump

Using the bump specifier from Step 3:

```
!node "$CLAUDE_PLUGIN_ROOT/skills/gaia-release/scripts/version-bump.js" <bump-from-step-3> --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT" --dry-run
```

Inspect the JSON output: the current version, the new version, and the files that would change. If the preview is wrong, adjust the arguments and re-run. The script exits 0 and writes nothing.

### Step 5 — Execute the bump

Drop `--dry-run` and run for real:

```
!node "$CLAUDE_PLUGIN_ROOT/skills/gaia-release/scripts/version-bump.js" <bump-from-step-3> --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT"
```

The script writes all configured version files and prints the JSON summary.

### Step 6 — Commit the bump

Use a conventional commit — no emoji, no Claude attribution. Stage exactly the files listed in the `bumped[]` array from Step 5's output:

```
!git add <files-from-bumped-array>
!git commit -m "chore(release): bump version to vX.Y.Z"
```

### Step 7 — Tag

```
!git tag -a vX.Y.Z -m "vX.Y.Z"
```

### Step 8 — Push

Push the bump commit and the tag together:

```
!git push origin main
!git push origin vX.Y.Z
```

### Step 9 — Create the GitHub Release

Draft release notes from the changelog entry. If a changelog is missing, generate one first with `/gaia-changelog`.

```
!gh release create vX.Y.Z --title "vX.Y.Z" --notes-file CHANGELOG-vX.Y.Z.md
```

### Step 10 — Post-release verification

- `gh release view vX.Y.Z` — confirm the release is published.
- `git describe --tags --abbrev=0` on a fresh clone matches the new tag.

## Flag quick reference

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print the planned changes as JSON and exit without writing. Use this first on every release. |
| `--scope <prefixes>` | Comma-separated path prefixes — only matching version files are bumped; each bumps from its own current version. |
| `--scope-map <json>` | JSON object mapping prefix to bump type — enables independent per-component bumps without a positional specifier. |

## References

- Version bump: `skills/gaia-release/scripts/version-bump.js` (zero-dependency Node.js script).
- Strategy resolver: `skills/gaia-release/scripts/resolve-release-version.sh` (reads `release.strategy` from config).
- Commit classification: `scripts/classify-commits.js` (Conventional Commits parser, reused by the conventional-commits strategy).
- Config resolution: `scripts/resolve-config.sh` (foundation script with walk-up discovery).
- Configuration: `release.version_files[]` and `release.strategy` in `project-config.yaml`.
- Related: `/gaia-changelog` for release-note generation.
