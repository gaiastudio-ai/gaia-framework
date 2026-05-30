---
name: gaia-release
description: Document and execute the GAIA framework release procedure — version bump, commit, tag, push, and GitHub Release. Wraps `scripts/version-bump.js` and the `main`-only release branch policy. Use when "cut a release", "release the framework", "bump the version", or /gaia-release.
argument-hint: "[patch|minor|major|none|X.Y.Z] [--prerelease rc | --strip-prerelease] [--modules mod1,mod2] [--dry-run]"
allowed-tools: [Read, Bash, Grep]
orchestration_class: light-procedural
---

## Mission

You are producing a repeatable release for the GAIA framework. The release procedure has five deterministic phases — **version bump → commit → tag → push → GitHub Release** — and they are executed only on `main` after a sprint merge. This skill is the discoverable source of truth for that procedure, replacing the inline narrative that used to live in `CLAUDE.md` before it was slimmed under FR-327 / ADR-048.

## Critical Rules

- **Release from `main` only.** Version bumps never happen on a feature branch or on `staging`. Cut a release only after the sprint PR has merged to `main`.
- **No Claude/AI attribution** in commit messages, tag messages, or the GitHub Release body. Every artifact must read as if a human release engineer authored it.
- **Never hand-edit the version strings.** Always invoke `scripts/version-bump.js` — it keeps `package.json` and the GAIA `framework_version` config key synchronized and validates drift before writing.
- **Always dry-run first.** Run the bump with `--dry-run` to preview the new version and the files that would change; only then execute the real bump.
- **Inspect the script's reported output paths.** `scripts/version-bump.js` prints the exact files it intends to touch (and re-prints them after writing). Use that output as the authoritative file list when staging the commit in Step 5 — it is resilient to the ADR-044 config-split and any future config-location changes.

## Inputs

- `$ARGUMENTS`: the bump specifier and any flags passed straight through to `scripts/version-bump.js`. Accepted values:
  - `patch | minor | major` — standard semver bump.
  - `none` — increment only the RC counter (requires the current version to already carry an `-rc.N` suffix).
  - `X.Y.Z` or `X.Y.Z-rc.N` — set an explicit version (e.g., after resolving drift).
  - `--prerelease rc` — turn a clean bump into an RC prerelease (`1.127.2` → `1.128.0-rc.1`).
  - `--strip-prerelease` — drop the `-rc.N` suffix without changing numbers (promote an RC to its final cut).
  - `--modules mod1,mod2` — also bump per-module `config.yaml` and manifest entries (valid modules: `core`, `lifecycle`, `dev`, `creative`, `testing`, or `all`).
  - `--dry-run` — print the planned changes and exit without writing.

## What `version-bump.js` actually does (ADR-025 Model B)

Per **ADR-025 Model B**, the script is the single source of truth for the framework version, and it updates **exactly 2 global targets**:

| Target | Role |
| --- | --- |
| `package.json` | npm manifest — `"version": "…"` |
| GAIA config (`framework_version` key) | framework source of truth — resolved via `scripts/resolve-config.sh`; the on-disk location follows the ADR-044 two-file split |

Earlier drafts described a broader touch-set; that narrative no longer applies. `gaia-install.sh`, `CLAUDE.md`, and `README.md` no longer carry hardcoded versions — the installer reads from `package.json` at runtime, and the markdown files reference the version indirectly.

When `--modules` is passed, the script also touches per-module `config.yaml` entries and the matching rows in the plugin's `knowledge/manifest.yaml` — these are **module**-scoped writes, separate from the 2 global targets above.

Before writing anything the script validates that every global target contains the expected version pattern and detects drift. If the targets disagree, the script halts unless an explicit `X.Y.Z` version is supplied.

## Instructions

### Step 1 — Verify you are on `main`

```
!git rev-parse --abbrev-ref HEAD
!git status --porcelain
```

HALT if the current branch is not `main` or the working tree is dirty. Releases are cut from a clean `main` only; pull with `git pull --ff-only` if the local branch is behind `origin/main`.

### Step 2 — Dry-run the bump

Run the bump with `--dry-run` first to confirm the target version:

