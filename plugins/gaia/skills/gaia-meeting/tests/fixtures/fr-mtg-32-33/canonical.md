# Test fixture: canonical PRD shard excerpt

This fixture mirrors the canonical post-AF-2026-05-10-1 prose for
FR-MTG-32 / FR-MTG-33. It is the positive-control input for
`verify-fr-mtg-32-33-amendment.sh` — all seven checks must pass.

## 4.39 gaia-meeting

- **FR-MTG-32 — Checkpoint yield contract** (amended AF-2026-05-08-4: enforcement moves from LLM-discipline-side prose to script-side `yield-gate.sh` helper that emits the canonical prompt block AND a YIELD-STOP sentinel that ends the LLM turn at all five mandatory yield points; amended AF-2026-05-10-1: the script-side stdout-sentinel mechanism was empirically defeated by harness Auto Mode on 2026-05-09, so enforcement moves from script-side stdout-sentinel to substrate `AskUserQuestion` primitive — `yield-gate.sh` retains its session-state side effects but becomes side-effect-only; the LLM emits the AskUserQuestion call as the user-facing prompt mechanism). At each yield the skill MUST emit the canonical AskUserQuestion call with 4 explicit options — `[c]ontinue` / `[p]ause` / `[w]rap-up` / `[a]bort` — and 1 free-text auto-Other option carrying the `[i]nterject "<text>"` payload (the [i]nterject mapping to AskUserQuestion's automatic Other slot is intentional — interject already requires a quoted-text payload that exactly matches what auto-Other returns, per FR-MTG-33 `--interject "<text>"` semantics).

- **FR-MTG-33 — Session resumption and state file** (amended AF-2026-05-08-4: `yield-gate.sh` updates `last_checkpoint_phase` and `last_yield_emitted_at` BEFORE printing the YIELD-STOP sentinel; amended AF-2026-05-10-1: `yield-gate.sh` retains the same session-state writes but the YIELD-STOP sentinel emission is removed — the LLM-emitted AskUserQuestion call replaces the sentinel as the user-facing prompt mechanism, with the session-state writes still happening first to preserve the re-entry-consistency invariant). yield-gate.sh becomes side-effect-only under AF-2026-05-10-1 and no longer emits the YIELD-STOP sentinel. The session-state file at `_memory/meeting-sessions/{date}-{slug}.yaml` is the source of truth for re-entry.
