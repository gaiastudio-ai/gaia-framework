# Publish Adapter Contract (FR-526 + ADR-113 + ADR-037 envelope + SR-77)

This document defines the contract every `/gaia-publish` adapter must satisfy. Built-in adapters live under `publish-<channel>/`; custom adapters live under `<project-root>/.gaia/custom/adapters/publish-<adapter_name>/` (custom shadows built-in per ADR-020 precedence — see E100-S8).

## Adapter Layout (ADR-113 §clause (a))

Each adapter directory contains:

```
publish-<channel>/
├── adapter-manifest.yaml   # validated against schemas/adapter-manifest.schema.json
├── run.sh                  # entry point (CLI shape below)
└── schema.yaml             # per-channel distribution sub-field schema (per E99-S2)
```

## Uniform CLI Shape (FR-526 / AC2)

The orchestrator dispatches `run.sh` with EXACTLY these flags:

```
run.sh \
  --action {trigger|verify} \
  --manifest <absolute-path-to-version-bearing-manifest> \
  --version <semver-or-channel-version-string> \
  --registry <registry-url-or-identifier> \
  --output <absolute-path-to-findings.json>
```

Adapters MAY accept additional `--<channel-specific>` flags sourced from `distribution.<sub-field>` entries (orchestrator passes through verbatim). Adapters SHALL fail-closed on unknown arguments — typos surface as hard errors, not silent drops.

## ADR-037 Envelope (ADR-113 §clause (b))

`run.sh` MUST write a `findings.json` matching:

```json
{
  "verdict": "PASSED" | "FAILED" | "UNVERIFIED",
  "evidence": [
    {"type": "log-excerpt" | "registry-response" | "manifest-hash",
     "content": "...",
     "source": "..."}
  ],
  "summary": "one-paragraph human-readable summary",
  "adapter_metadata": {
    "adapter_name": "publish-<channel>",
    "adapter_version": "<semver>",
    "channel": "<channel>",
    "action": "trigger" | "verify"
  }
}
```

**Three-state verdict (closed list):**
- `PASSED` — action succeeded.
- `FAILED` — action did not succeed; orchestrator HALTs and surfaces `evidence` to the user.
- `UNVERIFIED` — adapter could not produce a verdict (e.g., registry propagation lag); orchestrator continues with human-review note. Only valid for channels with intrinsically unbounded propagation (`mobile-app`).

Envelope shape is validated by `scripts/lib/validate-adr037-envelope.sh` before the orchestrator reads `verdict`. Schema violations are HALT-distinct from `verdict: FAILED` (see "Exit-code discipline" below).

## Exit-Code Discipline (ADR-113 §clause (b) + (d).6 / AC4)

- **Exit 0 + envelope written** → "adapter ran cleanly". `verdict` is authoritative (PASSED / FAILED / UNVERIFIED).
- **Exit non-zero + envelope NOT written** → `adapter-internal-failure`. Orchestrator HALTs with `STEP4_REASON=adapter-internal-failure`. DISTINCT from `verdict: FAILED`.
- **Envelope written but malformed** (missing `verdict`, `verdict` outside enum, `evidence` not an array, malformed JSON) → `envelope-schema-violation`. Orchestrator HALTs with `STEP4_REASON=envelope-schema-violation`. DISTINCT from `verdict: FAILED` and `adapter-internal-failure`.

The orchestrator SHALL NOT infer verdict from exit code alone — verdict is read from the envelope.

## adapter-manifest.yaml (ADR-113 §clause (c))

Each adapter ships an `adapter-manifest.yaml` co-located with `run.sh`. Schema: `plugins/gaia/schemas/adapter-manifest.schema.json`. Required fields:

| Field | Type | Notes |
|---|---|---|
| `adapter_name` | string | `publish-<channel>` pattern |
| `adapter_version` | string | Semver |
| `channel` | enum | One of 10 first-class channels + `custom` |
| `verify_retry_window_seconds` | integer\|null | Per-NFR-082 retry window. SR-83 caps at 3600s. `null` only valid for `mobile-app` |
| `credential_env_vars` | array | Per-channel SR-77 allowlist (see below) |
| `description` | string | Human-readable |

Top-level `additionalProperties: false` — extraneous fields rejected as CRITICAL.

## SR-77 — Per-Channel `credential_env_vars` Allowlist

The schema enforces per-channel allowlists via `allOf` + `if/then` chains:

| Channel | Permitted `credential_env_vars` |
|---|---|
| `npm` | `NPM_TOKEN`, `NPM_REGISTRY_URL` |
| `pypi` | `PYPI_API_TOKEN` |
| `github-releases` | `GH_TOKEN`, `GITHUB_TOKEN` |
| `homebrew` | `HOMEBREW_GITHUB_TOKEN` |
| `container-registry` | `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` |
| `claude-marketplace` | `CLAUDE_MARKETPLACE_TOKEN` |
| `static-site` | `NETLIFY_TOKEN`, `VERCEL_TOKEN`, `CF_API_TOKEN`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` |
| `mobile-app` | (none — `maxItems: 0`) |
| `maven` | `MAVEN_USERNAME`, `MAVEN_PASSWORD`, `MAVEN_GPG_PASSPHRASE` |

## SR-83 — `verify_retry_window_seconds` Cap

Schema-side `maximum: 3600` enforces the SR-83 ceiling. Runtime defensive cap in `gaia-publish.sh::_step4_post_publish_verify` clamps any manifest-declared value exceeding 3600s back to 3600s and logs a WARNING. Mitigates T-PUB-4 (local DoS via malicious manifest declaring e.g. 86400s).

## NFR-081 — Credential Isolation (audit-enforced)

Adapters MUST source credentials ONLY from environment variables declared in
their `adapter-manifest.yaml::credential_env_vars` list. No reads from
`~/.npmrc`, `~/.pypirc`, `~/.aws/credentials`, `~/.docker/config.json`,
keychain, or other ambient credential sources are permitted.

**SR-76 deny-list** (audit-enforced at `tests/adapters/credential-isolation.bats`):
`~/.npmrc`, `~/.aws/`, `~/.docker/config.json`, `security find-internet-password`,
`aws configure`, `gcloud auth`, `keychain`. The audit extends to custom adapters
under `.gaia/custom/adapters/publish-*/run.sh` per SR-76.

**Three-dimension audit** (E100-S9):
1. **Dimension 1 — manifest declaration** (TC-NFR-081-1): each adapter manifest
   declares non-empty `credential_env_vars:` (or empty `maxItems: 0` for the
   `mobile-app` STUB per SR-77).
2. **Dimension 2 — static grep** (TC-PUB-11 + TC-NFR-081-2): no hardcoded
   credential patterns (`AKIA*`, `-----BEGIN`, `ghp_*`, etc.) in adapter
   source.
3. **Dimension 3 — runtime no-implicit-reads** (TC-NFR-081-3): adapter
   invoked with declared env vars UNSET + poisoned `~/.npmrc`/`~/.pypirc`/etc.
   in `$HOME` MUST NOT silently consume the ambient credential.

**T-PUB-1** (DREAD 5.8 High) and **T-PUB-2** (DREAD 5.4 Medium) are closed as
permanent regression-class defects by this audit. Any regression in a future
adapter PR fails CI via the directory-sweep bats pickup.

## References

- FR-526 (uniform adapter CLI shape)
- ADR-113 §(a)(b)(c) (location + envelope + manifest schema)
- ADR-037 (3-state envelope)
- ADR-020 (custom-shadows-built-in precedence — implemented by E100-S8)
- SR-77 (per-channel credential_env_vars allowlist)
- SR-83 (verify_retry_window_seconds.maximum=3600 cap)
- NFR-082 (per-adapter retry window)
