---
name: gaia-review-mobile
description: Mobile review gate — runs six validators (manifest auditor, entitlements, signing configuration, store metadata completeness, privacy manifest, universal-links / app-links) on iOS and Android projects, composes a layered rubric (mobile + regimes), produces a verdict via verdict-resolver.sh, and updates the Review Gate via review-gate.sh. Routed to Talia (mobile-dev) via agent-overlay.sh per ADR-077. Use when "review mobile" or /gaia-review-mobile.
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
---

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-review-mobile/scripts/setup.sh

## Mission

You are the **pre-merge mobile review gate** for iOS and Android projects. The skill executes the six-validator suite mandated by E74-S8 and emits a composite verdict (PASSED / FAILED / BLOCKED) via the canonical three-tier evidence → judgment → verdict pipeline (E66-S1, ADR-077).

This skill is a sibling of the other GAIA review skills (`gaia-review-code`, `gaia-review-perf`, `gaia-review-security`, `gaia-review-a11y`, `gaia-review-deps`, `gaia-review-test`). It follows the seven-phase reviewer structure mandated by **ADR-077** (Three-Tier Review Pipeline) and the layered-rubric model mandated by **ADR-079** (Layered Rubric Loading).

**Scope (story E74-S8 / ADR-081):** mobile-as-platform extension. The six validators are platform-aware — iOS-only validators (Info.plist, entitlements, PrivacyInfo.xcprivacy, AASA) skip when `platforms` excludes `ios`; Android-only validators (AndroidManifest.xml, assetlinks.json) skip when `platforms` excludes `android`. Cross-platform validators (signing config, store metadata) inspect whichever platform is configured.

**Fork context semantics (ADR-041, ADR-045):** This skill runs under `context: fork` with read-only tools (`Read Grep Glob Bash`). It CANNOT modify source files — the tool allowlist enforces NFR-048 (no-write isolation). Findings flow into `analysis-results.json` and the Review Gate row only; the underlying source code is never edited by this skill.

## Agent Wiring

