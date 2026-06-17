#!/usr/bin/env bats
# af-2026-05-27-4-rubric-gaps.bats
#
# AF-2026-05-27-4 / Test05 F-020, F-027.
#
# F-020 — gaia-review-api was missing the cross-cutting REST concerns
#   (idempotency, pagination, content negotiation, rate limiting, auth scheme).
#   A Step 4b was added; the report category list was extended.
# F-027 — gaia-infra-design SV-07 (scaling) + SV-11 (state) keyword allowlists
#   were cloud-biased; now accept on-prem/local idioms so a local-topology
#   infra doc passes without forcing cloud concepts.

load 'test_helper.bash'

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  API_SKILL="$PLUGIN_ROOT/skills/gaia-review-api/SKILL.md"
  INFRA_FINAL="$PLUGIN_ROOT/skills/gaia-infra-design/scripts/finalize.sh"
}
teardown() { common_teardown; }

# ---------- F-020: gaia-review-api cross-cutting concerns ----------

@test "F-020: api-review SKILL.md has a Step 4b covering the cross-cutting concerns" {
  grep -qE '^### Step 4b' "$API_SKILL"
  grep -qiF 'idempotency' "$API_SKILL"
  grep -qiF 'pagination' "$API_SKILL"
  grep -qiF 'content negotiation' "$API_SKILL"
  grep -qiF 'rate limiting' "$API_SKILL"
  grep -qiF 'auth scheme' "$API_SKILL"
}

@test "F-020: api-review SKILL.md surfaces the canonical status/headers for the new concerns" {
  grep -qF '429 Too Many Requests' "$API_SKILL"
  grep -qF 'Idempotency-Key' "$API_SKILL"
  grep -qE 'cursor|offset' "$API_SKILL"
  grep -qE '406 Not Acceptable|415 Unsupported Media Type' "$API_SKILL"
}

@test "F-020: api-review report category list includes the new concerns" {
  grep -qiE 'idempotency, pagination, content negotiation, rate limiting, auth scheme' "$API_SKILL"
}

# ---------- F-027: gaia-infra-design topology-aware SV checks ----------

# Build a LOCAL/on-prem infra doc that documents scaling + state WITHOUT any
# cloud keyword, and assert finalize.sh's SV-07 + SV-11 still pass.
_write_onprem_infra() { # $1 = path
  cat > "$1" <<'EOF'
# Infrastructure Design

## Environments
dev, staging, and production with parity maintained via identical Docker images.

## Deployment
The service runs as a systemd unit on a single host. Scaling is handled by
increasing the worker count (a single-instance vertical posture for now).
Request routing is via an on-prem nginx reverse proxy. Networking is restricted
by host firewall rules; the app binds to localhost behind the proxy.

## Infrastructure as Code
Provisioned with Ansible playbooks. The deployment is stateless — no remote
state backend; configuration converges idempotently on each run (local state
file only).

## Observability
Structured logs shipped to a local aggregator; alerting and on-call escalation
documented. Distributed tracing via correlation-id propagation.

Decisions recorded in the devops-sidecar.
EOF
}

@test "infra finalize.sh PASSES + on an on-prem doc (no cloud keywords)" {
  local doc="$TEST_TMP/infrastructure-design.md"
  _write_onprem_infra "$doc"
  run env INFRA_DESIGN_ARTIFACT="$doc" bash "$INFRA_FINAL"
  # Assert on the SV CHECKLIST result, NOT the overall exit code: finalize.sh's
  # exit couples to checkpoint.sh / lifecycle-event.sh writes (line ~250 `die`),
  # which are environment-dependent (they fail in a hermetic CI runner with no
  # resolvable project root). The F-027 fix is purely about the SV-07/SV-11
  # keyword allowlists, so assert those two items report [PASS] and neither is a
  # violation — independent of whether the post-checklist checkpoint write
  # succeeds.
  [[ "$output" == *"[PASS] SV-07"* ]]
  [[ "$output" == *"[PASS] SV-11"* ]]
  [[ "$output" != *"SV-07"*"violation"* ]]
  [[ "$output" != *"SV-11"*"violation"* ]]
}

@test "infra finalize.sh allowlist includes on-prem scaling idioms" {
  grep -qE 'systemd|supervisor|pm2|process[[:space:]]+manager|worker[[:space:]]+\(count|replicas\?|single\[\[:space:\]-\]instance' "$INFRA_FINAL"
}

@test "infra finalize.sh allowlist includes local/stateless idioms" {
  grep -qE 'local\[\[:space:\]\]\+state|stateless|idempotent|declarative' "$INFRA_FINAL"
}

@test "F-027: infra SKILL.md Step 3 is topology-aware (cloud + on-prem branches)" {
  grep -qiF 'topology-aware' "$PLUGIN_ROOT/skills/gaia-infra-design/SKILL.md"
  grep -qiE 'on-prem|on prem' "$PLUGIN_ROOT/skills/gaia-infra-design/SKILL.md"
}
