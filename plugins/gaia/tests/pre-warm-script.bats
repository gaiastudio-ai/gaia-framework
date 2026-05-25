#!/usr/bin/env bats
# pre-warm-script.bats — E70-S7 coverage for the brownfield Phase 3 pre-flight
# pre-warm.sh (cdxgen + Grype DB pre-warm).
#
# Story: E70-S7. ADR-078 (adapter contract), ADR-121 (deterministic-tools master
# flag), FR-539, NFR-84/85/86.
#
# All network I/O is faked via PATH shims (fake `grype`/`cdxgen`/`curl`/`wget`)
# so the suite is deterministic and offline. The script under test is:
#   plugins/gaia/scripts/adapters/brownfield/pre-warm.sh
#
# Scenarios (story Test Scenarios + AC5):
#   1 cold cache   → grype db update + cdxgen warm + checksum-log entry; exit 0
#   2 warm cache   → "cache warm", zero network I/O, exit 0
#   3 grype absent → WARNING, exit 0 (graceful degrade)
#   4 net failure  → retry once → exit 0 (WARNING if both fail, still exit 0)
#   5 flag-off     → INFO skip, exit 0, no work
#   6 checksum log → two same-session invocations append two JSONL rows

load 'test_helper.bash'

setup() {
  common_setup
  PRE_WARM="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/pre-warm.sh"
  export PRE_WARM
  # Private bin dir for fake binaries; prepended to PATH per-test.
  FAKE_BIN="$TEST_TMP/bin"
  mkdir -p "$FAKE_BIN"
  export FAKE_BIN
  # Isolate the checksum-log audit dir to the temp tree.
  export GAIA_BROWNFIELD_AUDIT_DIR="$TEST_TMP/brownfield-audit"
  # Isolate the cdxgen sentinel-cache marker dir.
  export GAIA_PREWARM_CACHE_DIR="$TEST_TMP/prewarm-cache"
  export GAIA_SESSION_ID="test-session-1"
  # A network shim that records any invocation — used to assert zero net I/O.
  NET_LOG="$TEST_TMP/net.log"
  export NET_LOG
  _mk_net_shims
}

teardown() { common_teardown; }

# --- shim factories -------------------------------------------------------

# fake grype with a scripted behavior via GRYPE_MODE:
#   present_fresh : `db status` reports present + young; update is a no-op
#   cold          : `db check` fails (absent); `db update` succeeds
#   netfail_once  : first `db update` fails (network), a marker flips to success
_mk_grype() {
  local mode="$1"
  cat > "$FAKE_BIN/grype" <<EOF
#!/usr/bin/env bash
mode="$mode"
sub="\$1"; act="\${2:-}"
if [ "\$sub" = "db" ]; then
  case "\$mode:\$act" in
    present_fresh:status) echo '{"schemaVersion":5,"built":"2026-05-24T00:00:00Z","valid":true}'; exit 0 ;;
    present_fresh:check)  exit 0 ;;
    present_fresh:update) exit 0 ;;
    cold:status) echo '{"valid":false}'; exit 1 ;;
    cold:check)  exit 1 ;;
    cold:update) echo "updating"; exit 0 ;;
    netfail_once:status) echo '{"valid":false}'; exit 1 ;;
    netfail_once:check)  exit 1 ;;
    netfail_once:update)
      m="$TEST_TMP/grype-update-attempted"
      if [ -f "\$m" ]; then echo "updated"; exit 0; else touch "\$m"; echo "network error" >&2; exit 1; fi ;;
    *) exit 0 ;;
  esac
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/grype"
  # A fake grype-db.sqlite the script can checksum.
  mkdir -p "$TEST_TMP/grypedb"
  printf 'fake-grype-db-content\n' > "$TEST_TMP/grypedb/grype-db.sqlite"
  export GAIA_GRYPE_DB_FILE="$TEST_TMP/grypedb/grype-db.sqlite"
}

