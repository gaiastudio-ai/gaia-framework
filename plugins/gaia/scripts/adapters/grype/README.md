# Grype adapter — DB trust-boundary enforcement (E70-S9 / FR-542 / ADR-122)

`adapter.sh` runs the Grype CVE scan in `/gaia-brownfield` Phase 3 and treats the
Grype **vulnerability DB as a trust boundary distinct from the binary**.

## Trust-boundary rationale

Grype's built-in `--db-check-schema` validates that the SQLite DB matches the
*format* the binary expects. That guards against version-skew breakage — it does
**NOT** guard against an attacker swapping the DB *contents* while preserving the
schema. **Schema-version pinning is insufficient: it guards format compatibility,
not content integrity.** This adapter closes that gap with three controls:

1. **Max-age bound** — exports `GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d` so Grype itself
   rejects a deeply stale DB. An inherited override `!= 5d` is rejected at
   pre-flight (default FAIL — secure default).
2. **Checksum logging** — records the DB SHA-256 (`grype_db_checksum`) and built
   age (`grype_db_built_age`) in the brownfield report frontmatter.
3. **Mid-session drift rejection** — compares the current DB SHA-256 against the
   session-start checksum (produced by E70-S7 `pre-warm.sh`); on drift it ABORTS
   the scan with a non-zero exit (security failure, not a degrade).

## Trivy March 2026 precedent

The trust-boundary design follows the **Trivy March 2026 supply-chain compromise**,
verified via a triple-source incident response — **Microsoft IR + Aqua Security +
CrowdStrike**. In that incident a poisoned scanner DB / distribution was the attack
vector; the lesson is that a security scanner's *data* must be integrity-checked
independently of its *binary version*.

## Why 5d max-age

Grype DB rebuilds typically run daily. A 5-day window gives ~4 days of slack for
runner-side caching while still rejecting deeply stale DBs. Tighter windows (1–2d)
produced false positives on legitimate stale runners in pre-cascade testing.

## Checksum-drift operator runbook

When the adapter aborts with
`ERROR: Grype DB checksum drift detected mid-session (session=<id>, expected=<sha>, actual=<sha>)`:

1. **Do not retry blindly** — the drift is a security signal.
2. Audit the DB origin: where did the swapped DB come from? Check the runner's
   `grype db update` history and any concurrent process that may have rewritten it.
3. Rotate the session (new `GAIA_SESSION_ID`) and re-run `pre-warm.sh` to establish
   a fresh session-start checksum from a trusted DB.
4. Re-run the brownfield scan only after the DB origin is confirmed trusted.

> **Fail-open caveat.** Drift detection compares the current DB SHA-256 against the
> session-start checksum. If the DB file cannot be read/hashed (checksum resolves to
> `unavailable`), the drift comparison is SKIPPED and the scan proceeds — there is no
> checksum to compare. Grype's own `GRYPE_DB_MAX_ALLOWED_BUILT_AGE=5d` still applies.
> An unhashable DB therefore bypasses drift detection (but not the max-age bound).

## Config flag naming (key-spelling note)

The per-tool override is the flat depth-2 key `brownfield.grype_enabled` (default
true), not the story AC's hyphenated `brownfield.tools.grype.enabled`. The
`resolve-config.sh` nested-key parser supports only depth-3 ASCII-underscore
segments; the flat spelling preserves the ADR-078 master-flag + per-tool-override
SEMANTICS. Same constraint as `prewarm_enabled` / `sarif_merge_enabled` /
`dedup_enabled`.

## Binary supply-chain pinning (AC-X4 / NFR-86)

The `grype` binary MUST be version-pinned via checksum verification in the CI image
(Trivy Mar-2026 precedent), reusing the shared pinning machinery.

> **Status (E70-S9):** No dedicated dependency-pinning CI workflow exists yet
> (`.github/workflows/dependencies.yml`). The rationale is documented here; the CI
> wiring is tracked as a shared Finding (with E70-S7's grype/cdxgen + E104-S4's
> sarif pinning).

## Telemetry ownership (single-author per field)

This adapter is the single author of `grype_db_checksum`, `grype_db_built_age`,
`phase_runtime_seconds.grype`, `deterministic_tool_seconds.grype`, and (as a
deterministic tool) `llm_token_count: 0`. It does NOT write `gap_count_before_dedup`
/ `gap_count_after_dedup` — those are owned by the E104-S1 dedup phase (no fan-out).