Per the ADR-077 wiring table, this skill resolves to **Talia (Mobile Developer)**:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/agent-overlay.sh --skill gaia-review-mobile
# {"agent_id":"talia","sidecar_path":"_memory/talia-sidecar.md"}
```

Talia's persona overlay (mobile-first specialist; React Native / Swift / Kotlin) is loaded into the fork context for the duration of this review. The overlay resolver runs in the parent context BEFORE fork dispatch — the fork tool allowlist `[Read, Grep, Glob, Bash]` stays intact (NFR-RSV2-5 / NFR-048 preserved).

## Critical Rules

- A story key argument MUST be provided. If missing, fail fast with "usage: /gaia-review-mobile [story-key]".
- The story file MUST exist at `docs/implementation-artifacts/{story_key}-*.md`. Use the canonical glob to resolve regardless of title slug.
- The story MUST be in `review` status. If not, fail with "story must be in review status before mobile review".
- This skill is READ-ONLY. Do NOT attempt Write or Edit tools — the fork context allowlist enforces this.
- Platform-irrelevant validators MUST be skipped silently (e.g., iOS validators skip on `platforms: [android]`). Skipped validators do NOT contribute to the verdict.
- The signing-configuration validator MUST NOT access certificates, private keys, or signed `.mobileprovision` payloads. It validates configuration *references* and structural consistency only — never secrets.
- Findings are emitted as evidence items into `analysis-results.json` following the review-common schema; the verdict is computed by `verdict-resolver.sh`, never inline.
- Call `review-gate.sh` to update the "Review Gate" row — do NOT manually edit the story file.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Inputs

- `$ARGUMENTS`: required — the story key (e.g., `E74-S8`).
- `project-config.yaml`: required — supplies `platforms[]` (e.g., `[ios]`, `[android]`, `[ios, android]`) and `compliance[]` (e.g., `[apple-app-store]`, `[google-play-store]`) for rubric composition.

## Steps

### Phase 1 — Setup

- Resolve config via `resolve-config.sh` (already invoked by `setup.sh`).
- Read `platforms` and `compliance` from project-config.
- Resolve the story file path using the canonical glob: `docs/implementation-artifacts/{story_key}-*.md`. Fail on zero or multiple matches.
- Verify the story is in `review` status. Otherwise HALT.

### Phase 2 — Layered Rubric Composition

Compose the merged rubric via the deterministic merger (RFC 7396 JSON-merge-patch, ADR-079):

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

The merged rubric drives severity weighting for every finding emitted by Phase 3.

### Phase 3 — Evidence Collection (six validators)

Each validator emits structured evidence items into the in-memory `analysis-results.json` buffer following the review-common schema (E66-S1). Each evidence item carries: `validator`, `severity` (CRITICAL / WARNING / INFO), `file`, `line`, `criterion-id` (rubric rule), `finding`, `remediation`.

#### Phase 3a — Manifest Auditor (AC3, platform-conditional)

**iOS Info.plist** — when `platforms` includes `ios`:

- Verify required keys are present: `CFBundleIdentifier`, `CFBundleVersion`, `CFBundleShortVersionString`, `UIRequiredDeviceCapabilities`, `LSRequiresIPhoneOS`.
- Detect deprecated keys (e.g., `UIRequiresPersistentWiFi` removed iOS 13+, `CFBundleAllowMixedLocalizations` deprecated, `LSApplicationQueriesSchemes` policy boundaries).
- Detect conflicting permission usage descriptions (e.g., presence of `NSCameraUsageDescription` without an `Info.plist` privacy-mode declaration).

**Android AndroidManifest.xml** — when `platforms` includes `android`:

- Verify required attrs and elements: `package` (or `applicationId` in build.gradle), `versionCode`, `versionName`, `<uses-sdk android:minSdkVersion>`, `<uses-sdk android:targetSdkVersion>`, declared `<uses-permission>` blocks.
- Detect deprecated permissions (e.g., `READ_PHONE_STATE` without rationale, `GET_ACCOUNTS` after API 26).
- Detect permission conflicts (e.g., `WRITE_EXTERNAL_STORAGE` plus scoped-storage targetSdk ≥ 30 inconsistency, conflicting `<uses-permission-sdk-23>` declarations).

For every manifest finding, emit evidence with the file path and line number reference.

#### Phase 3b — Entitlements Validator (AC4, iOS-only)

Skip if `platforms` excludes `ios`. Otherwise:

- Parse `*.entitlements` plist files in the project.
- Cross-reference declared entitlements against capabilities in the provisioning profile metadata (read from the project file references — never the .mobileprovision payload itself).
- Flag dead entitlements (declared but unused per code scan).
- Validate `iCloud` container identifiers, `push-notifications` APS environment, and `app-groups` identifiers reference well-formed names (no empty strings, no wildcards in production).
- Flag development-only entitlements in Release configurations: `get-task-allow=true`, `aps-environment=development` in a Release-built target → CRITICAL.

#### Phase 3c — Signing Configuration Validator (AC5)

Cross-platform (iOS + Android signing config). Inspects *configuration references only* — never certificates or private keys.

- iOS (xcodeproj / pbxproj): verify `CODE_SIGN_IDENTITY` matches target environment (development vs. distribution); detect provisioning-profile expiry from referenced metadata files (WARNING when ≤ 30 days, CRITICAL when expired); confirm bundle ID consistency across all targets; verify `DEVELOPMENT_TEAM` (team ID) consistency; flag manual signing with hardcoded paths to `.mobileprovision` files.
- Android (build.gradle / signingConfigs block): verify `signingConfig` is declared for release builds; flag absence of `storeFile` resolution path; flag inline keystore passwords or aliases (must reference env vars or gradle properties).
- The validator does NOT access secret material — it inspects configuration references and structural consistency only.

#### Phase 3d — Store Metadata Validator (AC6, conditional on compliance regime)

Auto-detect metadata location (fastlane `metadata/` directory, `store-metadata/`, or platform-specific exports). For each platform present:

- **iOS / App Store** (when `compliance: [apple-app-store]`): app name (≤ 30 chars), subtitle (≤ 30 chars), description (≤ 4000 chars); screenshot completeness for required device classes (6.7", 6.5", 5.5"); privacy policy URL present and reachable; age-rating questionnaire answers present; valid category selection.
- **Android / Google Play** (when `compliance: [google-play-store]`): app name (≤ 30 chars), short description (≤ 80 chars), full description (≤ 4000 chars); screenshot completeness (phone, 7" tablet, 10" tablet); privacy policy URL present and reachable; content-rating questionnaire answers; valid category selection.

Character-limit overflows emit WARNING. Missing required fields emit CRITICAL.

#### Phase 3e — Privacy Manifest Validator (AC7, iOS-only)

Skip if `platforms` excludes `ios`. Otherwise:

- Verify `PrivacyInfo.xcprivacy` exists in the main target bundle. Absence → CRITICAL.
- Scan the codebase for required-reason API usage patterns (`UserDefaults`, file timestamp APIs, system boot time, disk space APIs, active keyboards) and cross-reference against `NSPrivacyAccessedAPITypes` declarations. Undeclared usage → CRITICAL.
- If ATT (App Tracking Transparency) is used, verify `NSPrivacyTrackingDomains` is populated.
- Verify `NSPrivacyCollectedDataTypes` matches the app's declared behavior.
- Verify third-party SDK privacy manifests are bundled (look for `PrivacyInfo.xcprivacy` inside SDK frameworks under the build output). Missing third-party SDK privacy manifests → WARNING.

The required-reason API list evolves; consult the current Apple developer documentation when extending this validator.

#### Phase 3f — Universal-Links / App-Links Validator (AC8)

Cross-platform. Inspects domain-association files referenced by the project.

- **iOS apple-app-site-association (AASA)** — when `platforms` includes `ios`:
  - Validate JSON is well-formed and matches the published structure (`applinks.details[].appIDs` array of `<TeamID>.<bundle-id>` strings).
  - Cross-reference `associated-domains` entitlement against AASA file domains.
  - Detect wildcard hijack patterns (e.g., `"*"` in `appIDs` without a paired `paths`/`exclude` filter).

- **Android assetlinks.json** — when `platforms` includes `android`:
  - Validate JSON structure declares the correct `package_name` and SHA-256 certificate fingerprints.
  - Verify `<intent-filter>` blocks in AndroidManifest.xml use `android:autoVerify="true"` for declared associated domains.
  - Detect wildcard hijack patterns and overly broad path patterns.

### Phase 4 — Static Adapter Tool Probe (AC11)

For each available mobile static adapter from E74-S7 (SwiftLint, Detekt, MobSF, etc.), invoke the three-state availability probe (E66-S2):

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/tool-availability-probe.sh --tool <adapter>
```

