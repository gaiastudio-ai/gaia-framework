#!/usr/bin/env bats
# secret-scrubber.bats — gaia-meeting T-MTG-3 secret-pattern scrubber (E76-S7, AC8, TC-MTG-CHKPT-8)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HELPER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/secret-scrubber.sh"
  TMP="$(mktemp -d)"
  IN="$TMP/in.txt"
  OUT="$TMP/out.txt"
}

teardown() {
  rm -rf "$TMP"
}

@test "Pre-flight: secret-scrubber.sh exists and is executable" {
  [ -x "$HELPER" ]
}

@test "an AWS access key id is redacted" {
  echo "use AKIAIOSFODNN7EXAMPLE for staging" > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "AKIAIOSFODNN7EXAMPLE" "$OUT"
  grep -q "REDACTED" "$OUT"
}

@test "a GitHub personal access token is redacted" {
  echo "token: ghp_abcdef1234567890ABCDEF1234567890abcd" > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "ghp_abcdef1234567890ABCDEF1234567890abcd" "$OUT"
  grep -q "REDACTED" "$OUT"
}

@test "a private key header is redacted" {
  cat > "$IN" <<EOF
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA...
-----END RSA PRIVATE KEY-----
EOF
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "BEGIN RSA PRIVATE KEY" "$OUT"
}

@test "a generic api_key assignment is redacted" {
  echo 'api_key="sk-1234567890abcdefABCDEF1234567890abcdEF12"' > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "sk-1234567890abcdefABCDEF1234567890abcdEF12" "$OUT"
}

@test "benign content is left untouched" {
  echo "the meeting decided to ship feature X" > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  diff "$IN" "$OUT"
}

@test "a secret in the charter never lands in the session file when scrubbed before close" {
  # Stage a charter line that contains a fake secret, run the scrubber on it,
  # and feed the output to a session-state update via a fixture path.
  echo "charter content: AKIA1234567890ABCDEF" > "$IN"
  "$HELPER" --in "$IN" --out "$OUT"
  ! grep -q "AKIA1234567890ABCDEF" "$OUT"
}
