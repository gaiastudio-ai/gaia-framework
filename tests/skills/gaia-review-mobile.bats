#!/usr/bin/env bats
# gaia-review-mobile.bats — /gaia-review-mobile skill structural tests (E74-S8)
#
# Maps to story E74-S8 acceptance criteria:
#   AC1  — SKILL.md exists and is loadable (frontmatter, triggers, /gaia-help)
#   AC2  — Agent wiring resolves to Talia via agent-overlay.sh
#   AC3  — Manifest auditor (Info.plist + AndroidManifest.xml)
#   AC4  — Entitlements validator
#   AC5  — Signing configuration validator
#   AC6  — Store metadata completeness validator
#   AC7  — Privacy manifest (PrivacyInfo.xcprivacy) validator
#   AC8  — Universal-links / app-links validator
#   AC9  — Three-tier pipeline integration (verdict-resolver + review-gate.sh)
#   AC10 — Layered rubric loading (mobile + regimes)
#   AC11 — Static adapter integration via tool-availability-probe.sh
#   AC12 — Idempotent re-run (overwrite analysis-results.json)
#
# Usage:
#   bats tests/skills/gaia-review-mobile.bats
#
# Dependencies: bats-core 1.10+

# ---------- Helpers ----------

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILLS_DIR="$REPO_ROOT/plugins/gaia/skills"
  SCRIPTS_DIR="$REPO_ROOT/plugins/gaia/scripts"
  KNOWLEDGE_DIR="$REPO_ROOT/plugins/gaia/knowledge"
  SKILL_DIR="$SKILLS_DIR/gaia-review-mobile"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  SETUP_SCRIPT="$SKILL_DIR/scripts/setup.sh"
  FINALIZE_SCRIPT="$SKILL_DIR/scripts/finalize.sh"
  AGENT_OVERLAY="$SCRIPTS_DIR/review-common/agent-overlay.sh"
}

# ---------- AC1: SKILL.md exists and is loadable ----------

@test "AC1: SKILL.md exists at gaia-review-mobile skill directory" {
  [ -f "$SKILL_FILE" ]
}

@test "AC1: SKILL.md has YAML frontmatter delimiters" {
  head -1 "$SKILL_FILE" | grep -q "^---$"
  awk 'NR>1 && /^---$/{found=1; exit} END{exit !found}' "$SKILL_FILE"
}

@test "AC1: SKILL.md frontmatter contains name: gaia-review-mobile" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^name: gaia-review-mobile"
}

@test "AC1: SKILL.md frontmatter contains description field" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^description:"
}

@test "AC1: SKILL.md frontmatter declares fork context" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -qE "^context:[[:space:]]*fork"
}

@test "AC1: SKILL.md frontmatter declares allowed-tools" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -q "^allowed-tools:"
}

@test "AC1: SKILL.md description mentions /gaia-review-mobile or 'review mobile'" {
  awk '/^---$/{n++; next} n==1{print}' "$SKILL_FILE" | grep -qiE "gaia-review-mobile|review.*mobile"
}

@test "AC1: skill is registered in gaia-help.csv" {
  grep -q "gaia-review-mobile" "$KNOWLEDGE_DIR/gaia-help.csv"
}

@test "AC1: skill is registered in workflow-manifest.csv" {
  grep -q "gaia-review-mobile" "$KNOWLEDGE_DIR/workflow-manifest.csv"
}

# ---------- AC2: Agent wiring resolves to Talia ----------

@test "AC2: agent-overlay.sh resolves gaia-review-mobile to talia" {
  run "$AGENT_OVERLAY" --skill gaia-review-mobile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"agent_id":"talia"'
}

@test "AC2: agent-overlay.sh emits talia sidecar path" {
  run "$AGENT_OVERLAY" --skill gaia-review-mobile
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"sidecar_path":"_memory/talia-sidecar.md"'
}

@test "AC2: SKILL.md references agent-overlay.sh and talia routing" {
  grep -q "agent-overlay.sh" "$SKILL_FILE"
  grep -qi "talia" "$SKILL_FILE"
}

# ---------- AC3: Manifest auditor (Info.plist + AndroidManifest.xml) ----------

@test "AC3: SKILL.md documents Info.plist manifest auditing" {
  grep -qi "Info\.plist" "$SKILL_FILE"
}

