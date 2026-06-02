# Transcript fixture — clean (no fabricated user turns) (E76-S8 control)
#
# Sibling control fixture for `transcript-fabricated-user-turn.md`. Same
# meeting, same invitees, same per-turn-header schema (NFR-MTG-1) — but the
# two fabricated `${USER_NAME}` turns are removed and the only user-attributed
# content is a single `[i]nterject` turn whose `origin: interject` excludes it
# from the no-fabricated-user-turn check (per AC2 / TC-MTG-NOFAB-2).

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
  gaia-framework/plugins/gaia/skills/gaia-config-platform/SKILL.md
What I know:
  - The `add` subcommand never enumerates baseline platforms.

Speaker: Theo
Role: Architect
Phase: RESEARCH
origin: prelude
dispatched_via: subagent

[Prelude] Theo (Architect) — 250 tokens
Sources consulted:
  gaia-framework/plugins/gaia/skills/gaia-init/SKILL.md
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
origin: interject

[i]nterject "Please also add a list subcommand pre-flight."

Speaker: Theo
Role: Architect
Phase: DISCUSS
origin: turn
dispatched_via: subagent

`claude-code-plugin` is a `project_kind`, not a platform — promoting it would
either be a no-op warn or require schema-wide changes. Cited:
`gaia-framework/plugins/gaia/skills/gaia-init/SKILL.md` Step 2.2 option 6.

## Phase: CLOSE

(Decisions and action items elided in fixture.)
