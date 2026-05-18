---
name: gaia-mobile-testing
description: Create mobile test plan with device matrix, Appium configuration, and responsive testing scenarios. Use when "mobile testing" or /gaia-mobile-testing.
argument-hint: "[story-key]"
context: main
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash]
orchestration_class: heavy-procedural
---

## Orchestration Mode

```bash
SESSION_MODE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-orchestration-mode.sh")
WARNING_OUTPUT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestration-warning.sh" --skill-class heavy-procedural --mode "$SESSION_MODE")
if printf '%s' "$WARNING_OUTPUT" | grep -q '^SURFACE-WARNING: '; then
  SENTINEL_PATH=$(printf '%s' "$WARNING_OUTPUT" | awk '/^SURFACE-WARNING: /{print $2; exit}')
  cat "$SENTINEL_PATH"
fi
```

**Surface contract (AF-2026-05-18-2).** When the prelude `cat`s a sentinel file — which happens once per session under Mode A (subagent dispatch) — you MUST mirror that cat'd warning text VERBATIM as the FIRST user-visible text of your response, before any skill-phase output. Claude Code auto-collapses Bash tool-call output, so the warning is invisible to users unless re-emitted as LLM turn text. Skip this step only when the prelude produced no sentinel output (Mode B, repeat invocation in same session, or out-of-scope skill class).

## Setup

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-mobile-testing/scripts/setup.sh

## Mission

You are creating a mobile test plan covering device matrix, Appium test infrastructure, React Native / cross-platform testing, responsive viewport testing, and platform-specific checks. The output is written to `docs/test-artifacts/mobile-test-plan-{date}.md`.

This skill is the native Claude Code conversion of the legacy `_gaia/testing/workflows/mobile-testing` workflow (E28-S88, Cluster 12, ADR-041). The step ordering, prompts, and output path are preserved from the legacy instructions.xml.

**Main context semantics (ADR-041):** This skill runs under `context: main` with full tool access. It reads project state (architecture, test plan, story) and produces an output document.

## Critical Rules

- A story key or project context MUST be available. If no story key is provided as an argument and no project context can be loaded, prompt: "Provide a story key or confirm project-level assessment."
- Device matrix MUST cover the top 90% of the target user base (FR-386 hard constraint).
- Platform-specific behaviors must be tested on real devices or emulators.
- Output MUST be written to `docs/test-artifacts/mobile-test-plan-{date}.md` where `{date}` is today's date in YYYY-MM-DD format.
- Knowledge fragments are bundled in this skill's `knowledge/` directory -- load them JIT when referenced by a step.
- Sprint-status.yaml is NEVER written by this skill (Sprint-Status Write Safety rule).

## Steps

### Step 1 -- Platform Matrix

**Hard constraint (FR-386):** The device matrix MUST cover the top 90% of the
target user base. The 90% threshold is non-negotiable — it is the minimum
defensible coverage floor. Acceptable evidence sources for the threshold are
usage analytics, app-store device telemetry, or vendor reports such as
StatCounter / DeviceAtlas. List the evidence source alongside the device
matrix in the generated test plan so the constraint is auditable.

- Define target devices by OS version, screen size, and market share.
- Include minimum supported versions for iOS and Android.
- Document screen size breakpoints and orientation requirements.
- Identify device-specific features used (camera, GPS, biometrics).
- If architecture.md is available, extract mobile stack details (React Native, Flutter, native).
- Surface the 90% user-base coverage constraint in the device-matrix section
  of the generated mobile-test-plan output so reviewers can verify it on a
  single grep.

### Step 2 -- Appium Setup

- Load knowledge fragment: `knowledge/appium-patterns.md`
- Design Appium test infrastructure and capabilities for iOS and Android.
- Configure device farm integration (BrowserStack, SauceLabs, or local emulators).
- Define element location strategies and wait patterns.
- Include Page Object Model structure for test maintainability.

#### Cloud device lab configuration (FR-386)

The generated test plan MUST include at least one runnable cloud-config
snippet drawn from one of the two reference providers below. Credentials are
sourced from environment variables or CI secret stores — never inlined.

**BrowserStack — `browserstack.yml` (Selenium 4 / Appium 2, W3C `bstack:options`):**

```yaml
# browserstack.yml — minimal Appium 2 mobile capabilities
userName: ${BROWSERSTACK_USERNAME}
accessKey: ${BROWSERSTACK_ACCESS_KEY}
projectName: ${PROJECT_NAME}
buildName: ${CI_BUILD_NAME}
platforms:
  - platformName: iOS
    deviceName: iPhone 15 Pro
    osVersion: "17"
    bstack:options:
      realMobile: true
      sessionName: smoke-suite-ios
  - platformName: Android
    deviceName: Samsung Galaxy S24
    osVersion: "14.0"
    bstack:options:
      realMobile: true
      sessionName: smoke-suite-android
```

**SauceLabs — `sauce:options` capabilities (Appium W3C):**

```yaml
# sauce.config.yml — minimal Appium W3C capabilities for Sauce Labs
sauce:options:
  username: ${SAUCE_USERNAME}
  accessKey: ${SAUCE_ACCESS_KEY}
  build: ${CI_BUILD_NAME}
  name: smoke-suite
  appiumVersion: "2.0.0"
platforms:
  - platformName: iOS
    appium:deviceName: iPhone 15 Pro
    appium:platformVersion: "17"
    appium:automationName: XCUITest
  - platformName: Android
    appium:deviceName: Pixel 8
    appium:platformVersion: "14"
    appium:automationName: UiAutomator2
```

Credential placeholders (`BROWSERSTACK_USERNAME`, `SAUCE_USERNAME`, etc.) are
required — never commit a real `accessKey` or `userName` value to a
configuration file. CI runners inject them at job start from the secret
store; local runs read them from a developer-scoped `.env` (which is excluded
from version control).

### Step 3 -- React Native / Cross-Platform Testing

- Load knowledge fragment: `knowledge/react-native-testing.md`
- Design Jest + React Native Testing Library unit test patterns.
- Configure Detox for E2E testing if applicable.
- Define native module mocking strategies.
- Include navigation testing patterns.

### Step 4 -- Responsive Testing

- Load knowledge fragment: `knowledge/responsive-testing.md`
- Define viewport testing matrix across target breakpoints (320px through 1920px).
- Design touch interaction tests (swipe, pinch, long press).
- Configure visual regression testing for mobile viewports.
- Include orientation change testing (portrait/landscape).

### Step 5 -- Platform-Specific Checks

- Test permission handling flows (camera, location, notifications).
- Verify deep linking behavior on both platforms.
- Test push notification delivery and handling.
- Validate platform gesture differences (back button on Android, swipe-back on iOS).
- Check app lifecycle handling (background, foreground, kill, restore).

### Step 6 -- Generate Output

- Generate mobile test plan with:
  - Device matrix with OS versions, screen sizes, and market share coverage
  - Appium infrastructure setup and capabilities configuration
  - React Native / cross-platform test patterns
  - Responsive viewport testing matrix
  - Platform-specific test scenarios
  - Touch interaction and gesture testing procedures
- Write output to `docs/test-artifacts/mobile-test-plan-{date}.md`.

> After artifact write: run open-question detection snippet
> `!${CLAUDE_PLUGIN_ROOT}/scripts/detect-open-questions.sh docs/test-artifacts/mobile-test-plan-${DATE}.md`

## Finalize

!${CLAUDE_PLUGIN_ROOT}/skills/gaia-mobile-testing/scripts/finalize.sh