- **AVAILABLE** → invoke the adapter and append its findings to `analysis-results.json` as evidence items.
- **UNAVAILABLE** → emit a single INFO-level "tool-unavailable" note (e.g., `INFO: SwiftLint adapter unavailable on this host — static lint findings skipped`). The note is informational only and never contributes to a FAILED verdict.
- **DEGRADED** → invoke the adapter; emit a WARNING noting the degradation; treat findings as advisory.

### Phase 5 — Judgment + Verdict (AC9)

Write the populated `analysis-results.json` to a deterministic path under `_memory/` for traceability, then resolve the composite verdict via the deterministic resolver:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-common/verdict-resolver.sh \
  --findings <analysis-results.json> \
  --rubric <merged-rubric.json>
```

The resolver emits one of `PASSED | FAILED | BLOCKED`. The skill MUST NOT recompute the verdict by hand (ADR-077, ADR-042).

Verdict mapping:

- **PASSED** — no CRITICAL findings; WARNING findings tolerated.
- **FAILED** — at least one CRITICAL finding from any validator.
- **BLOCKED** — infrastructure failure prevented full evidence collection (e.g., rubric load failure, malformed AASA file, manifest unparseable).

### Phase 6 — Report + Review Gate Update (AC9)

Generate the report at `docs/implementation-artifacts/{story_key}-mobile-review.md` containing:

- Story key + title
- Resolved `platforms[]` and `compliance[]` from project-config
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

### Phase 7 — Idempotency + Exit (AC12)

The skill is **idempotent** — re-running on the same story:

- Overwrites the prior `analysis-results.json` (never appends).
- Overwrites the prior `{story_key}-mobile-review.md` report.
- Updates the Review Gate row in place via `review-gate.sh` (no duplicate rows, no accumulated evidence).

After the Review Gate is updated, optionally invoke the composite gate check for human display:

```bash
!${CLAUDE_PLUGIN_ROOT}/scripts/review-gate.sh review-gate-check --story "{story_key}"
```

This check is informational only — do not halt on non-zero exit codes.

## Outputs

- `docs/implementation-artifacts/{story_key}-mobile-review.md` — human-readable report
- `_memory/analysis-results-{story_key}-mobile.json` — machine-readable evidence + verdict
- Review Gate row update in the story file (via `review-gate.sh`)

## References

- **ADR-077** Three-Tier Review Pipeline (review-common, agent-overlay, verdict-resolver) — governs the seven-phase structure.
- **ADR-079** Layered Rubric Loading (RFC 7396 JSON-merge-patch via `rubric-merger.sh`).
- **ADR-081** Mobile-as-Platform Extension — defines the mobile rubric layer and platform-conditional validator behavior.
- **ADR-041** Native Execution Model (Claude Code Skills + Subagents + Plugins + Hooks).
- **ADR-042** Scripts-over-LLM for Deterministic Operations.
- **E66-S1** review-common foundation (analysis-results schema, verdict-resolver).
- **E66-S4** agent-overlay.sh wiring table.
- **E68-S2** rubric-merger.sh + rubric.schema.json.
- **E74-S2** mobile stacks (canonical stack identifiers).
- **E74-S3** mobile rubrics (`mobile.json`, `mobile-code.json`, `mobile-perf.json`, `mobile-security.json`, `mobile-a11y.json`).
- **E74-S7** mobile static adapters (SwiftLint, Detekt, MobSF integration).
- **Story:** E74-S8 — `/gaia-review-mobile` skill spec + Talia routing.

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-review-mobile/scripts/finalize.sh
