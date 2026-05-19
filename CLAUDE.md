# GAIA Framework v1.127.2-rc.1

This project uses the **GAIA** (Generative Agile Intelligence Architecture) framework for Claude Code. Framework knowledge lives in the plugin's SKILL.md files — not in this file (per FR-327 / ADR-048).

## Environment

- **Project root:** the directory containing `.gaia/` (the consolidated GAIA runtime tree per ADR-111) and this `CLAUDE.md`.
- **Project path:** `gaia-public/` — product source (git-tracked; published via marketplace).
- **Runtime tree:** `.gaia/` carries five canonical subdirectories (resolved by `scripts/lib/gaia-paths.sh`):
  - `.gaia/config/` — project-config + global config (was `config/`)
  - `.gaia/artifacts/` — planning / implementation / test / creative / research artifacts (was `docs/*-artifacts/`)
  - `.gaia/state/` — mutable runtime state: `sprint-status.yaml`, `action-items.yaml`, `.review-gate-ledger`, etc.
  - `.gaia/memory/` — agent sidecars, checkpoints, lifecycle events (was `_memory/`)
  - `.gaia/custom/` — user-extension seam (was top-level `custom/`)
- **Directory identity:** `gaia-public/plugins/gaia/` is the **product source** (in git). `.gaia/` is the **local runtime framework** (not in git). Never symlink, merge, or confuse them.
- **Reference:** ADR-111 (consolidates ADR-020 / ADR-044 / ADR-046) — see `docs/planning-artifacts/assessment-AF-2026-05-19-1.md`.

## How to Start

- `/gaia` — orchestrator; routes to the right agent or workflow.
- `/gaia-help` — context-sensitive help.
- `/gaia-dev-story` — implement a user story.
- `/gaia-quick-spec` / `/gaia-quick-dev` — rapid spec + implementation for small changes.

All other framework behavior is documented in the corresponding `plugins/gaia/skills/*/SKILL.md`.

## Hard Rules

- No secrets, credentials, or `.env` files in commits.
- Feature branches only — never commit directly to `main` or `staging`.
- No Claude/AI attribution in commit messages or PR descriptions. Commits read as if a human developer wrote them.
- Version bumps happen only on `main` after sprint merge — never in feature branches.
- When implementing a GAIA story, follow the `/gaia-dev-story` workflow steps exactly; do not skip Steps 13–16 (push, PR, CI, merge) when `ci_cd.promotion_chain` is set.
- `gaia-public/plugins/gaia/commands/` is retired under FR-329 — do not repopulate it. Slash commands resolve via SKILL.md.
- Story file is the source of truth for sprint state; never write to `.gaia/state/sprint-status.yaml` directly except via `/gaia-sprint-status`.
- Story status MUST only be changed via `transition-story-status.sh`. Direct edits to `status:` fields in story frontmatter, `.gaia/state/sprint-status.yaml`, `epics-and-stories.md`, `story-index.yaml`, or per-epic shards under `.gaia/artifacts/planning-artifacts/epics/` are FORBIDDEN.
- All runtime paths route through `scripts/lib/gaia-paths.sh` canonical constants (`GAIA_CONFIG_DIR`, `GAIA_ARTIFACTS_DIR`, `GAIA_STATE_DIR`, `GAIA_MEMORY_DIR`, `GAIA_CUSTOM_DIR`) — no bare `docs/`, `_memory/`, `config/`, or `custom/` literals in new scripts.
