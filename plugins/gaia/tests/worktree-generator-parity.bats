#!/usr/bin/env bats
# worktree-generator-parity.bats — scan-based generators must produce identical
# results in a story worktree and in the primary tree for the same content.
#
# Both the component tagger and the leak-gate suites resolve their scan root
# relative to their own file location, so parity is a property of WHICH COPY of
# the file is invoked: running the worktree's copy must yield exactly what the
# primary's copy yields. A worktree that is missing files (a sparse or partial
# checkout) must make that divergence LOUD rather than silently emitting a
# smaller manifest.
#
# Real repos and real worktrees; the tagger under test is the real script,
# copied into the fixture so both trees hold a genuine copy of it.

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export PLUGIN_ROOT
  TAGGER="$PLUGIN_ROOT/scripts/bats-component-tagger.sh"
  LIB="$PLUGIN_ROOT/scripts/lib/story-worktree.sh"
  # Worktree mode is opt-in and enforced by the library; these tests create real
  # worktrees, so switch it on explicitly.
  export GAIA_WORKTREE_MODE=1
}

teardown() { common_teardown; }

_source_lib() {
  [ -f "$LIB" ] || return 1
  # shellcheck disable=SC1090
  . "$LIB"
}

# _mk_scanned_repo <dir> — a repo whose layout mirrors the real one closely
# enough for the tagger: scripts/ alongside tests/, with a few bats files.
_mk_scanned_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts/lib" "$dir/tests"
  cp "$TAGGER" "$dir/scripts/bats-component-tagger.sh"
  chmod +x "$dir/scripts/bats-component-tagger.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$dir/scripts/lib/helper-one.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$dir/scripts/top-level-one.sh"

  # The fixture suites are assembled with printf so that no line of THIS file
  # starts with the bats test keyword: bats 1.10 counts such lines inside
  # heredocs toward its plan and then reports a plan/execution mismatch.
  local kw='@test'
  printf '#!/usr/bin/env bats\nsetup() { LIB_DIR="$BATS_TEST_DIRNAME/../scripts/lib"; }\n%s "alpha exercises the shared helper (fixture)" {\n  [ -f "$LIB_DIR/helper-one.sh" ]\n}\n' "$kw" > "$dir/tests/alpha.bats"
  printf '#!/usr/bin/env bats\nsetup() { SCRIPTS_DIR="$BATS_TEST_DIRNAME/../scripts"; }\n%s "beta exercises a top-level script (fixture)" {\n  [ -f "$SCRIPTS_DIR/top-level-one.sh" ]\n}\n' "$kw" > "$dir/tests/beta.bats"
  printf '#!/usr/bin/env bats\n%s "gamma makes no resolvable code reference (fixture)" {\n  true\n}\n' "$kw" > "$dir/tests/gamma.bats"

  git -C "$dir" init -q -b main .
  git -C "$dir" config user.email "test@example.invalid"
  git -C "$dir" config user.name "Test User"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "seed the scanned tree"
  ( cd "$dir" && pwd )
}

# _install_real_leak_gate <root> — place the REAL leak-gate suite inside <root>
# so it resolves its scan root from its own location, the way it does in the
# repository. Driving the real suite (rather than a local approximation) is what
# makes this a parity test: the suite's own exemption rules and root resolution
# are part of what must agree between the two trees.
_install_real_leak_gate() {
  local root="$1" src="$PLUGIN_ROOT/tests/no-leaked-ids-in-prose.bats"
  local helper="$PLUGIN_ROOT/tests/test_helper.bash"
  [ -f "$src" ] && [ -f "$helper" ] || return 1
  mkdir -p "$root/tests"
  cp "$src" "$root/tests/no-leaked-ids-in-prose.bats"
  cp "$helper" "$root/tests/test_helper.bash"
}

# _leak_verdict <root> — run the real leak gate inside <root> and echo a stable
# verdict plus the sorted failing-test names, so two roots can be compared.
_leak_verdict() {
  local root="$1" out
  out="$( cd "$root" && bats tests/no-leaked-ids-in-prose.bats 2>&1 )" || true
  # A suite that failed to load reports a single gather-tests failure and would
  # make two broken runs compare equal. Refuse that rather than pass vacuously.
  if printf '%s\n' "$out" | grep -qF 'bats-gather-tests'; then
    printf 'LEAK-GATE-FAILED-TO-LOAD\n'
    return 0
  fi
  printf '%s\n' "$out" | grep -E '^(ok|not ok) ' | sed 's/[0-9][0-9]* //' | LC_ALL=C sort
}

