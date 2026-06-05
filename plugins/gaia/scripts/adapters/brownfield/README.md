# Brownfield deterministic-tools adapters

Adapters invoked by `/gaia-brownfield` Phase 3 pre-flight, gated behind the
deterministic-tools master flag and per-tool overrides.

## `pre-warm.sh`

Runs `grype db check || grype db update` and primes cdxgen package-registry
caches **before** the Phase 3 scan timer starts, so a cold CI runner does not
pay the 15–30s Grype DB cold-fetch + cdxgen warm-up against the 120s
WARNING budget.

### Contract

- **Flag gate.** Invoked only when the master flag
  `brownfield.deterministic_tools: true` AND the per-tool override
  `brownfield.prewarm_enabled: true` resolve true. `/gaia-brownfield`
  resolves these via `resolve-config.sh` and exports
  `GAIA_BROWNFIELD_DETERMINISTIC_TOOLS` / `GAIA_BROWNFIELD_PREWARM_ENABLED`
  into the script's environment. Flag-off → INFO skip, exit 0, no work.
- **Graceful degrade.** Missing `grype` or `cdxgen` → WARNING + exit 0 (never
  abort Phase 3). `grype db update` network failure → one retry, then WARNING +
  exit 0. Exit code is ALWAYS 0 — pre-flight degrade must never block the scan
  cohort.
- **Idempotent warm path.** DB present + fresh (`grype db status`, client-side,
  no network) AND a cdxgen sentinel marker younger than
  `GAIA_PREWARM_MAX_AGE_DAYS` (default 5) → emit `cache warm`, exit 0, **zero
  network I/O**.
- **Checksum log.** Appends one JSONL row per invocation
  to `.gaia/memory/brownfield-audit/grype-db-checksum.log`:
  `{"ts": <ISO-8601>, "session_id": <id>, "checksum": <sha256>, "db_built_age_seconds": <int>}`.
  The trust-boundary enforcement consumer reads the last row for the current
  session and rejects checksum drift / over-age DBs. This script is the
  producer only; do not pre-empt the consumer's enforcement here.

### Environment seams

| Variable | Purpose | Default |
|----------|---------|---------|
| `GAIA_BROWNFIELD_DETERMINISTIC_TOOLS` | master flag | `true` |
| `GAIA_BROWNFIELD_PREWARM_ENABLED` | per-tool override | `true` |
| `GAIA_BROWNFIELD_AUDIT_DIR` | checksum-log dir | `${GAIA_MEMORY_DIR}/brownfield-audit` |
| `GAIA_PREWARM_CACHE_DIR` | cdxgen sentinel-marker dir | `${AUDIT_DIR}/prewarm-cache` |
| `GAIA_GRYPE_DB_FILE` | grype-db.sqlite to checksum | best-effort discovery |
| `GAIA_SESSION_ID` | session id for the JSONL row | `$PPID` |
| `GAIA_PREWARM_MAX_AGE_DAYS` | warm-cache freshness threshold | `5` |

## Binary supply-chain pinning

`grype` and `cdxgen` MUST be version-pinned via checksum verification in the CI
image, following the **Trivy March 2026 supply-chain compromise** precedent. In
that incident a poisoned Trivy DB / distribution was caught by three independent
incident-response sources — **Microsoft IR + Aqua Security + CrowdStrike** — and
the remediation pattern that emerged is: never pull a security scanner or its
vulnerability DB unpinned; verify the published SHA-256 of the binary (and, where
feasible, the DB build) before invocation.

**Pinning recipe (to land in the CI image / dependency workflow):**

1. Pin exact `grype` and `cdxgen` release versions (no floating `latest`).
2. Fetch the vendor-published SHA-256 for each release artifact.
3. Verify the downloaded binary's `sha256sum` against the published value
   BEFORE adding it to the runner image; fail the image build on mismatch.
4. Record the pinned version + checksum in the dependency manifest so drift is
   reviewable.

> **Status:** This repo does not yet carry a dedicated dependency-pinning
> CI workflow (`.github/workflows/dependencies.yml` or equivalent). The pinning
> rationale + recipe are documented here; wiring the actual checksum-verified
> install into CI infra is tracked as a finding for the infra owner.
