---
name: gaia-review-mobile
description: Mobile review gate — runs six validators (manifest auditor, entitlements, signing configuration, store metadata completeness, privacy manifest, universal-links / app-links) on iOS and Android projects, composes a layered rubric (mobile + regimes), produces a verdict via verdict-resolver.sh, and updates the Review Gate via review-gate.sh. Routed to Talia (mobile-dev) via agent-overlay.sh. Use when "review mobile" or /gaia-review-mobile.
argument-hint: "[story-key]"
command: /gaia-review-mobile
phase: implementation
verdict_producing: true
context: fork
allowed-tools: [Read, Grep, Glob, Bash]
triggers:
  - "review mobile"
  - "mobile review"
  - "/gaia-review-mobile"
orchestration_class: reviewer
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-review-mobile/scripts/setup.sh

## Mission

You are the **pre-merge mobile review gate** for iOS and Android projects. Six validators (manifest auditor, entitlements, signing configuration, store metadata completeness, privacy manifest, universal-links / app-links) run as the deterministic evidence layer; the LLM applies semantic judgment on top of that evidence; the verdict is computed by `verdict-resolver.sh`.

> Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.

This is the unifying principle of every GAIA review skill. For `gaia-review-mobile` it means: the six validators run first and emit a structured `analysis-results.json` artifact. The LLM then performs a semantic review **on top of** that artifact — it cannot disregard a CRITICAL finding (e.g., development-only entitlement in a Release build, undeclared required-reason API), and it cannot relabel a manifest auditor failure as APPROVE. The verdict is computed by `verdict-resolver.sh` from the deterministic checks plus the LLM findings; the LLM never computes the verdict in natural language.

This skill follows the seven-phase reviewer structure (Three-Tier Review Pipeline) and the layered-rubric model (Layered Rubric Loading). It is wired to Talia (Mobile Developer) via `agent-overlay.sh`.

**Scope:** mobile-as-platform extension. Validators are platform-aware — iOS-only validators (Info.plist, entitlements, PrivacyInfo.xcprivacy, AASA) skip when `platforms` excludes `ios`; Android-only validators (AndroidManifest.xml, assetlinks.json) skip when `platforms` excludes `android`. Cross-platform validators (signing config, store metadata) inspect whichever platform is configured.

**Fork context semantics:** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify source files — the tool allowlist enforces no-write isolation.

## Agent Wiring

This skill resolves to **Talia (Mobile Developer)**:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill gaia-review-mobile
# {"agent_id":"talia","sidecar_path":".gaia/memory/talia-sidecar.md"}
```

The persona is lazy-loaded by `load-stack-persona.sh` BEFORE fork dispatch — the parent context resolves the persona payload, then the fork inherits it. The fork tool allowlist `[Read, Grep, Glob, Bash]` stays intact.

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-review-mobile [story-key]".
- The story file MUST exist at `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug.
- The story MUST be in `review` status. If not, fail with "story must be in review status before mobile review".
- This skill is READ-ONLY. Do NOT attempt Write or Edit tools — the fork context allowlist enforces this.
- Platform-irrelevant validators MUST be skipped silently (e.g., iOS validators skip on `platforms: [android]`). Skipped validators do NOT contribute to the verdict.
- The signing-configuration validator MUST NOT access certificates, private keys, or signed `.mobileprovision` payloads. It validates configuration *references* and structural consistency only — never secrets.
- Findings are emitted as evidence items into `analysis-results.json` following the review-common schema; the verdict is computed by `verdict-resolver.sh`, never inline.
- Call `review-gate.sh` to update the "Review Gate" row — do NOT manually edit the story file.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Severity Rubric

> Severity rubric format defined in shared skill `gaia-code-review-standards`. Per-skill examples below conform to this format.

The merged rubric loaded in Phase 3A drives severity weighting for every finding emitted by the six validators. Findings carry `severity: CRITICAL | WARNING | INFO`.

### Critical
- iOS Info.plist missing `CFBundleIdentifier` / `CFBundleVersion` / `CFBundleShortVersionString`.
- AndroidManifest.xml missing `versionCode` / `minSdkVersion` / `targetSdkVersion`.
- Entitlements: development-only `get-task-allow=true` or `aps-environment=development` in a Release-built target.
- Signing: provisioning profile expired; bundle identifier mismatch between project and provisioning profile.
- Store metadata: required field absent (app name, description, privacy policy URL, age/content rating answers).
- Privacy manifest: `PrivacyInfo.xcprivacy` missing; required-reason API used without declared reason in `NSPrivacyAccessedAPITypes`.
- Universal-links: malformed apple-app-site-association (AASA) JSON; assetlinks.json wrong package name or fingerprint.

