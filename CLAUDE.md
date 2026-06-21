# GAIA Framework

This project uses the **GAIA** (Generative Agile Intelligence Architecture) framework for Claude Code. Framework knowledge lives in the plugin's `SKILL.md` files — not in this file.

## Environment

- **Project root:** the directory containing `.gaia/` (the GAIA runtime tree) and this `CLAUDE.md`. The project root is wherever the user works from; do not assume it is named `gaia-framework/` or anything else specific.
- **Runtime tree:** `.gaia/` carries five canonical subdirectories (resolved by the GAIA paths helper):
  - `.gaia/config/` — project configuration
  - `.gaia/artifacts/` — planning / implementation / test / creative / research artifacts
  - `.gaia/state/` — mutable runtime state (sprint status, action items, review-gate ledger, etc.)
  - `.gaia/memory/` — agent sidecars, checkpoints, lifecycle events
  - `.gaia/custom/` — user-extension seam
  - `.gaia/knowledge/` — the Brain knowledge layer (see below)

## GAIA Brain

The Brain is a read-only knowledge layer that indexes your project's artifacts into a queryable governance graph. It lives at `.gaia/knowledge/` as a pair of files: `brain-index.yaml` (the machine-readable manifest) and `brain-index.md` (a human-browsable Map of Content). The Brain does not copy artifact bytes — each index entry points at the artifact's canonical path in place.

Key gestures:

- **`/gaia-feed`** — ingest an external document (URL, local file, or pasted text) into the knowledge store with provenance tracking. The slug and tags are auto-inferred.
- **`/gaia-brain-query`** — query a story's governance envelope: the requirements and decisions above it (UP), the tests and reviews below it (DOWN), and the design companions alongside it (LATERAL) — all in one read-only call.
- **`/gaia-brain-reindex`** — rebuild the index from source. Runs automatically at sprint-close and on demand.
- **`/gaia-brain-health`** — list every indexed artifact with no governance link (a passive quality signal, not an error).
- **`/gaia-unfeed`** — remove an ingested document. The inverse of `/gaia-feed`.
- **`/gaia-knowledge-refresh`** — re-fetch ingested sources and update only what changed.

**Browse in Obsidian:** open `.gaia/knowledge/` as an Obsidian vault to navigate the Map of Content visually. The vault's `.obsidian/` directory (workspace layout, graph settings, installed plugins) is per-user chrome and is gitignored by `/gaia-init` so it never creates commit churn. The brain content itself (`brain-index.yaml`, `brain-index.md`, ingested entries) is shared and tracked in version control.

## How to Start

- `/gaia` — orchestrator; routes to the right agent or workflow.
- `/gaia-help` — context-sensitive help.
- `/gaia-dev-story` — implement a user story.
- `/gaia-quick-spec` / `/gaia-quick-dev` — rapid spec + implementation for small changes.

All other framework behavior is documented in the corresponding plugin `SKILL.md` files.

## Framework documentation — consult first, guess never

The published GAIA Framework documentation is at **<https://gaiastudio-ai.github.io/gaia-framework/>**. When you are using the framework and you are not certain how a command, skill, agent, configuration field, or workflow step is supposed to behave — **do not improvise**. Open the docs and read the relevant page before acting.

Concretely:

- Before invoking a `/gaia-*` slash command whose exact arguments or side-effects you can't recall, consult the command's page in the docs site (and its companion plugin `SKILL.md`).
- Before editing any file under `.gaia/state/`, `.gaia/config/`, or `.gaia/artifacts/`, consult the docs to confirm which skill or script is the sanctioned writer for that file. Many of these files have a single sanctioned writer; manual edits often violate that contract and corrupt downstream state.
- Before claiming a framework feature does or does not exist, search the docs site. Hallucinating a feature, flag, or output path is a common source of silent regressions.
- Treat the published docs as authoritative when they disagree with model recall.

## Bug reports — file upstream, with reproduction evidence

