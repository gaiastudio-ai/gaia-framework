---
name: gaia-review-api
description: Review REST API design against standards and best practices — resource naming conventions, HTTP methods, status codes, RFC 7807 error format, versioning strategy. Produces a markdown findings report organised by category with severity levels. Use when "review API design" or /gaia-review-api.
argument-hint: "[target — API spec, OpenAPI doc, or route code]"
allowed-tools: [Read, Write, Edit, Bash, Grep]
orchestration_class: reviewer
---

## Mission

You are performing a **REST API design review** on the target the user supplies — an OpenAPI spec, route definitions, or API implementation code. You evaluate the target across four categories: resource naming conventions, HTTP method usage + status codes, error response format (RFC 7807), and versioning strategy. You produce a markdown findings report organised by category with per-finding severity and recommendation.

This skill is the native Claude Code conversion of the legacy `_gaia/core/tasks/review-api-design.xml` task (38 lines). Per **ADR-041** (Native Execution Model) and **ADR-042** (Scripts-over-LLM for Deterministic Operations), the legacy task-runner engine is retired and this skill runs natively under the Claude Code primitives model. Deterministic report-header generation is delegated to the shared foundation script `template-header.sh` (E28-S16) rather than re-prosed per skill.

## Critical Rules

- **Check naming conventions, HTTP methods, status codes.** Resources are plural nouns, URLs are kebab-case, URLs contain no verbs; HTTP methods carry the verb (GET / POST / PUT / PATCH / DELETE); status codes are appropriate (2xx / 4xx / 5xx).
- **Verify versioning strategy.** The API MUST declare a versioning scheme — URL-path (`/v1/`), custom header (`Api-Version`), media-type versioning, or query param. Lack of versioning is a critical finding.
- **Reference RFC 7807 for error responses.** Errors MUST follow RFC 7807 (Problem Details for HTTP APIs) or a consistent documented pattern — type, title, status, detail, instance.
- The review is READ-ONLY on the target — findings go in the report artifact, not inline edits.

## Inputs

- `$ARGUMENTS`: optional target (API spec file, OpenAPI YAML/JSON, routes source file, or directory). If omitted, ask the user inline: "Which API spec or route code should I review?"

## Steps

### Step 1 — Scope

- If `$ARGUMENTS` is non-empty, resolve it as the target. Otherwise ask the user inline for the API spec or route code (preserves the legacy Step 1 "Ask user for API specification or code to review" behavior — AC-EC4).
- Read the target file(s). If a directory is given, recursively read all relevant API-definition files.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-api 1 api_spec_path="$API_SPEC_PATH" review_scope="$REVIEW_SCOPE"`

### Step 2 — Naming Conventions

- Check resource naming: plural nouns (`/users` not `/user`), kebab-case in path segments (`/audit-logs` not `/auditLogs`), no verbs in URLs (prefer `GET /orders/{id}/items` over `GET /getOrderItems`).
- Verify consistent naming across endpoints — pluralisation, casing, hyphenation must be uniform.
- Check path parameter naming — `{id}`, `{userId}`, consistent casing.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-api 2 api_spec_path="$API_SPEC_PATH" review_scope="$REVIEW_SCOPE" review_stage=naming`

### Step 3 — HTTP Methods and Status Codes

- Verify correct HTTP method usage:
  - `GET` — safe, idempotent retrieval
  - `POST` — create or non-idempotent action
  - `PUT` — idempotent full replacement
  - `PATCH` — partial update
  - `DELETE` — remove
- Check status codes are appropriate:
  - `200 OK`, `201 Created`, `202 Accepted`, `204 No Content` for success
  - `400 Bad Request`, `401 Unauthorized`, `403 Forbidden`, `404 Not Found`, `409 Conflict`, `422 Unprocessable Entity` for client error
  - `500`, `502`, `503`, `504` for server error
- Flag misuse (e.g., returning `200` with an error body, or using `POST` where `PATCH` is correct).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-api 3 api_spec_path="$API_SPEC_PATH" review_scope="$REVIEW_SCOPE" review_stage=methods-codes`

### Step 4 — Error Format and Versioning

- Check the error response format follows RFC 7807 (Problem Details) or a consistent documented pattern. Required RFC 7807 fields: `type`, `title`, `status`; recommended: `detail`, `instance`. Deviations are flagged with severity.
- Verify the API declares a versioning strategy — URL segment (`/v1/`), custom header (`Api-Version: 1`), media-type (`Accept: application/vnd.example+json; version=1`), or query parameter. Lack of versioning is a critical finding.
- Verify breaking changes follow the declared versioning strategy — additive changes inside a major version, breaking changes require a new version.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-api 4 api_spec_path="$API_SPEC_PATH" review_scope="$REVIEW_SCOPE" review_stage=errors-versioning`

### Step 4b — Cross-Cutting REST Concerns (Test05 F-020)

Beyond naming/methods/errors/versioning, review the cross-cutting concerns that
distinguish a production-grade REST API. Each is flagged with severity when
absent or incorrect (skip a concern with an INFO note when it is genuinely
inapplicable to the API's domain — e.g. rate limiting on a purely internal
service):

- **Idempotency.** `GET`/`PUT`/`DELETE` must be idempotent; non-idempotent
  `POST` create endpoints that can be safely retried should accept an
  `Idempotency-Key` request header. Flag retry-unsafe mutating endpoints.
- **Pagination.** Collection endpoints must declare a pagination strategy —
  cursor-based (`?cursor=…&limit=…`, preferred for large/changing sets) or
  offset/limit (`?offset=…&limit=…`). Verify a documented default + maximum
  `limit`, and a stable ordering. Unbounded list endpoints are a finding.
