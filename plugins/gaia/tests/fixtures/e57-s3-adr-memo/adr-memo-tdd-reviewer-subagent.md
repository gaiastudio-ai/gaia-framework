# ADR Memo — TDD-Reviewer Subagent Contract

| Field        | Value                                                                                  |
|--------------|----------------------------------------------------------------------------------------|
| Story        | E57-S3 — TDD review subagent contract                                                  |
| Date         | 2026-04-28                                                                             |
| Author       | gaia-dev-story                                                                         |
| Status       | Accepted                                                                               |
| Cross-refs   | ADR-037 (finding shape), ADR-063 (verdict surfacing), ADR-067 (hard-CRITICAL)          |

## Context

The `/gaia-dev-story` workflow's `QA_AUTO` (and its non-YOLO peer `route-to-qa`) branch needs a fork-context subagent that consumes the Red/Green/Refactor diff, runs a 14-item TDD checklist (7 after-Red + 4 after-Green + 3 after-Refactor), and emits an ADR-063 verdict (`PASSED` / `FAILED` / `UNVERIFIED`) plus an ADR-037 findings list. The agent runs in a **forked context** so its working memory does not pollute the main dev-story session, and runs with a **read-only tool allowlist** (`Read`, `Grep`, `Glob`, `Bash`) so it cannot rewrite the diff it reviews.

Today, the closest existing agent is `qa.md` (Vera). Vera is `context: main` with a **test-generation** persona and a full edit allowlist (`Read, Write, Edit, Bash, Grep, Glob`). Vera and the TDD-reviewer have orthogonal contracts: Vera produces test code, the TDD-reviewer reads diffs and emits verdicts. Two questions follow:

1. Should the TDD-reviewer be a **new dedicated agent** (Option A), or
2. Should `qa.md` be **split into two files** (Option B), e.g., `qa.md` + `qa-tdd-review.md`, with the second one carrying the fork-context contract?

This memo records the decision and rationale before the contract surface ships.

## Option A — New dedicated `tdd-reviewer.md`

Author a new file at `gaia-public/plugins/gaia/agents/tdd-reviewer.md`. Frontmatter is `context: fork`, `allowed-tools: [Read, Grep, Glob, Bash]`, model `claude-opus-4-6`. The persona owns the 14-item checklist and the verdict-emission contract. `qa.md` (Vera) is left untouched.

**Pros:**

- **Single responsibility** — Vera keeps the test-generation contract, TDD-reviewer keeps the diff-review contract. No file mixes two distinct ADR-063 verdict surfaces.
- **Allowlist clarity** — Vera's edit allowlist (`Write, Edit`) and the reviewer's read-only allowlist (`Read, Grep, Glob, Bash`) live in separate files where the lint suite can pin each contract independently.
- **Pattern match** — `validator.md` (Val) is already a fork-context, read-only review agent at `[Read, Grep, Glob]`. A new `tdd-reviewer.md` uses the same pattern, lowering reader load for anyone new to the codebase.
- **Downstream wiring is simpler** — E57-S4's SKILL.md gate-wiring story dispatches by agent name (`tdd-reviewer`). A dedicated file means no aliasing or context-mode flip logic at dispatch time.
- **Backward compatibility** — every consumer of `qa.md` keeps its current behaviour. No surprise context-mode change for downstream callers of Vera.

**Cons:**

- **One more file** — agent count goes from 28 to 29. Marginal. Lint and discovery already iterate over `agents/*.md`.
- **Persona duplication risk** — TDD-reviewer needs some QA-engineering tone overlap with Vera. Mitigated by keeping the reviewer's persona scoped tightly to the 14-item checklist; cross-cutting QA tone lives in Vera.

## Option B — Split `qa.md` into `qa.md` + `qa-tdd-review.md`

Keep Vera as `qa.md` for test generation, and add a sibling file `qa-tdd-review.md` carrying the same persona name (`Vera`) but with `context: fork` and the read-only allowlist. Both files would share Vera's identity but expose two distinct contracts.