@test "AC3: SKILL.md documents AndroidManifest.xml manifest auditing" {
  grep -qi "AndroidManifest\.xml" "$SKILL_FILE"
}

@test "AC3: SKILL.md mentions iOS required keys (CFBundleIdentifier, CFBundleVersion)" {
  grep -q "CFBundleIdentifier" "$SKILL_FILE"
  grep -q "CFBundleVersion" "$SKILL_FILE"
}

@test "AC3: SKILL.md mentions Android required attrs (versionCode, minSdkVersion)" {
  grep -q "versionCode" "$SKILL_FILE"
  grep -q "minSdkVersion" "$SKILL_FILE"
}

@test "AC3: SKILL.md documents deprecated-key detection" {
  grep -qiE "deprecated.*key|deprecated.*manifest" "$SKILL_FILE"
}

@test "AC3: SKILL.md documents permission conflict detection" {
  grep -qiE "permission.*conflict|conflicting.*permission" "$SKILL_FILE"
}

# ---------- AC4: Entitlements validator ----------

@test "AC4: SKILL.md documents entitlements validation" {
  grep -qi "entitlements" "$SKILL_FILE"
}

@test "AC4: SKILL.md mentions provisioning profile cross-reference" {
  grep -qiE "provisioning profile" "$SKILL_FILE"
}

@test "AC4: SKILL.md mentions get-task-allow / dev-only entitlements check" {
  grep -qE "get-task-allow|development-only entitlement" "$SKILL_FILE"
}

@test "AC4: SKILL.md mentions iCloud / push-notifications / app-groups entitlements" {
  grep -qE "iCloud|push-notifications|app-groups" "$SKILL_FILE"
}

# ---------- AC5: Signing configuration validator ----------

@test "AC5: SKILL.md documents signing configuration validation" {
  grep -qiE "signing.*configuration|code.signing|signing.*identity" "$SKILL_FILE"
}

@test "AC5: SKILL.md mentions provisioning profile expiry" {
  grep -qiE "expir(y|es|ed|ation)" "$SKILL_FILE"
}

@test "AC5: SKILL.md mentions team ID consistency" {
  grep -qiE "team.*id|teamid" "$SKILL_FILE"
}

@test "AC5: SKILL.md notes signing validator does NOT access secrets" {
  grep -qiE "do(es)? not access.*(certificate|profile|secret)|never access.*(certificate|profile|secret)|no.*secret" "$SKILL_FILE"
}

# ---------- AC6: Store metadata completeness validator ----------

@test "AC6: SKILL.md documents store metadata validation" {
  grep -qiE "store.metadata|app store|google play" "$SKILL_FILE"
}

@test "AC6: SKILL.md mentions character limits per platform" {
  grep -qiE "character.*limit|char.*limit" "$SKILL_FILE"
}

@test "AC6: SKILL.md mentions screenshot device classes" {
  grep -qiE "screenshot|6\.7|6\.5|5\.5" "$SKILL_FILE"
}

@test "AC6: SKILL.md mentions privacy policy URL check" {
  grep -qiE "privacy policy" "$SKILL_FILE"
}

# ---------- AC7: Privacy manifest validator ----------

@test "AC7: SKILL.md documents PrivacyInfo.xcprivacy validation" {
  grep -q "PrivacyInfo\.xcprivacy" "$SKILL_FILE"
}

@test "AC7: SKILL.md mentions required-reason API declarations" {
  grep -qiE "required.reason|NSPrivacyAccessedAPI" "$SKILL_FILE"
}

@test "AC7: SKILL.md mentions tracking domains (NSPrivacyTrackingDomains)" {
  grep -qE "NSPrivacyTrackingDomains|tracking.*domain" "$SKILL_FILE"
}

@test "AC7: SKILL.md mentions third-party SDK privacy manifests" {
  grep -qiE "third.party.*SDK.*privacy|SDK.*privacy.*manifest" "$SKILL_FILE"
}

# ---------- AC8: Universal-links / app-links validator ----------

@test "AC8: SKILL.md documents apple-app-site-association validation" {
  grep -qE "apple-app-site-association|AASA" "$SKILL_FILE"
}