@test "the component tagger produces byte-identical output from the worktree and the primary tree (AC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_scanned_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KP-S1" "slug")"

  local from_primary="$TEST_TMP/out-primary.tsv"
  local from_worktree="$TEST_TMP/out-worktree.tsv"
  bash "$primary/scripts/bats-component-tagger.sh" --format tsv > "$from_primary"
  bash "$wt/scripts/bats-component-tagger.sh" --format tsv > "$from_worktree"

  [ -s "$from_primary" ]
  diff -u "$from_primary" "$from_worktree"
}

@test "the leak-gate suites detect the same violations in the worktree and the primary tree (AC5)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_scanned_repo "$TEST_TMP/primary")"
  # Seed a violation so the comparison is between two NON-empty sets.
  # Plant the violation in a directory the gate actually scans. A .md file
  # directly inside tests/ is deliberately exempt (developer test documentation),
  # so a fixture placed there would be invisible to the real gate and the
  # comparison below would be between two clean runs.
  # Synthesize the identifier shape from parts rather than writing it literally,
  # so this fixture stays inert if a future gate widens to .bats bodies.
  mkdir -p "$primary/skills/sample-skill"
  printf 'prose citing %s-%s in published text\n' "FR" "123" \
    > "$primary/skills/sample-skill/SKILL.md"
  git -C "$primary" add -A
  git -C "$primary" commit -qm "add a file carrying a leaked identifier shape"

  local wt; wt="$(worktree_create "$primary" "KP-S2" "slug")"

  _install_real_leak_gate "$primary" || skip "leak gate suite not available"
  git -C "$primary" add -A
  git -C "$primary" commit -qm "install the leak gate into the scanned tree"

  local wt2; wt2="$(worktree_create "$primary" "KP-S5" "slug")"

  local a="$TEST_TMP/leak-primary.txt" b="$TEST_TMP/leak-worktree.txt"
  _leak_verdict "$primary" > "$a"
  _leak_verdict "$wt2" > "$b"
  [ -s "$a" ]
  grep -qF 'LEAK-GATE-FAILED-TO-LOAD' "$a" && { echo "leak gate did not load in the primary tree"; return 1; }
  # The planted violation must actually be detected, or the comparison below is
  # between two clean runs and proves nothing.
  grep -qE '^not ok ' "$a" || { echo "leak gate reported no violation for the planted fixture"; return 1; }
  diff -u "$a" "$b"
}

@test "a worktree missing files from the primary tree makes the parity assertion fail loudly (AC-EC6)" {
  _source_lib || { echo "library not implemented: $LIB"; return 1; }
  local primary; primary="$(_mk_scanned_repo "$TEST_TMP/primary")"
  local wt; wt="$(worktree_create "$primary" "KP-S3" "slug")"

  # Simulate a sparse / partial checkout: a scanned file is absent downstream.
  rm -f "$wt/tests/beta.bats"

  local from_primary="$TEST_TMP/out-primary.tsv"
  local from_worktree="$TEST_TMP/out-worktree.tsv"
  bash "$primary/scripts/bats-component-tagger.sh" --format tsv > "$from_primary"
  bash "$wt/scripts/bats-component-tagger.sh" --format tsv > "$from_worktree"

  # The divergence must be detectable, never silent.
  run diff -q "$from_primary" "$from_worktree"
  [ "$status" -ne 0 ]
}

@test "the tagger output does not depend on the invoking working directory (AC5)" {
  local primary; primary="$(_mk_scanned_repo "$TEST_TMP/primary")"
  local elsewhere="$TEST_TMP/elsewhere"
  mkdir -p "$elsewhere"

  local a="$TEST_TMP/cwd-a.tsv" b="$TEST_TMP/cwd-b.tsv"
  ( cd "$primary" && bash "$primary/scripts/bats-component-tagger.sh" --format tsv ) > "$a"
  ( cd "$elsewhere" && bash "$primary/scripts/bats-component-tagger.sh" --format tsv ) > "$b"
  [ -s "$a" ]
  diff -u "$a" "$b"
}