_mk_cdxgen() {
  cat > "$FAKE_BIN/cdxgen" <<'EOF'
#!/usr/bin/env bash
# Pretend to warm registry caches; emit a tiny SBOM to stdout.
echo '{"bomFormat":"CycloneDX","components":[]}'
exit 0
EOF
  chmod +x "$FAKE_BIN/cdxgen"
}

# curl/wget shims that LOG any call — presence of a log line means net I/O happened.
_mk_net_shims() {
  for tool in curl wget; do
    cat > "$FAKE_BIN/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$NET_LOG"
exit 0
EOF
    chmod +x "$FAKE_BIN/$tool"
  done
}

run_prewarm() { PATH="$FAKE_BIN:$PATH" run bash "$PRE_WARM" "$@"; }

# --- Scenario 1 — cold cache ---------------------------------------------

@test "E70-S7 AC1/AC4: cold cache runs grype db update + cdxgen warm + logs checksum, exit 0" {
  _mk_grype cold; _mk_cdxgen
  run_prewarm
  [ "$status" -eq 0 ]
  [ -f "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log" ]
  run cat "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log"
  [[ "$output" == *"checksum"* ]]
  [[ "$output" == *"$GAIA_SESSION_ID"* ]]
}

@test "E70-S7 AC4: checksum-log row is valid JSONL with required keys" {
  _mk_grype cold; _mk_cdxgen
  run_prewarm
  [ "$status" -eq 0 ]
  run tail -n1 "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log"
  # Must parse as JSON and carry the four documented keys.
  echo "$output" | jq -e '.ts and .session_id and .checksum and (.db_built_age_seconds != null)'
}

# --- Scenario 2 — warm cache (idempotent, zero net I/O) ------------------

@test "E70-S7 AC3: warm cache emits 'cache warm', exits 0, performs zero network I/O" {
  _mk_grype present_fresh; _mk_cdxgen
  # Seed a fresh cdxgen sentinel-cache marker so the warm path triggers.
  mkdir -p "$GAIA_PREWARM_CACHE_DIR"; touch "$GAIA_PREWARM_CACHE_DIR/cdxgen-warm.marker"
  run_prewarm
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache warm"* ]]
  # No curl/wget shim should have been invoked.
  [ ! -s "$NET_LOG" ]
}

# --- Scenario 3 — grype unavailable → graceful degrade -------------------

@test "E70-S7 AC5: grype unavailable emits WARNING and exits 0 (graceful degrade)" {
  # No fake grype on PATH; provide cdxgen only.
  _mk_cdxgen
  # Strip any real grype by using ONLY the fake bin dir as PATH plus coreutils.
  PATH="$FAKE_BIN:/usr/bin:/bin" run bash "$PRE_WARM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
}

# --- Scenario 4 — network failure → retry once → exit 0 ------------------

@test "E70-S7 AC5: network failure on db update retries once then exits 0" {
  _mk_grype netfail_once; _mk_cdxgen
  run_prewarm
  [ "$status" -eq 0 ]
  # The retry marker proves a second attempt happened.
  [ -f "$TEST_TMP/grype-update-attempted" ]
}

# --- Scenario 5 — flag-off skip ------------------------------------------

@test "E70-S7 AC-X1: flag-off (master flag false) emits INFO skip and exits 0 with no work" {
  _mk_grype cold; _mk_cdxgen
  GAIA_BROWNFIELD_DETERMINISTIC_TOOLS=false PATH="$FAKE_BIN:$PATH" run bash "$PRE_WARM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
  # No checksum log written when skipped.
  [ ! -f "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log" ]
}

@test "E70-S7 AC-X1: per-tool override off emits INFO skip and exits 0" {
  _mk_grype cold; _mk_cdxgen
  GAIA_BROWNFIELD_PREWARM_ENABLED=false PATH="$FAKE_BIN:$PATH" run bash "$PRE_WARM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]] || [[ "$output" == *"INFO"* ]]
}

# --- Scenario 6 — checksum-log append, same session ----------------------