Bugs found in the GAIA Framework itself (a `/gaia-*` command, a skill, a script under the plugin's `scripts/` tree, the schema, an adapter, an agent persona, the statusline runtime, the deterministic-tools docker image, etc.) **MUST be filed as an issue on the upstream repository** at <https://github.com/gaiastudio-ai/gaia-framework/issues> — **not** on this project's own issue tracker. This is how a defect found by any user reaches every other user.

When filing a framework bug, the issue body MUST include:

1. **A clear summary** in the issue title — short, names the affected file or surface, and states the failure mode in one line.
2. **Reproduction steps** — the exact commands run, the configuration that triggered the bug, and the observed-vs-expected behaviour. If the bug is config-driven, paste the minimal YAML fragment that reproduces. If it is script-driven, paste the exact `/gaia-*` invocation.
3. **The plugin version**, formatted as `gaia/<version>` (e.g., `gaia/1.182.5`). Find it via `cat ~/.claude/plugins/cache/gaiastudio-ai-gaia-framework/gaia/*/.plugin-version 2>/dev/null | sort -V | tail -1` (newest installed cache), or read `.plugin-version` inside the plugin checkout if you have one.
4. **Supporting evidence** — schema excerpts, script output (stderr + exit code), validator findings, or a minimal `yq` probe that demonstrates the bug class.
5. **Environment** — OS, shell, Docker version if the bug touches the deterministic-tools image, and the names of any validators / tools present on the host (`ajv`, `python3 + jsonschema`, `jq`, `yq` flavor, etc.).

Use the GitHub standard labels where they fit (`bug`, `documentation`, `enhancement`, `question`) and mention any related issues. Bugs in the GAIA Framework are PR-fixed against the upstream repo; the upstream fix then lands in the next published plugin version that every user installs via `/plugin marketplace add gaiastudio-ai/gaia-framework`.

If you are uncertain whether a behaviour is a bug or by design, **read the docs first** (preceding section) — many "bugs" turn out to be documented constraints. If the behaviour still appears wrong after consulting the docs, file the upstream issue.

## Hard Rules

- **NEVER defer, descope, skip, or partially-complete any work without first informing the user and getting their explicit approval. This is STRICT and non-negotiable.** If you cannot finish a task, an acceptance criterion, a story, or any part of what was asked — or you decide some part should be "out of scope", "a follow-on", "deferred to a later story", or "left as backlog" — you MUST stop, tell the user plainly what you are proposing to leave undone and why, and wait for their decision. Silence is not consent. The failure mode this prevents: an agent quietly narrows scope, marks the visible part done, and the user never learns the rest was dropped unless they happen to ask. Do not let that happen. Concretely:
  - Surface every deferral the moment you decide it — in your turn's response, in plain language, not buried in a story file, commit message, or artifact the user may never read.
  - A deferral is only legitimate once the user has seen it and agreed. Until then, treat the full original scope as still owed.
  - Marking a story/AC `done` or `delivered` while any of its scope is unmet is forbidden unless the user explicitly approved that carve-out — and the deferred remainder must be filed as a tracked backlog story (never left only as prose).
  - When work you complete *surfaces* new latent issues or follow-ons, name them explicitly to the user and ask whether to file/handle them; do not assume they will ask.
  - Be honest by default: report what is actually done, what is not, and what you chose not to do — every time, without being prompted.
- No secrets, credentials, or `.env` files in commits.
- Feature branches only — never commit directly to `main` or `staging` (or whatever protected branches the project uses).
- No Claude/AI attribution in commit messages or PR descriptions. Commits read as if a human developer wrote them.
- When implementing a GAIA story, follow the `/gaia-dev-story` workflow steps exactly; do not skip the push / PR / CI / merge steps when the project has a configured promotion chain.
- Story file is the source of truth for sprint state; never write to `.gaia/state/sprint-status.yaml` directly. Use the `/gaia-sprint-status` and `/gaia-sprint-*` skills instead.
- Story status MUST only be changed through the framework's transition tooling. Direct edits to `status:` fields in story frontmatter, `.gaia/state/sprint-status.yaml`, `epics-and-stories.md`, `story-index.yaml`, or per-epic shards under `.gaia/artifacts/planning-artifacts/epics/` are FORBIDDEN.
- All runtime paths route through the framework's path helper — never hard-code `docs/`, `_memory/`, `config/`, or `custom/` literals in new scripts.