@test "AC8: SKILL.md documents Android assetlinks.json validation" {
  grep -q "assetlinks\.json" "$SKILL_FILE"
}

@test "AC8: SKILL.md mentions android:autoVerify intent-filter check" {
  grep -qE "autoVerify|auto.?verify" "$SKILL_FILE"
}

@test "AC8: SKILL.md mentions wildcard hijack detection" {
  grep -qiE "wildcard.*hijack|hijack.*pattern|wildcard.*pattern" "$SKILL_FILE"
}

# ---------- AC9: Three-tier pipeline integration ----------

@test "AC9: SKILL.md references analysis-results.json output" {
  grep -q "analysis-results\.json" "$SKILL_FILE"
}

@test "AC9: SKILL.md invokes verdict-resolver.sh" {
  grep -q "verdict-resolver\.sh" "$SKILL_FILE"
}

@test "AC9: SKILL.md invokes review-gate.sh to update Review Gate row" {
  grep -q "review-gate\.sh" "$SKILL_FILE"
}

@test "AC9: SKILL.md emits canonical PASSED/FAILED verdict vocabulary" {
  grep -qE "PASSED|FAILED" "$SKILL_FILE"
}

# ---------- AC10: Layered rubric loading ----------

@test "AC10: SKILL.md invokes rubric-merger.sh or rubric-loader.sh" {
  grep -qE "rubric-merger\.sh|rubric-loader\.sh" "$SKILL_FILE"
}

@test "AC10: SKILL.md references base mobile rubric (mobile.json)" {
  grep -qE "mobile\.json|rubrics/base/mobile" "$SKILL_FILE"
}

@test "AC10: SKILL.md references regime rubric composition (apple-app-store / google-play-store)" {
  grep -qE "apple-app-store|google-play-store" "$SKILL_FILE"
}

@test "AC10: SKILL.md references mobile sub-rubrics (mobile-code, mobile-perf, mobile-security, mobile-a11y)" {
  grep -qE "mobile-code|mobile-perf|mobile-security|mobile-a11y" "$SKILL_FILE"
}

# ---------- AC11: Static adapter integration ----------

@test "AC11: SKILL.md invokes tool-availability-probe.sh" {
  grep -q "tool-availability-probe\.sh" "$SKILL_FILE"
}

@test "AC11: SKILL.md mentions specific mobile static adapters (SwiftLint, Detekt, MobSF)" {
  grep -qE "SwiftLint|Detekt|MobSF" "$SKILL_FILE"
}

@test "AC11: SKILL.md describes INFO-level tool-unavailable note (graceful degrade)" {
  grep -qiE "tool.unavailable|tool.*unavailable|adapter.*unavailable" "$SKILL_FILE"
}

# ---------- AC12: Idempotent re-run ----------

@test "AC12: SKILL.md documents idempotent re-run / overwrite behavior" {
  grep -qiE "idempotent|overwrit|re.run.*replace" "$SKILL_FILE"
}

# ---------- Shared setup.sh / finalize.sh pattern ----------

@test "Shared: setup.sh exists and is executable" {
  [ -x "$SETUP_SCRIPT" ]
}

@test "Shared: finalize.sh exists and is executable" {
  [ -x "$FINALIZE_SCRIPT" ]
}

@test "Shared: setup.sh calls resolve-config.sh" {
  grep -q "resolve-config.sh" "$SETUP_SCRIPT"
}

@test "Shared: setup.sh loads checkpoint" {
  grep -q "checkpoint" "$SETUP_SCRIPT"
}

@test "Shared: finalize.sh writes checkpoint" {
  grep -q "checkpoint" "$FINALIZE_SCRIPT"
}

@test "Shared: finalize.sh emits lifecycle event" {
  grep -q "lifecycle-event" "$FINALIZE_SCRIPT"
}

@test "Shared: SKILL.md invokes setup.sh at entry" {
  grep -q '!.*setup\.sh' "$SKILL_FILE"
}

@test "Shared: SKILL.md invokes finalize.sh at exit" {
  grep -q '!.*finalize\.sh' "$SKILL_FILE"
}

# ---------- Story traceability ----------

@test "Traceability: SKILL.md documents the mobile review-gate contract" {
  grep -qiE "review.gate|verdict-resolver|mobile" "$SKILL_FILE"
}
