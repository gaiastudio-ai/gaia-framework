# GAIA Framework v1.127.2-rc.1

This project uses the **GAIA** (Generative Agile Intelligence Architecture) framework for Claude Code. Framework knowledge lives in the plugin's SKILL.md files — not in this file (per FR-327 / ADR-048).

## Environment

- **Project root:** the directory containing `_gaia/`, `docs/`, `_memory/`, and this `CLAUDE.md`.
- **Project path:** `gaia-public/` — product source (git-tracked; published via marketplace).
- **Artifacts:** `docs/planning-artifacts/`, `docs/implementation-artifacts/`, `docs/test-artifacts/`, `docs/creative-artifacts/`.
- **Memory:** `_memory/` (agent sidecars + `_memory/checkpoints/`).
- **Directory identity:** `gaia-public/plugins/gaia/` is the **product source** (in git). `{project-root}/_gaia/` is the **local runtime framework** (not in git). Never symlink, merge, or confuse them.

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
- Story file is the source of truth for sprint state; never write to `sprint-status.yaml` directly except via `/gaia-sprint-status`.
- Story status MUST only be changed via `transition-story-status.sh`. Direct edits to `status:` fields in story frontmatter, sprint-status.yaml, epics-and-stories.md, story-index.yaml, or per-epic shards under `docs/planning-artifacts/epics/` are FORBIDDEN.