### Warning
- Deprecated key in Info.plist or AndroidManifest.xml (e.g., `READ_PHONE_STATE` without rationale).
- Provisioning profile expires within 30 days.
- Store metadata field exceeds character limit (e.g., 35-char app name, limit 30).
- Missing screenshots for a required device class (e.g., 6.7" missing while 6.5" + 5.5" present).
- Wildcard pattern in AASA `appIDs` or assetlinks.json target paths (hijack risk).
- Third-party SDK privacy manifest absent (advisory).

### Info
- Static adapter unavailable on this host (e.g., `INFO: SwiftLint adapter unavailable on this host — static lint findings skipped`).
- Tooling note that does not contribute to verdict.

## Phases

The skill is organized into seven canonical phases in this order: Setup → Story Gate → Phase 3A Deterministic Analysis → Phase 3B LLM Semantic Review → Architecture Conformance + Design Fidelity → Verdict → Output + Gate Update → Finalize. Each phase has explicit responsibilities; phase boundaries are non-negotiable.

### Phase 1 — Setup

- Resolve config via `resolve-config.sh` (already invoked by `setup.sh`).
- Read `platforms[]` and `compliance[]` from project-config.
- Invoke `${CLAUDE_PLUGIN_ROOT}/scripts/load-stack-persona.sh --story-file <path>` in the parent context. The script emits the canonical stack name and lazy-loads the matching reviewer persona + memory sidecar BEFORE fork dispatch. For mobile review the canonical stack name is `mobile-dev` (Talia). Forward the persona payload + canonical stack name into the fork.
- Resolve the story file path using the canonical glob: `.gaia/artifacts/implementation-artifacts/{story_key}-*.md`. Fail on zero or multiple matches.

### Phase 2 — Story Gate

- Verify the story is in `review` status. Otherwise HALT with `"story must be in review status before mobile review"`.
- Read the File List from the story's Dev Agent Record. Run `${CLAUDE_PLUGIN_ROOT}/scripts/file-list-diff-check.sh --story-file <path>` to detect divergence between the recorded File List and the actual diff. **Story Gate semantics are advisory — divergence does NOT halt the review.** Surface divergence as a Warning to the user.
- Missing-file handling: if a File List entry is absent from disk (renamed/deleted post-File-List-write), record it as a Warning finding under `category: integrity, severity: warning` in `analysis-results.json`.

### Phase 3A — Deterministic Analysis

Phase 3A is the **evidence layer**. Output: `analysis-results.json` validating against the review-common schema (`plugins/gaia/schemas/analysis-results.schema.json`, `schema_version: "1.0"`). Each evidence item carries: `validator`, `severity`, `file`, `line`, `criterion-id` (rubric rule), `finding`, `remediation`.

#### Layered rubric composition (AC10)

Compose the merged rubric via the deterministic merger (RFC 7396 JSON-merge-patch):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/rubric-merger.sh \
  ${CLAUDE_PLUGIN_ROOT}/rubrics/base/mobile.json \
  ${CLAUDE_PLUGIN_ROOT}/rubrics/base/mobile-code.json \
  ${CLAUDE_PLUGIN_ROOT}/rubrics/base/mobile-perf.json \
  ${CLAUDE_PLUGIN_ROOT}/rubrics/base/mobile-security.json \
  ${CLAUDE_PLUGIN_ROOT}/rubrics/base/mobile-a11y.json \
  [regime-rubric.json...]
```

Regime rubrics layered conditionally based on `compliance[]`:

- `compliance: [apple-app-store]` → append `${CLAUDE_PLUGIN_ROOT}/rubrics/regimes/apple-app-store.json`
- `compliance: [google-play-store]` → append `${CLAUDE_PLUGIN_ROOT}/rubrics/regimes/google-play-store.json`
- Both → append both, in declared order.

#### Validator 1 — Manifest Auditor (AC3, platform-conditional)

**iOS Info.plist** — when `platforms` includes `ios`:

- Verify required keys are present: `CFBundleIdentifier`, `CFBundleVersion`, `CFBundleShortVersionString`, `UIRequiredDeviceCapabilities`, `LSRequiresIPhoneOS`.
- Detect deprecated keys (e.g., `UIRequiresPersistentWiFi` removed iOS 13+, `CFBundleAllowMixedLocalizations` deprecated, `LSApplicationQueriesSchemes` policy boundaries).
- Detect conflicting permission usage descriptions.

**Android AndroidManifest.xml** — when `platforms` includes `android`:

- Verify required attrs: `package` (or `applicationId`), `versionCode`, `versionName`, `<uses-sdk android:minSdkVersion>`, `<uses-sdk android:targetSdkVersion>`, declared `<uses-permission>` blocks.
- Detect deprecated permissions (e.g., `READ_PHONE_STATE` without rationale, `GET_ACCOUNTS` after API 26).
- Detect permission conflicts (e.g., `WRITE_EXTERNAL_STORAGE` plus scoped-storage targetSdk ≥ 30, conflicting `<uses-permission-sdk-23>` declarations).

For every finding, emit evidence with the file path and line number.

#### Validator 2 — Entitlements Validator (AC4, iOS-only)

Skip if `platforms` excludes `ios`. Otherwise:

- Parse `*.entitlements` plist files in the project.
- Cross-reference declared entitlements against capabilities in the provisioning profile metadata (read from project-file references — never the .mobileprovision payload itself).
- Flag dead entitlements (declared but unused per code scan).
- Validate `iCloud` container identifiers, `push-notifications` APS environment, and `app-groups` identifiers reference well-formed names.
- Flag development-only entitlements in Release configurations: `get-task-allow=true`, `aps-environment=development` in Release → CRITICAL.

#### Validator 3 — Signing Configuration Validator (AC5)

Cross-platform. Inspects *configuration references only* — does not access certificates, private keys, or `.mobileprovision` payloads.

- iOS (xcodeproj / pbxproj): verify `CODE_SIGN_IDENTITY` matches target environment; detect provisioning-profile expiry from referenced metadata files (WARNING ≤ 30 days, CRITICAL when expired); confirm bundle ID consistency across all targets; verify `DEVELOPMENT_TEAM` (team ID) consistency; flag manual signing with hardcoded paths to `.mobileprovision`.
- Android (build.gradle / signingConfigs block): verify `signingConfig` is declared for release builds; flag inline keystore passwords or aliases (must reference env vars or gradle properties).
- The validator does NOT access secret material — never reads private keys, never parses `.mobileprovision` payloads, never extracts certificates.

#### Validator 4 — Store Metadata Validator (AC6)

Auto-detect metadata location (fastlane `metadata/`, `store-metadata/`, or platform-specific exports). For each platform present:

- **iOS / App Store** (when `compliance: [apple-app-store]`): app name (≤ 30 chars), subtitle (≤ 30 chars), description (≤ 4000 chars); screenshot completeness for required device classes (6.7", 6.5", 5.5"); privacy policy URL present and reachable; age-rating answers; valid category.
- **Android / Google Play** (when `compliance: [google-play-store]`): app name (≤ 30 chars), short description (≤ 80 chars), full description (≤ 4000 chars); screenshots (phone + 7" tablet + 10" tablet); privacy policy URL present and reachable; content-rating answers; valid category.

Character-limit overflows → WARNING. Missing required fields → CRITICAL.

#### Validator 5 — Privacy Manifest Validator (AC7, iOS-only)

Skip if `platforms` excludes `ios`. Otherwise:

- Verify `PrivacyInfo.xcprivacy` exists in the main target bundle. Absence → CRITICAL.
- Scan the codebase for required-reason API usage patterns (`UserDefaults`, file timestamp APIs, system boot time, disk space APIs, active keyboards) and cross-reference against `NSPrivacyAccessedAPITypes` declarations. Undeclared usage → CRITICAL.
- If ATT is used, verify `NSPrivacyTrackingDomains` is populated (tracking-domain declarations).
- Verify `NSPrivacyCollectedDataTypes` matches the app's declared behavior.
- Verify third-party SDK privacy manifests are bundled. Missing third-party SDK privacy manifest → WARNING.

#### Validator 6 — Universal-Links / App-Links Validator (AC8)

Cross-platform.

- **iOS apple-app-site-association (AASA)** — when `platforms` includes `ios`: validate JSON well-formed and matches the published structure (`applinks.details[].appIDs`); cross-reference `associated-domains` entitlement against AASA file domains; detect wildcard hijack patterns (e.g., `"*"` in `appIDs` without paired filters).
- **Android assetlinks.json** — when `platforms` includes `android`: validate JSON declares correct `package_name` and SHA-256 certificate fingerprints; verify `<intent-filter>` blocks use `android:autoVerify="true"` for declared associated domains; detect wildcard hijack patterns and overly broad path patterns.

#### Static Adapter Tool Probe (AC11)

For each available mobile static adapter (SwiftLint, Detekt, MobSF, etc.), invoke the three-state availability probe:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/tool-availability-probe.sh --tool <adapter>
```

- **AVAILABLE** → invoke the adapter and append findings to `analysis-results.json`.
- **UNAVAILABLE** → emit a single INFO-level "tool-unavailable" note (e.g., `INFO: SwiftLint adapter unavailable on this host — static lint findings skipped`). Never contributes to FAILED.
- **DEGRADED** → invoke; emit WARNING; treat findings as advisory.

### Phase 3B — LLM Semantic Review

The LLM applies the rubric above to the evidence collected in Phase 3A. Findings are organized by validator (`manifest`, `entitlements`, `signing`, `store-metadata`, `privacy-manifest`, `universal-links`). For each evidence item, the LLM:

- Confirms the rubric `criterion-id` mapping.
- Decides whether mitigating context (e.g., a recently rotated team ID still being propagated, a deprecated permission gated behind a runtime feature flag) downgrades the severity.
- Adds remediation guidance the deterministic validator could not infer.

The LLM cannot relabel a CRITICAL finding to APPROVE; it can only add context, downgrade WARNING → INFO with rationale, or upgrade INFO → WARNING with rationale. Severity downgrade requires an explicit reason recorded in the evidence item.

### Phase 4 — Architecture Conformance + Design Fidelity

Cross-check the diff against the project's architecture and threat-model artifacts (`.gaia/artifacts/planning-artifacts/architecture.md`, `.gaia/artifacts/planning-artifacts/threat-model.md`) when present. Verify that:

- New entitlements or permissions are documented in the architecture (or threat model) before being introduced. Undocumented sensitive entitlements (camera, location, contacts, microphone, push) → WARNING.
- Universal-link domain additions match the architecture's documented external-integration surface.
- Privacy manifest disclosures align with the threat model's data-flow diagrams.

Architecture-conformance findings are appended to `analysis-results.json` under `category: architecture, severity: warning` unless an explicit policy upgrades them.

### Phase 5 — Verdict

Resolve the composite verdict via the deterministic resolver:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh \
  --findings <analysis-results.json> \
  --rubric <merged-rubric.json>
```

The resolver emits one of `PASSED | FAILED | BLOCKED`. The skill MUST NOT recompute the verdict by hand.

Verdict mapping:

- **PASSED** — no CRITICAL findings; WARNING findings tolerated.
- **FAILED** — at least one CRITICAL finding from any validator.
- **BLOCKED** — infrastructure failure prevented full evidence collection (rubric load failure, malformed AASA file, manifest unparseable).

### Phase 6 — Output + Gate Update

Generate the report at `.gaia/artifacts/implementation-artifacts/{story_key}-mobile-review.md` containing:

- Story key + title
- Resolved `platforms[]` and `compliance[]`
- Per-validator section (Manifest Auditor, Entitlements, Signing, Store Metadata, Privacy Manifest, Universal-Links) with findings table
- Static adapter availability summary
- Composite findings count by severity
- Machine-readable verdict line: `**Verdict: PASSED**` or `**Verdict: FAILED**` or `**Verdict: BLOCKED**`

Update the Review Gate row via the canonical script:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh update \
  --story "{story_key}" \
  --gate "Mobile Review" \
  --verdict "{PASSED|FAILED|BLOCKED}"
```

**Idempotency (AC12):** The skill is idempotent — re-running on the same story overwrites the prior `analysis-results.json` (never appends), overwrites the prior `{story_key}-mobile-review.md` report, and updates the Review Gate row in place via `review-gate.sh` (no duplicate rows, no accumulated evidence).

After the Review Gate is updated, optionally invoke the composite gate check for human display:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
```

This check is informational only — do not halt on non-zero exit codes.

### Phase 7 — Finalize

Hand off control to `finalize.sh` which writes the workflow checkpoint and emits the lifecycle event for the tailing sync agent.

## References

- Three-Tier Review Pipeline (review-common, agent-overlay, verdict-resolver) — governs the seven-phase structure.
- Layered Rubric Loading (RFC 7396 JSON-merge-patch via `rubric-merger.sh`).
- Mobile-as-Platform Extension — defines the mobile rubric layer and platform-conditional validator behavior.
- Evidence/Judgment Split unifying principle.
- Native Execution Model (Claude Code Skills + Subagents + Plugins + Hooks).
- Scripts-over-LLM for Deterministic Operations.
- review-common foundation (analysis-results schema, verdict-resolver).
- agent-overlay.sh wiring table.
- rubric-merger.sh + rubric.schema.json.
- mobile stacks (canonical stack identifiers).
- mobile rubrics (`mobile.json`, `mobile-code.json`, `mobile-perf.json`, `mobile-security.json`, `mobile-a11y.json`).
- mobile static adapters (SwiftLint, Detekt, MobSF integration).
- `/gaia-review-mobile` skill spec + Talia routing.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-review-mobile/scripts/finalize.sh
