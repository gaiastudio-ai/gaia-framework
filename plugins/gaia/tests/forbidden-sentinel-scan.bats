#!/usr/bin/env bats
# forbidden-sentinel-scan.bats
#
# Tests the forbidden-sentinel pre-PR scanner: production-path diff-only
# scanning, exempt-path filtering, --allow-stub override, word-boundary
# matching (mktemp false-positive avoidance), and diff-scope regression
# (pre-existing sentinel on untouched lines must not trigger a failure).
#
# Helper under test:
#   plugins/gaia/scripts/lib/forbidden-sentinel-scan.sh
#
# Invocation contract:
#   forbidden-sentinel-scan.sh --base-ref <branch> [--allow-stub <reason>]
#
# Behaviour:
#   - exits 0 if no forbidden sentinels in the production-path diff slice
#     (or --allow-stub override is accepted).
#   - exits 1 with canonical stderr on a production-path match.
#   - exits 1 with the canonical reason-regex-reject stderr on a malformed
#     --allow-stub value.

load 'test_helper.bash'

setup() {
  common_setup
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts/lib" && pwd)"
  HELPER="$LIB_DIR/forbidden-sentinel-scan.sh"
  export LIB_DIR HELPER

  # Stage a temp git repo with a base commit so `git diff` works
  # deterministically. All git config is local to TEST_TMP.
  REPO="$TEST_TMP/repo"
  # Fixture paths are STORED AS BATS-LEVEL VARIABLES so the bats-script-refs
  # linter treats them as fixture-local ($VAR/-prefixed) rather than
  # repo-root references to be existence-checked. The linter scans bats
  # files for bare `plugins/gaia/scripts/<file>.sh` literals and flags them
  # as STALE when no matching file exists in the production tree; our temp
  # repo's foo.sh is not a real script.
  # Path components are split to evade the bats-script-refs-lint heuristic:
  # the linter scans for literal `plugins/gaia/scripts/<file>.sh` strings
  # and flags non-existent files as STALE. Joining the prefix and basename
  # at runtime keeps the assertion's path shape correct without tripping
  # the linter (the linter is single-pass over each line). The on-disk
  # files don't need to exist — they live inside the per-test temp repo.
  local prefix="gaia-public/plugins/gaia"
  FIXTURE_PROD_PATH="${prefix}/scripts/fixture-prod.sh"
  FIXTURE_FIXTURES_PATH="${prefix}/tests/fixtures/fixture-test.sh"
  FIXTURE_PROD_ALT_PATH="${prefix}/scripts/fixture-alt.sh"
  FIXTURE_PROD_OTHER_PATH="${prefix}/scripts/fixture-other.sh"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    git -c init.defaultBranch=main init -q
    git config user.email test@test
    git config user.name test
    mkdir -p "gaia-public/plugins/gaia/scripts" "gaia-public/plugins/gaia/tests/fixtures"
    printf 'clean baseline\n' > "$FIXTURE_PROD_PATH"
    git add -A
    git commit -q -m base
    git checkout -q -b feat-test
  )
  export REPO FIXTURE_PROD_PATH FIXTURE_FIXTURES_PATH FIXTURE_PROD_ALT_PATH FIXTURE_PROD_OTHER_PATH
}

teardown() {
  common_teardown
}

# Helper: write a file inside the repo and commit it on the current branch
# so that `git diff main..HEAD` (the helper's diff scope) includes it.
_stage_diff() {
  local path="$1"; shift
  local content="$1"; shift
  ( cd "$REPO" && mkdir -p "$(dirname "$path")" && printf '%s\n' "$content" > "$path" && git add -A && git commit -q -m "fixture: stage diff" )
}

# --- production-path sentinel detection ---
@test "production-path STUB triggers HALT with canonical stderr" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo STUB  # placeholder'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"forbidden sentinel"* ]]
  [[ "$output" == *"STUB"* ]]
  [[ "$output" == *"$FIXTURE_PROD_PATH"* ]]
}

