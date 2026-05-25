# `defectdojo-export.sh` — opt-in DefectDojo export (E104-S4 / AC4)

POSTs the merged SARIF (`sarif-merge.sh` output) to a configured
[DefectDojo](https://www.defectdojo.org/) instance for centralized vulnerability
management — **only when explicitly enabled**.

## Why opt-in (not default)

DefectDojo requires a **Django + PostgreSQL + Celery + Redis** stack to run. That
is far too heavy to impose as a default brownfield dependency. Operators who already
run DefectDojo (or want centralized vuln management) can opt in; everyone else pays
nothing — when disabled, the export path is skipped entirely with **zero network
calls and no token requirement**.

## Contract

- **Disabled by default.** `brownfield.defectdojo_enabled` defaults to `false` →
  INFO skip, exit 0, no network. Resolved via `resolve-config.sh --field
  brownfield.defectdojo_enabled` and exported as `GAIA_BROWNFIELD_DEFECTDOJO_ENABLED`.
- **Enabled but mis-configured.** Missing `api_url` / `api_token` / `engagement_id`
  → WARN + skip (no failure) rather than abort Phase 7.
- **Fire-and-forget.** No synchronous wait on the DefectDojo response beyond the POST;
  a failed POST is a WARN, not a Phase 7 abort (avoids coupling Phase 7 latency to an
  external service).
- **Idempotent.** DefectDojo's reimport API dedups via `engagement_id` + `scan_type`,
  so repeated brownfield runs against the same merged SARIF do not create duplicates.

## Config keys

| Key | Purpose |
|-----|---------|
| `brownfield.defectdojo_enabled` | opt-in toggle (default `false`) |
| `brownfield.defectdojo_api_url` | DefectDojo import endpoint |
| `brownfield.defectdojo_api_token` | API token — supply via env-var reference, never a literal secret in config |
| `brownfield.defectdojo_engagement_id` | engagement id for dedup idempotency |

> Credentials follow the GAIA env-var-only credential policy (NFR-RSV2-7): the config
> holds the NAME of the env var, never the literal token.
