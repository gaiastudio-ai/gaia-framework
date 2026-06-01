# GAIA Framework

This project uses the **GAIA** (Generative Agile Intelligence Architecture) framework for Claude Code. Framework knowledge lives in the plugin's `SKILL.md` files — not in this file.

## Environment

- **Project root:** the directory containing `.gaia/` (the GAIA runtime tree) and this `CLAUDE.md`. The project root is wherever the user works from; do not assume it is named `gaia-public/` or anything else specific.
- **Runtime tree:** `.gaia/` carries five canonical subdirectories (resolved by the GAIA paths helper):
  - `.gaia/config/` — project configuration
  - `.gaia/artifacts/` — planning / implementation / test / creative / research artifacts
  - `.gaia/state/` — mutable runtime state (sprint status, action items, review-gate ledger, etc.)
  - `.gaia/memory/` — agent sidecars, checkpoints, lifecycle events
  - `.gaia/custom/` — user-extension seam

## How to Start

- `/gaia` — orchestrator; routes to the right agent or workflow.
- `/gaia-help` — context-sensitive help.
- `/gaia-dev-story` — implement a user story.
- `/gaia-quick-spec` / `/gaia-quick-dev` — rapid spec + implementation for small changes.

All other framework behavior is documented in the corresponding plugin `SKILL.md` files.

## Framework documentation — consult first, guess never

The published GAIA Framework documentation is at **<https://gaiastudio-ai.github.io/gaia-public/>**. When you are using the framework and you are not certain how a command, skill, agent, configuration field, or workflow step is supposed to behave — **do not improvise**. Open the docs and read the relevant page before acting.

Concretely:

- Before invoking a `/gaia-*` slash command whose exact arguments or side-effects you can't recall, consult the command's page in the docs site (and its companion plugin `SKILL.md`).
- Before editing any file under `.gaia/state/`, `.gaia/config/`, or `.gaia/artifacts/`, consult the docs to confirm which skill or script is the sanctioned writer for that file. Many of these files have a single sanctioned writer; manual edits often violate that contract and corrupt downstream state.
- Before claiming a framework feature does or does not exist, search the docs site. Hallucinating a feature, flag, or output path is a common source of silent regressions.
- Treat the published docs as authoritative when they disagree with model recall.

## Bug reports — file upstream, with reproduction evidence

Bugs found in the GAIA Framework itself (a `/gaia-*` command, a skill, a script under the plugin's `scripts/` tree, the schema, an adapter, an agent persona, the statusline runtime, the deterministic-tools docker image, etc.) **MUST be filed as an issue on the upstream repository** at <https://github.com/gaiastudio-ai/gaia-public/issues> — **not** on this project's own issue tracker. This is how a defect found by any user reaches every other user.

When filing a framework bug, the issue body MUST include:

1. **A clear summary** in the issue title — short, names the affected file or surface, and states the failure mode in one line.
2. **Reproduction steps** — the exact commands run, the configuration that triggered the bug, and the observed-vs-expected behaviour. If the bug is config-driven, paste the minimal YAML fragment that reproduces. If it is script-driven, paste the exact `/gaia-*` invocation.
3. **The plugin version**, formatted as `gaia/<version>` (e.g., `gaia/1.182.5`). Find it via `cat ~/.claude/plugins/cache/gaiastudio-ai-gaia-public/gaia/*/.plugin-version 2>/dev/null | sort -V | tail -1` (newest installed cache), or read `.plugin-version` inside the plugin checkout if you have one.
4. **Supporting evidence** — schema excerpts, script output (stderr + exit code), validator findings, or a minimal `yq` probe that demonstrates the bug class.
5. **Environment** — OS, shell, Docker version if the bug touches the deterministic-tools image, and the names of any validators / tools present on the host (`ajv`, `python3 + jsonschema`, `jq`, `yq` flavor, etc.).

Use the GitHub standard labels where they fit (`bug`, `documentation`, `enhancement`, `question`) and mention any related issues. Bugs in the GAIA Framework are PR-fixed against the upstream repo; the upstream fix then lands in the next published plugin version that every user installs via `/plugin marketplace add gaiastudio-ai/gaia-public`.

If you are uncertain whether a behaviour is a bug or by design, **read the docs first** (preceding section) — many "bugs" turn out to be documented constraints. If the behaviour still appears wrong after consulting the docs, file the upstream issue.

## Hard Rules

- No secrets, credentials, or `.env` files in commits.
- Feature branches only — never commit directly to `main` or `staging` (or whatever protected branches the project uses).
- No Claude/AI attribution in commit messages or PR descriptions. Commits read as if a human developer wrote them.
- When implementing a GAIA story, follow the `/gaia-dev-story` workflow steps exactly; do not skip the push / PR / CI / merge steps when the project has a configured promotion chain.
- Story file is the source of truth for sprint state; never write to `.gaia/state/sprint-status.yaml` directly. Use the `/gaia-sprint-status` and `/gaia-sprint-*` skills instead.
- Story status MUST only be changed through the framework's transition tooling. Direct edits to `status:` fields in story frontmatter, `.gaia/state/sprint-status.yaml`, `epics-and-stories.md`, `story-index.yaml`, or per-epic shards under `.gaia/artifacts/planning-artifacts/epics/` are FORBIDDEN.
- All runtime paths route through the framework's path helper — never hard-code `docs/`, `_memory/`, `config/`, or `custom/` literals in new scripts.