```
!node scripts/version-bump.js <patch|minor|major|none|X.Y.Z> [--prerelease rc] [--strip-prerelease] [--modules mod1,mod2] --dry-run
```

Inspect the output: the current version, the new version, the global targets that will change (with their resolved on-disk paths), and the per-module files (if `--modules` was supplied). If the preview is wrong, adjust the arguments and re-run the dry-run. The script exits 0 and writes nothing.

### Step 3 — Execute the bump

Drop `--dry-run` and run the bump for real:

```
!npm run version:bump -- <patch|minor|major|none|X.Y.Z> [--prerelease rc] [--strip-prerelease] [--modules mod1,mod2]
```

(or equivalently `!node scripts/version-bump.js <args>`). The script writes `package.json` and the on-disk file backing the `framework_version` key (as reported in the script's own output), plus any module files covered by `--modules`, and prints the next-step reminder.

### Step 4 — Commit the bump

Use a conventional commit — no emoji, no Claude attribution. Stage exactly what `version-bump.js` reported as modified in Step 3; do NOT hand-enumerate the config path, read it back from the script's output so this skill stays correct across ADR-044 config-layout changes:

```
!git add package.json <config-files-printed-by-version-bump.js> [module files if any]
!git commit -m "chore(release): bump version to vX.Y.Z"
```

For RC prereleases use `chore(release): bump version to vX.Y.Z-rc.N`.

### Step 5 — Tag

Annotated tags carry the release notes summary and are what `gh release create` attaches to:

```
!git tag -a vX.Y.Z -m "vX.Y.Z"
```

For an RC: `git tag -a vX.Y.Z-rc.N -m "vX.Y.Z-rc.N"`.

### Step 6 — Push

Push the bump commit and the tag together. The tag must reach the remote before Step 7:

```
!git push origin main
!git push origin vX.Y.Z
```

### Step 7 — Create the GitHub Release

Draft the Release notes from the changelog entry. If a changelog is missing, generate one first with `/gaia-changelog`.

```
!gh release create vX.Y.Z --title "vX.Y.Z" --notes-file CHANGELOG-vX.Y.Z.md
```

For RC builds add `--prerelease` so the release is flagged correctly on GitHub:

```
!gh release create vX.Y.Z-rc.N --prerelease --title "vX.Y.Z-rc.N" --notes-file CHANGELOG-vX.Y.Z-rc.N.md
```

### Step 8 — Post-release verification

- `gh release view vX.Y.Z` — confirm the release is published (or marked prerelease for RCs).
- `git describe --tags --abbrev=0` on a fresh clone matches the new tag.
- The published tarball (if any) installs cleanly via `gaia-install.sh`.

## Flag quick reference

| Flag | Effect |
| --- | --- |
| `--dry-run` | Print the planned changes and exit without writing. Use this first on every release. |
| `--prerelease rc` | Bump to an RC prerelease (`1.127.2` → `1.128.0-rc.1` for a minor bump). |
| `--strip-prerelease` | Remove the `-rc.N` suffix without changing numbers — promote the final cut. |
| `none` | Increment the RC counter only (`1.128.0-rc.1` → `1.128.0-rc.2`); requires an existing `-rc.N`. |
| `--modules mod1,mod2` | Also bump per-module `config.yaml` + manifest rows. `all` expands to every module. |

## References

- Source: `scripts/version-bump.js` (node script in the repo root — zero deps per ADR-005, file-based regex per ADR-006).
- ADR-025 (Model B): canonical 2-target version storage — `package.json` + the `framework_version` config key (resolved via `scripts/resolve-config.sh` per ADR-042/ADR-044).
- ADR-044 — Two-file config split (`.gaia/config/project-config.yaml` shared + `config/global.yaml` machine-local); the `framework_version` key lives in the shared project config.
- FR-327 / ADR-048: CLAUDE.md slim-down — procedural detail moved to SKILL.md files.
- Story: `.gaia/artifacts/implementation-artifacts/E28-S167-document-version-bump-procedure-in-gaia-release-skill.md` (origin: triage finding F4 from E28-S129).
- Related: `/gaia-changelog` for release-note generation.
