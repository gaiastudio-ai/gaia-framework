# Stack Detection Namespaces

## Two-Namespace Design

The stack pipeline uses two distinct naming namespaces for the same concept —
the technology ecosystem — and they serve different purposes:

| Namespace | Examples | Used by |
|---|---|---|
| **Ecosystem name** | `python`, `go`, `embedded`, `node`, `angular` | `detect-signals.sh` — emitted in the `stacks[].name` JSON field |
| **Canonical persona token** | `python-dev`, `go-dev`, `embedded-dev`, `ts-dev`, `angular-dev` | `load-stack-persona.sh` — resolved to an agent `.md` file |

The ecosystem name is the raw signal produced by file-marker detection. The
canonical persona token is the `-dev`-suffixed identifier that the persona
pipeline, story frontmatter, and agent routing all use.

## Mapping

`load-stack-persona.sh` maps from persona token to agent filename. The ecosystem
name produced by `detect-signals.sh` is used separately to populate
`stacks[].name` in `project-config.yaml`; a higher-level caller (such as
`/gaia-config-stack`) maps it to the persona token when a dev agent needs to be
selected.

Selected mappings:

| Ecosystem name | Canonical persona token | Agent file |
|---|---|---|
| `node` / `angular` | `ts-dev` / `angular-dev` | `typescript-dev.md` / `angular-dev.md` |
| `python` | `python-dev` | `python-dev.md` |
| `go` | `go-dev` | `go-dev.md` |
| `embedded` | `embedded-dev` | `embedded-dev.md` |
| (explicit-only) | `bash-dev` | `bash-dev.md` |

## Why bash-dev Is Explicit-Only

`bash-dev` has no file-marker in the ecosystem namespace. Shell scripts
(`*.sh`) appear in almost every polyglot repository, so detecting bash by
file-glob would misclassify the vast majority of projects. The bash stack is
resolved only through:

- An explicit `--stack bash-dev` flag passed to `load-stack-persona.sh`
- A `stack: bash-dev` field in a story's YAML frontmatter
- A `project.stack: bash-dev` field in `project-config.yaml`

`detect-signals.sh` includes a note in its source code documenting this
explicit-only behaviour so that contributors adding a new bash auto-detect
heuristic understand the intentional design decision.

## Where Each Script Lives

- `scripts/detect-signals.sh` — ecosystem-name detection; emits JSON
- `scripts/load-stack-persona.sh` — persona-token resolution and agent file loading