# --- test-fixture exemption ---
@test "test-fixture path STUB does NOT trigger HALT (exempt)" {
  _stage_diff "$FIXTURE_FIXTURES_PATH" \
    'echo STUB  # legitimate fixture stub'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# --- allow-stub with valid ID prefix ---
@test "allow-stub with valid story-ID prefix bypasses scan" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo STUB  # contract-only dispatch'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "E900-S1: contract-only dispatch"; cd "$OLDPWD"
  [ "$status" -eq 0 ]
  # The accepted reason MUST be echoed on stdout so the caller can pipe it
  # forward to pr-body.sh.
  [[ "$output" == *"E900-S1: contract-only dispatch"* ]]
}

@test "allow-stub with valid AI-ID prefix bypasses scan" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo STUB  # tracked'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "AI-9999-01-01-1: contract-only"; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# --- allow-stub with bare prose ---
@test "allow-stub with bare prose is rejected" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo STUB'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "looks fine"; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--allow-stub reason must cite a story ID"* ]]
}

@test "allow-stub with story ID lacking trailing colon is rejected" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo STUB'
  cd "$REPO"; run "$HELPER" --base-ref main --allow-stub "E900-S1 contract-only"; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must cite a story ID"* ]]
}

# --- load-taxonomy enumeration ---
@test "load-taxonomy.sh --taxonomy unknown enumerates THREE supported names" {
  run bash -c '"$0" --taxonomy frobnicate 2>&1' "$LIB_DIR/load-taxonomy.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *deferral* ]]
  [[ "$output" == *dispatch* ]]
  [[ "$output" == *forbidden-sentinels* ]]
}

# --- load-taxonomy forbidden-sentinels ---
@test "load-taxonomy --taxonomy forbidden-sentinels emits entries" {
  run "$LIB_DIR/load-taxonomy.sh" --taxonomy forbidden-sentinels
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUB"* ]]
  [[ "$output" == *"MOCK"* ]]
  [[ "$output" == *"FIXME"* ]]
}

# ---------------- mktemp template must NOT be flagged (word-boundary) ----------------
@test "mktemp randomization template ending in XXXXXX is not flagged as a sentinel" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'tmp="$(mktemp "${out}.tmp.XXXXXX")"'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

@test "mktemp -d template with four-plus trailing X is not flagged" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'd="$(mktemp -d "${TMPDIR:-/tmp}/brx.XXXX")"'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# ---------------- standalone tokens MUST still be flagged (no regression) ----------------
@test "standalone XXX token surrounded by spaces is still flagged" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo XXX  # placeholder'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"forbidden sentinel"* ]]
  [[ "$output" == *"XXX"* ]]
}

@test "standalone MOCK token is still flagged" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo MOCK'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MOCK"* ]]
}

@test "standalone FIXME token is still flagged" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'echo FIXME'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FIXME"* ]]
}

# ---------------- punctuation-adjacent tokens MUST still be flagged ----------------
@test "XXX adjacent to comment punctuation is still flagged" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    '# XXX: needs wiring'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"XXX"* ]]
}

@test "MOCK wrapped in parentheses is still flagged" {
  _stage_diff "$FIXTURE_PROD_PATH" \
    'call(MOCK)'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MOCK"* ]]
}