**Pros:**

- **Persona continuity** — Vera owns both surfaces. From a roleplay perspective, the same engineer does test generation in main-context and TDD review in fork-context.
- **Smaller cognitive map** — Reviewers and developers only need to remember one persona name (`Vera`) for both QA-related contracts.

**Cons:**

- **Two files, one persona, two `name:` fields** — The frontmatter `name:` field is the canonical agent id used by Claude Code's dispatch and by `memory-loader.sh`. If both files use `name: qa`, dispatch is ambiguous; if they use `name: qa` and `name: qa-tdd-review`, the persona/identity claim is split across two ids and the marketplace listing is duplicated.
- **Allowlist drift risk** — Two files claiming to be Vera with different allowlists invites accidental edits where the wrong allowlist gets copied over the other during a future refactor. The lint suite cannot easily enforce "these two files belong to the same persona but must have different allowlists."
- **Context-mode flip is not natively supported** — Claude Code subagent frontmatter pins `context` per file. There is no native split of a single subagent across two context modes. Option B is effectively Option A with a forced shared persona-name claim.
- **Discoverability hurt** — A user looking for "TDD reviewer" greps the agents directory; with Option B, the file matching `tdd-review` lives under a `qa-` prefix, which is not where the search lands.

## Chosen: Option A

This memo records **Option A** as the chosen path. The TDD-reviewer ships as a new dedicated agent at `gaia-public/plugins/gaia/agents/tdd-reviewer.md`. `qa.md` (Vera) is not modified.

### Rationale

The decisive argument is the schema in `agents/_SCHEMA.md`: the `name:` field is the canonical dispatch id, and the schema does not support a single persona spanning two context modes via two files with different `name:` values. Option B's "share the persona name across two files" is incompatible with the dispatch contract; Option B's "give them different `name:` values" collapses into Option A with a confusing `qa-` prefix on a non-Vera contract.

Once that argument is accepted, the remaining differences favour Option A:

- Pattern match with `validator.md` lowers reader load for anyone new to the codebase.
- Allowlist isolation lets the lint suite pin each file's contract independently.
- Backward compatibility — Vera's contract is unchanged for every existing caller.
- Downstream E57-S4 dispatch by agent name (`tdd-reviewer`) is a single-line lookup with no aliasing.

The marginal "one more file" cost is the only Option A downside, and it does not move the needle against the dispatch-contract argument.

### Persona name for the chosen agent

The chosen agent file uses `name: tdd-reviewer` and persona name **Tex** (TDD reviewer). The persona is distinct from Vera so that the dispatch-by-name path is unambiguous and so the marketplace listing for the TDD-reviewer surfaces under its own role rather than aliasing onto Vera.

## Consequences

- A new file ships at `gaia-public/plugins/gaia/agents/tdd-reviewer.md`.
- `qa.md` is unchanged; Vera continues to own test generation in main context.
- E57-S4 (SKILL.md gate wiring) dispatches by agent name `tdd-reviewer`.
- Bats coverage at `gaia-public/plugins/gaia/tests/tdd-reviewer-agent-contract.bats` pins the contract: frontmatter shape, 14-item checklist, ADR-037/063/067 references, audit-file path, and `qa_timeout_seconds` consumption.

## References

- `gaia-public/plugins/gaia/agents/_SCHEMA.md` — frontmatter schema (`name`, `context`, `allowed-tools`).
- `gaia-public/plugins/gaia/agents/validator.md` — reference fork-context, read-only review agent.
- `gaia-public/plugins/gaia/agents/qa.md` — Vera, test-generation persona left intact under Option A.
- `docs/planning-artifacts/architecture.md` §Decision Log — ADR-037, ADR-063, ADR-067.
- `docs/test-artifacts/test-plan.md` §11.51 — TC-TDR-05/06/07/08.
- `docs/test-artifacts/atdd-E57-S3.md` — failing test scenarios for this story.
