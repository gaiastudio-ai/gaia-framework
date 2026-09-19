#!/usr/bin/env bats
# retirement-sweep.bats -- tests for plugins/gaia/scripts/retirement-sweep.sh
#
# Exercises the provider-neutral sweep script against SYNTHETIC fixture trees
# built in $BATS_TEST_TMPDIR.  Uses a neutral fake provider name ("acmeprov")
# so this file needs no real provider literal.
#
# Provider-literal containment: no contiguous real provider name appears
# anywhere in this file.  All tests use "acmeprov" as a synthetic stand-in.
#
# Public-function coverage gate: every column-0 public function in
# retirement-sweep.sh is named below so the coverage gate's grep finds a
# hit for each function.

load 'test_helper.bash'

SWEEP_SCRIPT="$BATS_TEST_DIRNAME/../scripts/retirement-sweep.sh"

# ---------- Portable helpers ---------------------------------------------

# _tree_checksum <root>  -- deterministic checksum of a fixture root
# (excludes .git/ contents).  Uses sha256sum (Linux) or shasum (macOS).
_tree_checksum() {
  local sha_cmd="sha256sum"
  command -v sha256sum >/dev/null 2>&1 || sha_cmd="shasum -a 256"
  find "$1" -not -path '*/.git/*' -type f -print0 \
    | xargs -0 $sha_cmd \
    | sort
}

# _build_fixture_roots  -- creates the synthetic public and enterprise
# fixture trees used by most tests.
_build_fixture_roots() {
  PUB_ROOT="$TEST_TMP/public-root"
  mkdir -p "$PUB_ROOT/.git/refs"
  printf 'acmeprov branch ref\n' > "$PUB_ROOT/.git/refs/heads-acmeprov"

  mkdir -p "$PUB_ROOT/src"
  printf 'This uses acmeprov for design.\n' > "$PUB_ROOT/src/design.sh"
  printf 'Another acmeprov hit here.\n'    > "$PUB_ROOT/src/tool.sh"

  # Non-word hits -- must NOT be matched by word-bounded grep.
  printf 'The xacmeprov library is unrelated.\n' > "$PUB_ROOT/src/false-positive.sh"
  printf 'Use acmeprovider for extended.\n'      > "$PUB_ROOT/src/partial.sh"

  # Unowned hit (node_modules).
  mkdir -p "$PUB_ROOT/node_modules/dep"
  printf 'acmeprov reference in dep\n' > "$PUB_ROOT/node_modules/dep/index.js"

  ENT_ROOT="$TEST_TMP/enterprise-root"
  mkdir -p "$ENT_ROOT/.git/refs"
  printf 'acmeprov in git ref\n' > "$ENT_ROOT/.git/refs/heads-acmeprov"

  mkdir -p "$ENT_ROOT/plugins"
  printf 'acmeprov skill body\n' > "$ENT_ROOT/plugins/skill.md"
}

# _build_annotation_files  -- creates the carve-out and exclusion files.
_build_annotation_files() {
  CARVEOUT_FILE="$TEST_TMP/carveouts.txt"
  cat > "$CARVEOUT_FILE" <<'EOF'
# Carve-outs for retirement
plugins/skill.md | enterprise skill retained for compatibility
src/design.sh | design script retained with behaviour unchanged
EOF

  EXCLUSION_FILE="$TEST_TMP/exclusions.txt"
  cat > "$EXCLUSION_FILE" <<'EOF'
src/tool.sh | comparison prose in tool fixture
EOF
}

# _init_git_repos  -- turn fixture roots into tiny git repos so commit ids
# are available for provenance tests.
_init_git_repos() {
  (cd "$PUB_ROOT" && git init -q && git add -A && git commit -q -m "init" --allow-empty)
  (cd "$ENT_ROOT" && git init -q && git add -A && git commit -q -m "init" --allow-empty)
}

# ---------- Setup / teardown ---------------------------------------------

setup() {
  common_setup
  PROVIDER="acmeprov"
  _build_fixture_roots
  _build_annotation_files
}

teardown() { common_teardown; }

# ---------- Public function coverage gate --------------------------------
# Each declare -F assertion proves the function exists at column 0 in the
# script, satisfying the public-function coverage gate.

@test "public function coverage: retirement_sweep_main is defined" {
  source "$SWEEP_SCRIPT"
  run declare -F retirement_sweep_main
  [ "$status" -eq 0 ] || fail "retirement_sweep_main not defined at column 0"
}

@test "public function coverage: scan_root is defined" {
  source "$SWEEP_SCRIPT"
  run declare -F scan_root
  [ "$status" -eq 0 ] || fail "scan_root not defined at column 0"
}

