# Bats Testing Patterns

<!-- SECTION: test-structure -->
## Test Structure

Bats (Bash Automated Testing System) uses `@test` blocks. Each block is
independent — a failure in one does not affect the others.

```bash
#!/usr/bin/env bats
# tests/unit/my-script.bats

# PLUGIN_ROOT resolved relative to this file's location — never hardcoded.
PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

@test "script exits 0 on valid input" {
  run "$PLUGIN_ROOT/scripts/my-script.sh" --input "hello"
  [ "$status" -eq 0 ]
}

@test "script emits expected output" {
  run "$PLUGIN_ROOT/scripts/my-script.sh" --input "hello"
  [ "$output" = "processed: hello" ]
}

@test "script exits non-zero on missing required flag" {
  run "$PLUGIN_ROOT/scripts/my-script.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--input"* ]] || [[ "$stderr" == *"--input"* ]]
}
```

<!-- SECTION: setup-teardown -->
## setup and teardown

`setup` runs before each `@test`; `teardown` runs after each (even on failure).
Use `setup_file` / `teardown_file` for once-per-file work (Bats >= 1.5).

```bash
setup() {
  TMP_DIR="$(mktemp -d)"
  export TMP_DIR
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "writes output file to expected path" {
  run bash "$PLUGIN_ROOT/scripts/generate.sh" --out "$TMP_DIR/result.json"
  [ "$status" -eq 0 ]
  [ -f "$TMP_DIR/result.json" ]
}
```

<!-- SECTION: run-assert -->
## run and Assertions

`run` captures exit status in `$status` and combined stdout+stderr in `$output`.
Use `$lines` for line-by-line access:

```bash
@test "first line of output is a header" {
  run bash "$PLUGIN_ROOT/scripts/report.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "# Report" ]
}

@test "output contains required field" {
  run bash "$PLUGIN_ROOT/scripts/emit-json.sh"
  echo "$output" | grep -q '"verdict"'
}
```

To separate stdout from stderr, use `run --separate-stderr` (Bats >= 1.5):

```bash
@test "warnings go to stderr, result to stdout" {
  run --separate-stderr bash "$PLUGIN_ROOT/scripts/check.sh" --warn-mode
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING"* ]]
  [[ "$output" == *"PASS"* ]]
}
```

<!-- SECTION: fixtures -->
## Fixtures

Place test fixtures under `tests/fixtures/`. Never write fixtures at col 0 with
a literal `@test` string inside a heredoc — the TAP plan counter counts `@test`
occurrences and will report an inflated test count.

```bash
# Safe: write fixture content with printf after the heredoc
setup() {
  TMP_DIR="$(mktemp -d)"
  FIXTURE="$TMP_DIR/sample.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho hello\n' > "$FIXTURE"
  chmod +x "$FIXTURE"
}
```

<!-- SECTION: tool-absent-testing -->
## Testing Tool-Absent Paths

Avoid `command -v tool || skip` — the tool may exist in CI where it is absent
locally, causing the skip to hide CI failures. Test tool-absent paths with an
empty-dir PATH override instead:

```bash
@test "script errors clearly when jq is absent" {
  local empty_bin
  empty_bin="$(mktemp -d)"
  PATH="$empty_bin" run bash "$PLUGIN_ROOT/scripts/my-script.sh" --project-root .
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]] || [[ "$stderr" == *"jq"* ]]
  rm -rf "$empty_bin"
}
```