- **Content negotiation.** Verify `Accept` / `Content-Type` handling, the
  documented default media type, `406 Not Acceptable` / `415 Unsupported Media
  Type` on mismatch, and (where applicable) compression (`Accept-Encoding`).
- **Rate limiting.** Verify a documented rate-limit policy and the standard
  response surface — `429 Too Many Requests` with `Retry-After` and
  `RateLimit-Limit` / `RateLimit-Remaining` / `RateLimit-Reset` headers.
- **Auth scheme.** Verify the authentication scheme is declared and consistent
  (OAuth2 / OIDC bearer, API key, mTLS), that `401` vs `403` are used correctly
  (unauthenticated vs unauthorized), and that scopes/permissions are documented
  per endpoint. Endpoints with no declared auth on a non-public API are a
  critical finding.

These cross-cutting concerns are part of the Step 4 review pass — they do NOT add a separate numbered step or checkpoint (the canonical step count + per-step checkpoint contract is preserved; their findings fold into the Step 4 → Step 5 report flow).

### Step 5 — Report

Invoke the shared foundation script to emit the deterministic artifact header (ADR-042):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/template-header.sh --template api-design-review --workflow gaia-review-api
```

If `template-header.sh` is missing or non-executable (AC-EC7), degrade gracefully to an inline prose header (`# API Design Review — {date}`), log a warning, and still write a valid report.

Write the report to the following path (preserved verbatim from the legacy task — AC4):

```
{planning_artifacts}/api-design-review-{date}.md
```

If the file already exists for the same day (AC-EC3), write to a suffix-incremented filename (`api-design-review-{date}-2.md`, ...).

**Output override + location note (Test05 F-021).** The default lives under `planning-artifacts/` because the API DESIGN review is a planning-phase artifact (it reviews the API contract before implementation), aggregated alongside the other design reviews. To redirect it, pass `--output <path>` in `$ARGUMENTS` or set `GAIA_API_REVIEW_REPORT_PATH`. Resolution precedence: `--output` arg > `GAIA_API_REVIEW_REPORT_PATH` env > the default `{planning_artifacts}/api-design-review-{date}.md`. An explicit override skips the same-day suffix logic (the caller owns collision handling). The eventual single-source review-path consolidation is tracked by E105-S4.

The report is organised by category (naming, HTTP methods, status codes, error format, versioning, idempotency, pagination, content negotiation, rate limiting, auth scheme). Each finding row includes: category, severity (critical / high / medium / low), endpoint or location, finding description, recommendation.

If the target is empty or resolves to no API definitions (AC-EC6), exit with `No review target resolved` and do NOT write an empty report.

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-api 5 api_spec_path="$API_SPEC_PATH" review_scope="$REVIEW_SCOPE" review_stage=report --paths "$REPORT_PATH"`

### Step 6 — Val Auto-Fix Loop (E44-S2 / ADR-058)

> Reuses the canonical pattern at `gaia-public/plugins/gaia/skills/gaia-val-validate/SKILL.md`
> § "Auto-Fix Loop Pattern". Do not duplicate the spec here; cite this anchor.

**Guards (run before invocation):**

- Artifact-existence guard (AC-EC3): if not exists `$REPORT_PATH` (the actual resolved write path emitted by Step 5, which may be `.gaia/artifacts/planning-artifacts/api-design-review-{date}.md` or a same-day suffix-incremented variant such as `api-design-review-{date}-2.md`) -> skip Val auto-review and exit (no Val invocation, no checkpoint, no iteration log).
- Val-skill-availability guard (AC-EC6): if `/gaia-val-validate` SKILL.md is not resolvable at runtime -> warn `Val auto-review unavailable: /gaia-val-validate not found`, preserve the artifact, and exit cleanly.

**Loop:**

1. iteration = 1.
2. Invoke `/gaia-val-validate` with `artifact_path = $REPORT_PATH`, `artifact_type = api-design-review`. The `artifact_path` MUST be the runtime-resolved path captured by Step 5 (post-suffix-increment), NOT the templated `api-design-review-{date}.md` literal — see story E44-S5 AC-EC3.
3. If findings is empty: proceed past the loop.
4. If findings contains only INFO: log informational notes, proceed past the loop.
5. If findings contains CRITICAL or WARNING:
     a. Apply a fix to `$REPORT_PATH` addressing the findings.
     b. Append an iteration log record to checkpoint `custom.val_loop_iterations`.
     c. iteration += 1.
     d. If iteration <= 3: go to step 2.
     e. Else: present the iteration-3 prompt verbatim (centralized in `gaia-val-validate` SKILL.md § "Auto-Fix Loop Pattern") and dispatch.

YOLO INVARIANT: the iteration-3 prompt MUST NOT be auto-answered under YOLO. This wire-in does not introduce a YOLO bypass branch. See ADR-057 FR-YOLO-2(e) and ADR-058 for the hard-gate contract.

> Val auto-review per E44-S2 pattern (ADR-058, architecture.md §10.31.2).

> `!${CLAUDE_PLUGIN_ROOT}/scripts/write-checkpoint.sh gaia-review-api 6 api_spec_path="$API_SPEC_PATH" review_scope="$REVIEW_SCOPE" stage=val-auto-review --paths "$REPORT_PATH"`

## References

- Source: `_gaia/core/tasks/review-api-design.xml` (legacy 38-line task body — ported per ADR-041 + ADR-042).
- ADR-041: Native Execution Model via Claude Code Skills + Subagents + Plugins + Hooks.
- ADR-042: Scripts-over-LLM for Deterministic Operations.
- ADR-048: Engine Deletion as Program-Closing Action — legacy task coexists until program close.
- FR-323: Skill Conversion — slash-command identity preserved.
- NFR-053: Full v1.127.2-rc.1 Feature Parity.
- RFC 7807: Problem Details for HTTP APIs.