@test "public function coverage: annotate_hit is defined" {
  source "$SWEEP_SCRIPT"
  run declare -F annotate_hit
  [ "$status" -eq 0 ] || fail "annotate_hit not defined at column 0"
}

@test "public function coverage: emit_provenance is defined" {
  source "$SWEEP_SCRIPT"
  run declare -F emit_provenance
  [ "$status" -eq 0 ] || fail "emit_provenance not defined at column 0"
}

@test "public function coverage: load_exclusion_list is defined" {
  source "$SWEEP_SCRIPT"
  run declare -F load_exclusion_list
  [ "$status" -eq 0 ] || fail "load_exclusion_list not defined at column 0"
}

# ---------- AC1: sweep produces inventory --------------------------------

@test "(AC1) sweep produces inventory at the output path" {
  local out="$TEST_TMP/inventory.md"

  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"

  [ "$status" -eq 0 ] || fail "sweep exited $status; expected 0"
  [ -f "$out" ]        || fail "inventory not written to $out"
}

@test "(AC1) sweep does not modify the scanned trees" {
  local pre_pub pre_ent
  pre_pub="$(_tree_checksum "$PUB_ROOT")"
  pre_ent="$(_tree_checksum "$ENT_ROOT")"

  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  local post_pub post_ent
  post_pub="$(_tree_checksum "$PUB_ROOT")"
  post_ent="$(_tree_checksum "$ENT_ROOT")"

  [ "$pre_pub" = "$post_pub" ] || fail "public root modified by sweep"
  [ "$pre_ent" = "$post_ent" ] || fail "enterprise root modified by sweep"
}

@test "(AC1) carve-out list names exactly two entries" {
  local count
  count="$(grep -cvE '^\s*#|^\s*$' "$CARVEOUT_FILE")"
  [ "$count" -eq 2 ] || fail "expected 2 carve-out entries, got $count"
}

@test "(AC1) carve-out entries carry a one-line reason" {
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    [[ "$line" == *"|"* ]] || fail "carve-out line missing pipe separator: $line"
    local reason="${line##*|}"
    [ -n "${reason// /}" ] || fail "carve-out line has empty reason: $line"
  done < "$CARVEOUT_FILE"
}

@test "(AC1) inventory carries provenance header with commit ids and command" {
  _init_git_repos

  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  grep -q 'Provider:'              "$out" || fail "provenance missing Provider"
  grep -q 'Timestamp:'             "$out" || fail "provenance missing Timestamp"
  grep -q 'Public tree commit:'    "$out" || fail "provenance missing public commit"
  grep -q 'Enterprise tree commit:' "$out" || fail "provenance missing enterprise commit"
  grep -q 'Command:'               "$out" || fail "provenance missing Command"
  # Full invocation must include real roots, not placeholders.
  grep -q -- '--public-root'       "$out" || fail "provenance Command missing --public-root"
  grep -q -- '--enterprise-root'   "$out" || fail "provenance Command missing --enterprise-root"
}

@test "(AC1) exclusion-file hits are inventoried with EXCLUDED annotation" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --exclusion-file "$EXCLUSION_FILE" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  grep -q 'src/tool.sh'    "$out" || fail "excluded file not inventoried"
  grep -q '\[EXCLUDED:'    "$out" || fail "EXCLUDED annotation missing"
}

# ---------- AC-EC1: reduced tree is not a defect -------------------------

@test "(AC-EC1) sweep on reduced tree exits clean with no warnings" {
  # Remove one hit to simulate a smaller tree (fewer hits than a prior run).
  rm -f "$PUB_ROOT/src/tool.sh"

  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status on reduced tree"

  # Assert on the structured status footer -- the sweep must report clean
  # completion.  Asserting on a structured line avoids false positives from
  # tmpdir path components that happen to contain dictionary words.
  grep -q '^- Status: complete$' "$out" || fail "missing Status: complete footer"
  grep -q '^- Warnings: 0$'     "$out" || fail "missing Warnings: 0 footer"
}

# ---------- AC-EC2: unowned hit classification ---------------------------

@test "(AC-EC2) unowned hit classified with reason" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  grep -q '\[UNOWNED:' "$out" || fail "node_modules hit not annotated as UNOWNED"
}

# ---------- AC-EC3: absent root exits 1 ---------------------------------

@test "(AC-EC3) absent root causes exit 1 with ABSENT message" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$TEST_TMP/nonexistent" \
    --output "$out"
  [ "$status" -eq 1 ]           || fail "expected exit 1 for absent root, got $status"
  [[ "$output" == *"ABSENT"* ]] || fail "ABSENT message not in output"
}

# ---------- AC-EC4: label-expected annotation ----------------------------