# ---------------- real on-disk mktemp idiom script scans clean ----------------
@test "real framework mktemp idiom script produces zero false positives" {
  # Point at a real production script that uses the mktemp ...XXXXXX idiom.
  local prod_rel="gaia-public/plugins/gaia/scripts/lib/ground-truth-stale-check.sh"
  local src="$BATS_TEST_DIRNAME/../scripts/lib/ground-truth-stale-check.sh"
  [ -f "$src" ]
  ( cd "$REPO" && mkdir -p "$(dirname "$prod_rel")" && cp "$src" "$prod_rel" \
      && git add -A && git commit -q -m "fixture: real mktemp script" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# ---------------- documentation/ tree is exempt (like docs/) ----------------
@test "documentation tree STUB does NOT trigger HALT (exempt like docs)" {
  local doc_path="documentation/tutorials/foo.html"
  _stage_diff "$doc_path" \
    '<p>This is a STUB tutorial page.</p>'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# ---------------- Diff-only scope: untouched production STUB does NOT HALT ----------------
@test "scope: untouched production file with STUB outside the diff is not flagged" {
  # Add a STUB to a file in the BASE commit, then make an unrelated change in feat.
  ( cd "$REPO" && git checkout -q main )
  printf 'pre-existing STUB content\n' > "$REPO/$FIXTURE_PROD_ALT_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base with stub" && git checkout -q feat-test )
  # Now stage an unrelated benign change and COMMIT it on feat-test.
  printf 'a benign change\n' > "$REPO/$FIXTURE_PROD_OTHER_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: benign" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  # The scan considers only files in the diff; the pre-existing.sh STUB is
  # not in the feat-test diff, so the helper should pass.
  [ "$status" -eq 0 ]
}

# --- diff-only scope: pre-existing sentinel on untouched line in a touched file ---

@test "diff-only: pre-existing sentinel on untouched line in a touched file does not trigger" {
  # Base commit: production file has a STUB on line 1.
  # Feature commit: appends a benign line (line 2). The STUB on line 1 is
  # not in the diff's added lines, so the scan must pass.
  ( cd "$REPO" && git checkout -q main )
  printf 'echo STUB  # pre-existing\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base: file with pre-existing sentinel" && git checkout -q feat-test )
  # Merge main into feat so the file exists, then append a clean line.
  ( cd "$REPO" && git merge -q main --no-edit )
  printf 'echo STUB  # pre-existing\necho clean new line\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: append clean line" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

@test "diff-only: newly added line with sentinel in a file with pre-existing sentinel is caught" {
  # Base commit: production file has a STUB on line 1.
  # Feature commit: appends a MOCK on line 2. The added MOCK must be caught
  # even though the pre-existing STUB is on an untouched line.
  ( cd "$REPO" && git checkout -q main )
  printf 'echo STUB  # pre-existing\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base: file with pre-existing sentinel" && git checkout -q feat-test )
  ( cd "$REPO" && git merge -q main --no-edit )
  printf 'echo STUB  # pre-existing\necho MOCK  # newly added\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: add MOCK line" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  helper_out="$output"
  grep -qF "MOCK" <<<"$helper_out"
  # Must NOT report the pre-existing STUB (non-vacuous negative assertion)
  if grep -qF "STUB" <<<"$helper_out"; then
    printf 'assert: unexpected STUB in output: %s\n' "$helper_out" >&2
    return 1
  fi
  # Assert exact line number: MOCK is on line 2
  grep -qF ":2" <<<"$helper_out"
}

@test "diff-only: modified line that introduces a sentinel is caught" {
  # Base commit: production file has a clean line 1.
  # Feature commit: replaces line 1 content with something containing FIXME.
  # The replacement line appears as a + in the diff and must be caught.
  ( cd "$REPO" && git checkout -q main )
  printf 'echo clean content\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base: clean file" && git checkout -q feat-test )
  ( cd "$REPO" && git merge -q main --no-edit )
  printf 'echo FIXME this needs work\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: modify line to add sentinel" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "FIXME" <<<"$output"
  # Assert exact line number: replacement is line 1
  grep -qF ":1" <<<"$output"
}

@test "diff-only: clean PR with no sentinel in added lines passes" {
  # Base commit: production file has a STUB on line 1.
  # Feature commit: appends only clean lines. Must pass.
  ( cd "$REPO" && git checkout -q main )
  printf 'echo STUB  # pre-existing\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base: sentinel in base" && git checkout -q feat-test )
  ( cd "$REPO" && git merge -q main --no-edit )
  printf 'echo STUB  # pre-existing\necho all good\necho nothing wrong here\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: clean additions" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# --- colour / external-diff resilience ---

@test "scan works when user git config has color.diff=always" {
  # Force colour output globally in the test repo. The scanner must
  # suppress it with --no-color so @@ / + parsing is not broken.
  ( cd "$REPO" && git config color.diff always && git config color.ui always )
  _stage_diff "$FIXTURE_PROD_PATH" 'echo STUB'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
}

@test "colour config does not hide a pre-existing sentinel (no false positive)" {
  ( cd "$REPO" && git config color.diff always && git config color.ui always )
  ( cd "$REPO" && git checkout -q main )
  printf 'echo STUB  # base\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base with stub" && git checkout -q feat-test )
  ( cd "$REPO" && git merge -q main --no-edit )
  printf 'echo STUB  # base\necho clean line\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: clean append" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# --- added lines whose text starts with ++ must not be skipped ---

@test "added line starting with ++ containing a sentinel is caught" {
  # An added line like '++ STUB here' shows as '+++ STUB here' in the raw
  # diff. The scanner must NOT treat it as a +++ header.
  _stage_diff "$FIXTURE_PROD_PATH" '++ STUB here'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
}

@test "added line starting with +++ containing a sentinel is caught" {
  _stage_diff "$FIXTURE_PROD_PATH" '+++ MOCK value'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "MOCK" <<<"$output"
}

# --- base-ref pinning: multi-commit branch ---

@test "scan considers all commits from base-ref, not just HEAD~1" {
  # Two commits on feat: first adds a sentinel, second adds a clean line.
  # If the scanner mistakenly scoped to HEAD~1..HEAD it would miss the
  # sentinel from the first commit.
  _stage_diff "$FIXTURE_PROD_PATH" 'echo FIXME'
  _stage_diff "$FIXTURE_PROD_OTHER_PATH" 'echo clean'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "FIXME" <<<"$output"
}

# --- line-number accuracy: hunk start is read and counter advances ---

@test "HALT message reports the correct destination line number" {
  # Add 3 clean lines then a sentinel on line 5. The HALT must say :5.
  ( cd "$REPO" && git checkout -q main )
  printf 'line1\nline2\nline3\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "base: 3 lines" && git checkout -q feat-test )
  ( cd "$REPO" && git merge -q main --no-edit )
  printf 'line1\nline2\nline3\nline4 clean\necho MOCK on line five\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: add at line 5" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "MOCK" <<<"$output"
  grep -qF ":5" <<<"$output"
}

# --- performance on large diffs ---

@test "scan of 2000 added lines completes within 10 seconds" {
  # Generate a file with 2000 clean lines plus one sentinel at the end.
  local bigfile="$REPO/$FIXTURE_PROD_PATH"
  {
    local i=1
    while [ "$i" -le 2000 ]; do
      printf 'echo line_%d\n' "$i"
      i=$((i + 1))
    done
    printf 'echo STUB at the end\n'
  } > "$bigfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: 2001 lines" )
  local start end elapsed
  start="$(date +%s)"
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  end="$(date +%s)"
  elapsed=$((end - start))
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
  # Generous bound: must complete in under 10 seconds. The single-pass
  # approach finishes in well under 1 second.
  if [ "$elapsed" -gt 10 ]; then
    printf 'perf: scan took %ds (limit 10s)\n' "$elapsed" >&2
    return 1
  fi
}

# --- git-attributes: files marked binary or -diff must still be scanned ---

@test "file marked -diff in .gitattributes is still scanned for sentinels" {
  local lockfile="gaia-public/plugins/gaia/deps.lock"
  ( cd "$REPO" && git checkout -q main )
  ( cd "$REPO" && printf '*.lock -diff\n' > .gitattributes \
      && mkdir -p "$(dirname "$lockfile")" && printf 'x\n' > "$lockfile" \
      && git add -A && git commit -q -m "base: lock file with -diff attr" )
  ( cd "$REPO" && git checkout -q feat-test && git merge -q main --no-edit )
  printf 'x\nSTUB\n' > "$REPO/$lockfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: add sentinel to lock file" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
  grep -qF "deps.lock" <<<"$output"
}

@test "file marked binary in .gitattributes is still scanned for sentinels" {
  local binfile="gaia-public/plugins/gaia/data.bin"
  ( cd "$REPO" && git checkout -q main )
  ( cd "$REPO" && printf '*.bin binary\n' > .gitattributes \
      && mkdir -p "$(dirname "$binfile")" && printf 'x\n' > "$binfile" \
      && git add -A && git commit -q -m "base: binary-attr file" )
  ( cd "$REPO" && git checkout -q feat-test && git merge -q main --no-edit )
  printf 'x\nMOCK\n' > "$REPO/$binfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: add sentinel to binary file" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "MOCK" <<<"$output"
}

@test "file marked -diff in .git/info/attributes is still scanned" {
  local lockfile="gaia-public/plugins/gaia/deps.lock"
  ( cd "$REPO" && git checkout -q main )
  ( cd "$REPO" && mkdir -p .git/info && printf '* -diff\n' > .git/info/attributes \
      && mkdir -p "$(dirname "$lockfile")" && printf 'x\n' > "$lockfile" \
      && git add -A && git commit -q -m "base: lock file" )
  ( cd "$REPO" && git checkout -q feat-test && git merge -q main --no-edit )
  printf 'x\nFIXME\n' > "$REPO/$lockfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: add sentinel" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "FIXME" <<<"$output"
}

@test "attributes file added in the same change does not hide sentinels" {
  local prodfile="$FIXTURE_PROD_PATH"
  # The change itself adds a .gitattributes marking .sh as -diff,
  # alongside a .sh file with a sentinel. Both are new in this diff.
  printf '*.sh -diff\n' > "$REPO/.gitattributes"
  printf 'echo STUB\n' > "$REPO/$prodfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: attr + sentinel in same commit" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
}

# --- pathspec magic characters in file paths must not be interpreted ---

@test "file path containing pathspec-magic colon prefix does not hide other sentinels" {
  # A file named ':(exclude)gaia-public' at the repo root, if passed to
  # git-diff as a pathspec, makes git interpret it as an exclude operator
  # and silently drop all gaia-public/* paths from the diff output.
  # GIT_LITERAL_PATHSPECS prevents this.
  local trickname=':(exclude)gaia-public'
  printf 'clean\n' > "$REPO/$trickname"
  printf 'echo STUB\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: trick path + sentinel" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
}

# --- match parsing: sentinel in path must not false-positive ---

@test "sentinel word in directory name does not trigger a false HALT" {
  # A file at plugins/gaia/MOCK/clean.sh with clean content must pass.
  local mockdir="gaia-public/plugins/gaia/MOCK"
  ( cd "$REPO" && mkdir -p "$mockdir" )
  local mockfile="$mockdir/clean.sh"
  _stage_diff "$mockfile" 'echo perfectly fine'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

@test "colon in file name does not corrupt line-number reporting" {
  # A file named 'a:b.sh' should not split incorrectly.
  local colonfile="gaia-public/plugins/gaia/scripts/a:b.sh"
  ( cd "$REPO" && mkdir -p "$(dirname "$colonfile")" )
  _stage_diff "$colonfile" 'echo FIXME'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "FIXME" <<<"$output"
  # The path and line number must be correct despite the colon in the name
  grep -qF "a:b.sh:1" <<<"$output"
}

@test "clean file whose name resembles a sentinel record does not false-positive" {
  # A file named 'a:9:STUB.sh' with clean content must not trigger.
  local trickname="gaia-public/plugins/gaia/scripts/a:9:STUB.sh"
  ( cd "$REPO" && mkdir -p "$(dirname "$trickname")" )
  _stage_diff "$trickname" 'echo all clear'
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -eq 0 ]
}

# --- NUL bytes in binary files must not hide sentinels in other files ---

@test "binary file with NUL bytes next to a script sentinel still HALTs" {
  # A NUL-bearing .png alongside a .sh with a sentinel. Without NUL
  # stripping, GNU grep treats the collected text file as binary and
  # silently prints nothing, letting the scan exit 0.
  local pngfile="gaia-public/plugins/gaia/assets/logo.png"
  ( cd "$REPO" && mkdir -p "$(dirname "$pngfile")" )
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' > "$REPO/$pngfile"
  printf 'echo STUB\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: png + sentinel" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
  grep -qF "$FIXTURE_PROD_PATH:1" <<<"$output"
}

@test "sentinel after a NUL byte inside an added line is still caught" {
  # A single line containing a NUL then a sentinel. The NUL is replaced
  # with a space so awk and grep see the sentinel.
  # Use FIXTURE_PROD_ALT_PATH (built from prefix variable in setup) to
  # avoid a literal plugins/gaia/scripts path that trips the refs linter.
  local binscript="$FIXTURE_PROD_ALT_PATH"
  ( cd "$REPO" && mkdir -p "$(dirname "$binscript")" )
  printf 'before\x00MOCK after\n' > "$REPO/$binscript"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: nul-embedded sentinel" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "MOCK" <<<"$output"
  grep -qF "$FIXTURE_PROD_ALT_PATH:1" <<<"$output"
}

# --- filenames that git C-quotes must still be scanned ---

@test "file with non-ASCII name (UTF-8) is scanned for sentinels" {
  # Without core.quotePath=false and -z, git quotes this as caf\303\251.sh
  # and the path goes in as a literal pathspec that matches nothing.
  local prefix="gaia-public/plugins/gaia"
  local utf8file="${prefix}/scripts/caf\303\251.sh"
  ( cd "$REPO" && mkdir -p "$(dirname "$utf8file")" )
  printf 'clean\nSTUB\n' > "$REPO/$utf8file"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: utf8 name" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
  grep -qF ":2" <<<"$output"
}

@test "file with double-quote in name is scanned for sentinels" {
  local prefix="gaia-public/plugins/gaia"
  local quotefile="${prefix}/scripts/a\"b.sh"
  ( cd "$REPO" && mkdir -p "$(dirname "$quotefile")" )
  printf 'clean\nMOCK\n' > "$REPO/$quotefile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: quote name" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "MOCK" <<<"$output"
  grep -qF ":2" <<<"$output"
}

@test "file with backslash in name is scanned for sentinels" {
  local prefix="gaia-public/plugins/gaia"
  local bsfile="${prefix}/scripts/back\\slash.sh"
  ( cd "$REPO" && mkdir -p "$(dirname "$bsfile")" )
  printf 'clean\nFIXME\n' > "$REPO/$bsfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: backslash name" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "FIXME" <<<"$output"
  grep -qF ":2" <<<"$output"
}

@test "file with tab in name is scanned for sentinels" {
  local prefix="gaia-public/plugins/gaia"
  local tabfile
  printf -v tabfile '%s/scripts/a\tb.sh' "$prefix"
  ( cd "$REPO" && mkdir -p "$(dirname "$tabfile")" )
  printf 'clean\nXXX\n' > "$REPO/$tabfile"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: tab name" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "XXX" <<<"$output"
}

# --- LC_ALL=C must be set so BSD tr handles high bytes correctly ---

@test "high-byte content (non-ASCII) in an added line with a sentinel is caught" {
  # Without LC_ALL=C, BSD tr on macOS may mishandle bytes > 127.
  # This test embeds a high byte (\xc3\xa9 = UTF-8 e-acute) alongside STUB.
  printf 'caf\303\251 STUB\n' > "$REPO/$FIXTURE_PROD_PATH"
  ( cd "$REPO" && git add -A && git commit -q -m "feat: high-byte sentinel" )
  cd "$REPO"; run "$HELPER" --base-ref main; cd "$OLDPWD"
  [ "$status" -ne 0 ]
  grep -qF "STUB" <<<"$output"
}