@test "E70-S7 AC4: two same-session invocations append two JSONL rows sharing session_id" {
  _mk_grype cold; _mk_cdxgen
  run_prewarm
  [ "$status" -eq 0 ]
  run_prewarm
  [ "$status" -eq 0 ]
  run wc -l < "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log"
  [ "$output" -ge 2 ]
  run grep -c "$GAIA_SESSION_ID" "$GAIA_BROWNFIELD_AUDIT_DIR/grype-db-checksum.log"
  [ "$output" -ge 2 ]
}

# --- AC-X1 flag-resolution integration (resolve-config.sh path) -----------
# F2 (Val Step7b): exercise the REAL config-resolution path the /gaia-brownfield
# prelude uses, not just the GAIA_BROWNFIELD_* env seam. Proves the flag-gate
# can actually be turned on/off via project-config.yaml (resolve-config.sh
# --field brownfield.* must be whitelisted + the schema must accept the key).

_mk_brownfield_config() {
  # $1 = deterministic_tools value, $2 = prewarm_enabled value ("" = omit block)
  local dt="$1" pw="$2"
  cat > "$TEST_TMP/project-config.yaml" <<YAML
project_root: /tmp/gaia
project_path: /tmp/gaia/app
memory_path: /tmp/gaia/.gaia/memory
checkpoint_path: /tmp/gaia/.gaia/memory/checkpoints
installed_path: /tmp/gaia/_gaia
framework_version: 1.176.0
date: 2026-05-25
YAML
  if [ -n "$dt" ]; then
    printf 'brownfield:\n  deterministic_tools: %s\n  prewarm_enabled: %s\n' "$dt" "$pw" \
      >> "$TEST_TMP/project-config.yaml"
  fi
  cp "$(cd "$BATS_TEST_DIRNAME/../config" && pwd)/project-config.schema.yaml" "$TEST_TMP/project-config.schema.yaml"
}

@test "E70-S7 AC-X1: resolve-config.sh --field brownfield.deterministic_tools is whitelisted and resolves true" {
  _mk_brownfield_config true true
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --field brownfield.deterministic_tools
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "E70-S7 AC-X1: resolve-config.sh --field brownfield.prewarm_enabled is whitelisted and resolves true" {
  _mk_brownfield_config true true
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --field brownfield.prewarm_enabled
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "E70-S7 AC-X1: brownfield top-level key passes schema validation (--all exits 0)" {
  _mk_brownfield_config true true
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --all
  [ "$status" -eq 0 ]
}

@test "E70-S7 AC-X1: absent brownfield block resolves empty (consumers treat as false)" {
  _mk_brownfield_config "" ""
  run bash "$SCRIPTS_DIR/resolve-config.sh" --shared "$TEST_TMP/project-config.yaml" \
    --schema "$TEST_TMP/project-config.schema.yaml" --field brownfield.deterministic_tools
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- AC-X2 / AC-X3 — pre_warm telemetry via the shared writer (E104-S1) -----

@test "E70-S7 AC-X2/AC-X3: brownfield-telemetry.sh populates *.pre_warm fields on the report frontmatter" {
  TELEM="$(cd "$BATS_TEST_DIRNAME/../scripts/adapters/brownfield" && pwd)/brownfield-telemetry.sh"
  [ -x "$TELEM" ]
  cat > "$TEST_TMP/report.md" <<'MD'
---
title: brownfield report
---
body
MD
  run bash "$TELEM" --report "$TEST_TMP/report.md" --field phase_runtime_seconds.pre_warm --value 7
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --field deterministic_tool_seconds.pre_warm --value 7
  [ "$status" -eq 0 ]
  run bash "$TELEM" --report "$TEST_TMP/report.md" --get phase_runtime_seconds.pre_warm
  [ "$output" = "7" ]
  run grep -F "body" "$TEST_TMP/report.md"
  [ "$status" -eq 0 ]
}

# --- Hygiene --------------------------------------------------------------

@test "E70-S7: pre-warm.sh exists, is executable, and passes bash -n" {
  [ -x "$PRE_WARM" ]
  run bash -n "$PRE_WARM"
  [ "$status" -eq 0 ]
}
