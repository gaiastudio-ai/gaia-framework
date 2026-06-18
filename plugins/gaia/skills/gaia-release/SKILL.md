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

Add a `release.version_files` list to your `project-config.yaml`:

```yaml
release:
  version_files:
    - package.json
    - plugin.json
    - VERSION
```

Each entry is a file path **relative to the project root**. The script resolves them against `--project-root`.

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

### Error handling

- **Missing `release.version_files`**: exits non-zero with an error that explicitly names the missing config key `release.version_files`.
- **Missing version file on disk**: exits non-zero naming the file.
- **Unsupported format**: exits non-zero naming the file and the detected format problem.
- **No silent no-ops**: the script always either bumps all listed files or fails before writing any.

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
  ]
}
```

### Config resolution

The script requires `--config <path>` pointing at the project-config.yaml. In practice, the release workflow resolves this path via `scripts/resolve-config.sh` (the existing foundation script with walk-up discovery), which locates the config from any working directory.

## Inputs

- `$ARGUMENTS`: the bump specifier and optional flags:
  - `patch | minor | major` — standard semver bump.
  - `X.Y.Z` — set an explicit version.
  - `--dry-run` — print the planned changes as JSON and exit without writing.

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

### Step 3 — Dry-run the bump

```
!node "$CLAUDE_PLUGIN_ROOT/skills/gaia-release/scripts/version-bump.js" <patch|minor|major|X.Y.Z> --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT" --dry-run
```

Inspect the JSON output: the current version, the new version, and the files that would change. If the preview is wrong, adjust the arguments and re-run. The script exits 0 and writes nothing.

### Step 4 — Execute the bump

Drop `--dry-run` and run for real:

```
!node "$CLAUDE_PLUGIN_ROOT/skills/gaia-release/scripts/version-bump.js" <patch|minor|major|X.Y.Z> --config "$CONFIG_PATH" --project-root "$PROJECT_ROOT"
```

The script writes all configured version files and prints the JSON summary.

### Step 5 — Commit the bump

Use a conventional commit — no emoji, no Claude attribution. Stage exactly the files listed in the `bumped[]` array from Step 4's output:

```
!git add <files-from-bumped-array>
!git commit -m "chore(release): bump version to vX.Y.Z"
```

### Step 6 — Tag

```
!git tag -a vX.Y.Z -m "vX.Y.Z"
```

### Step 7 — Push

Push the bump commit and the tag together:

```
!git push origin main
!git push origin vX.Y.Z
```

### Step 8 — Create the GitHub Release

Draft release notes from the changelog entry. If a changelog is missing, generate one first with `/gaia-changelog`.

```
!gh release create vX.Y.Z --title "vX.Y.Z" --notes-file CHANGELOG-vX.Y.Z.md
```

### Step 9 — Post-release verification

- `gh release view vX.Y.Z` — confirm the release is published.
- `git describe --tags --abbrev=0` on a fresh clone matches the new tag.

## Flag quick reference

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print the planned changes as JSON and exit without writing. Use this first on every release. |

## References

- Source: `skills/gaia-release/scripts/version-bump.js` (zero-dependency Node.js script).
- Config resolution: `scripts/resolve-config.sh` (foundation script with walk-up discovery).
- Configuration: `release.version_files[]` in `project-config.yaml`.
- Related: `/gaia-changelog` for release-note generation.
