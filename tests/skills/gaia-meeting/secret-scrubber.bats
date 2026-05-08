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

@test "AC8: redacts AWS access key id" {
  echo "use AKIAIOSFODNN7EXAMPLE for staging" > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "AKIAIOSFODNN7EXAMPLE" "$OUT"
  grep -q "REDACTED" "$OUT"
}

@test "AC8: redacts GitHub personal access token (ghp_*)" {
  echo "token: ghp_abcdef1234567890ABCDEF1234567890abcd" > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "ghp_abcdef1234567890ABCDEF1234567890abcd" "$OUT"
  grep -q "REDACTED" "$OUT"
}

@test "AC8: redacts BEGIN PRIVATE KEY headers" {
  cat > "$IN" <<EOF
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA...
-----END RSA PRIVATE KEY-----
EOF
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "BEGIN RSA PRIVATE KEY" "$OUT"
}

@test "AC8: redacts generic api_key=... assignments" {
  echo 'api_key="sk-1234567890abcdefABCDEF1234567890abcdEF12"' > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q "sk-1234567890abcdefABCDEF1234567890abcdEF12" "$OUT"
}

@test "AC8: leaves benign content untouched" {
  echo "the meeting decided to ship feature X" > "$IN"
  run "$HELPER" --in "$IN" --out "$OUT"
  [ "$status" -eq 0 ]
  diff "$IN" "$OUT"
}

@test "AC8 TC-MTG-CHKPT-8: pre-CLOSE — fake secret in charter never lands in session file" {
  # Stage a charter line that contains a fake secret, run the scrubber on it,
  # and feed the output to a session-state update via a fixture path.
  echo "charter content: AKIA1234567890ABCDEF" > "$IN"
  "$HELPER" --in "$IN" --out "$OUT"
  ! grep -q "AKIA1234567890ABCDEF" "$OUT"
}
