# Transcript fixture — fabricated user turns (E76-S8 regression evidence)
#
# Reconstructed from the 2026-05-08 live `/gaia-meeting` run captured at
# `docs/creative-artifacts/meeting-2026-05-08-platform-config-discoverability.md`.
# That digest does NOT preserve per-turn `Speaker:` headers byte-for-byte —
# this fixture matches the NFR-MTG-1 per-turn-header schema (Speaker, Role,
# Phase, origin, optional dispatched_via per E76-S10).
#
# The user-name placeholder `${USER_NAME}` is expanded at test time via
# `scripts/resolve-user-name.sh` so the test works on any CI runner.
#
# Two fabricated user turns are present below: one in RESEARCH (prelude) and
# one in DISCUSS (round 1). The bats check MUST detect both — either is
# sufficient to fail the test.

## Phase: INVITE

Invitees: Christy, Theo, Derek, Soren, Vera

## Phase: CHARTER

When configuring a project through `/gaia-init` or `/gaia-config-*`, the
platform options are confusing.

## Phase: RESEARCH

Speaker: Christy
Role: Product Designer
Phase: RESEARCH
origin: prelude
dispatched_via: subagent

[Prelude] Christy (Product Designer) — 320 tokens
Sources consulted:
  gaia-public/plugins/gaia/skills/gaia-config-platform/SKILL.md
What I know:
  - The `add` subcommand never enumerates baseline platforms.

Speaker: ${USER_NAME}
Role: User
Phase: RESEARCH
origin: prelude

[Prelude] ${USER_NAME} (user) — 80 tokens
Sources consulted:
  (none)
What I know:
  - I want backend / frontend / mobile categories.

Speaker: Theo
Role: Architect
Phase: RESEARCH
origin: prelude
dispatched_via: subagent

[Prelude] Theo (Architect) — 250 tokens
Sources consulted:
  gaia-public/plugins/gaia/skills/gaia-init/SKILL.md
What I know:
  - Step 2.2 mixes topology and platform.

## Phase: DISCUSS

Speaker: Christy
Role: Product Designer
Phase: DISCUSS
origin: turn
dispatched_via: subagent

The `add` command should print the documented baseline (`web | ios | android`
per `docs/planning-artifacts/architecture.md` ADR-081 §4.2) when invoked with
no argument.

Speaker: ${USER_NAME}
Role: User
Phase: DISCUSS
origin: turn

I think the platform list should also include claude-plugin. [inference]

Speaker: Theo
Role: Architect
Phase: DISCUSS
origin: turn
dispatched_via: subagent

`claude-code-plugin` is a `project_kind`, not a platform — promoting it would
either be a no-op warn or require schema-wide changes. Cited:
`gaia-public/plugins/gaia/skills/gaia-init/SKILL.md` Step 2.2 option 6.

## Phase: CLOSE

(Decisions and action items elided in fixture.)