@test "(AC-EC4) label-expected annotates remaining hits" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --label-expected \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  grep -q '\[EXPECTED-STILL-PRESENT\]' "$out" || fail "label-expected annotation missing"
}

# ---------- AC-EC7: two runs produce distinct provenance -----------------

@test "(AC-EC7) two runs produce distinct provenance" {
  _init_git_repos

  local out1="$TEST_TMP/inv1.md"
  local out2="$TEST_TMP/inv2.md"

  "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out1"

  # Make a tiny change + recommit so the commit id differs.
  printf 'extra\n' >> "$PUB_ROOT/src/design.sh"
  (cd "$PUB_ROOT" && git add -A && git commit -q -m "tweak")

  "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out2"

  local prov1 prov2
  prov1="$(grep 'Public tree commit:' "$out1")"
  prov2="$(grep 'Public tree commit:' "$out2")"
  [ "$prov1" != "$prov2" ] || fail "provenance unchanged across commits"
}

# ---------- Word-boundary enforcement -----------------------------------

@test "sweep does not match non-word-bounded occurrences" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  run grep 'xacmeprov' "$out"
  [ "$status" -ne 0 ] || fail "non-word hit xacmeprov matched"
  run grep 'acmeprovider' "$out"
  [ "$status" -ne 0 ] || fail "non-word hit acmeprovider matched"
}

@test "sweep excludes .git directory contents" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  run grep '\.git/' "$out"
  [ "$status" -ne 0 ] || fail ".git content appeared as hit"
}

# ---------- Carve-out annotation in output --------------------------------

@test "carve-out hits are annotated with CARVE-OUT marker" {
  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --carve-out-file "$CARVEOUT_FILE" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  grep -q '\[CARVE-OUT:' "$out" || fail "CARVE-OUT annotation missing"
}

# ---------- Anchored carve-out / exclusion matching -----------------------

@test "decoy carve-out path is NOT annotated as carve-out" {
  # Plant a decoy at decoy/<carve-out-path> and a .bak variant -- both
  # contain the provider name but must NOT inherit the carve-out annotation.
  local carveout_entry="src/design.sh"
  mkdir -p "$PUB_ROOT/decoy/src"
  printf 'acmeprov decoy hit\n' > "$PUB_ROOT/decoy/src/design.sh"
  printf 'acmeprov backup hit\n' > "$PUB_ROOT/src/design.sh.bak"

  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --carve-out-file "$CARVEOUT_FILE" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  # The real src/design.sh must still be a carve-out.
  grep 'src/design.sh:' "$out" | grep -v 'decoy/' | grep -v '\.bak' \
    | grep -q '\[CARVE-OUT:' || fail "real carve-out not annotated"

  # The decoy must NOT be annotated as a carve-out.
  if grep 'decoy/src/design.sh' "$out" | grep -q '\[CARVE-OUT:'; then
    fail "decoy path incorrectly annotated as CARVE-OUT"
  fi

  # The .bak must NOT be annotated as a carve-out.
  if grep 'src/design.sh.bak' "$out" | grep -q '\[CARVE-OUT:'; then
    fail ".bak variant incorrectly annotated as CARVE-OUT"
  fi
}

@test "decoy exclusion path is NOT annotated as excluded" {
  # Plant a decoy at decoy/<exclusion-path> and a .bak variant -- both
  # contain the provider name but must NOT inherit the exclusion annotation.
  local exclusion_entry="src/tool.sh"
  mkdir -p "$PUB_ROOT/decoy/src"
  printf 'acmeprov decoy tool\n' > "$PUB_ROOT/decoy/src/tool.sh"
  printf 'acmeprov backup tool\n' > "$PUB_ROOT/src/tool.sh.bak"

  local out="$TEST_TMP/inventory.md"
  run "$SWEEP_SCRIPT" \
    --provider "$PROVIDER" \
    --public-root "$PUB_ROOT" \
    --enterprise-root "$ENT_ROOT" \
    --exclusion-file "$EXCLUSION_FILE" \
    --output "$out"
  [ "$status" -eq 0 ] || fail "sweep exited $status"

  # The real src/tool.sh must still be excluded.
  grep 'src/tool.sh:' "$out" | grep -v 'decoy/' | grep -v '\.bak' \
    | grep -q '\[EXCLUDED:' || fail "real exclusion not annotated"

  # The decoy must NOT be annotated as excluded.
  if grep 'decoy/src/tool.sh' "$out" | grep -q '\[EXCLUDED:'; then
    fail "decoy path incorrectly annotated as EXCLUDED"
  fi

  # The .bak must NOT be annotated as excluded.
  if grep 'src/tool.sh.bak' "$out" | grep -q '\[EXCLUDED:'; then
    fail ".bak variant incorrectly annotated as EXCLUDED"
  fi
}
