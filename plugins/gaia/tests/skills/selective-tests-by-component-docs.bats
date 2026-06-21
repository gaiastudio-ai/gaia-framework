#!/usr/bin/env bats
# Guard for the "Selective Tests by Component (Multi-Language)" documentation
# page. Pins its existence, the multi-language worked example, the dependency
# (cross_refs) section, and that it is linked into the tutorials nav.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  DOC="$REPO_ROOT/documentation/tutorials/selective-tests-by-component.html"
}

@test "component-tests doc: page exists (AC1)" {
  [ -f "$DOC" ]
}

@test "component-tests doc: carries the site chrome (styles.css + sidebar) (AC1)" {
  grep -q '../styles.css' "$DOC"
  grep -q 'class="sidebar"' "$DOC"
}

@test "component-tests doc: explains the stack-is-the-narrowing-unit concept (AC1)" {
  grep -qiE 'unit of narrowing' "$DOC"
}

@test "component-tests doc: documents the single-stack trap (AC1)" {
  grep -qiE 'single-stack trap|narrows to nothing' "$DOC"
}

@test "component-tests doc: multi-language example covers React, Angular, Python, Go, C++ (AC1)" {
  grep -qiE 'react' "$DOC"
  grep -qiE 'angular' "$DOC"
  grep -qiE 'python' "$DOC"
  grep -qiE '\bgo\b' "$DOC"
  grep -qiE 'c\+\+|cpp|ctest' "$DOC"
}

@test "component-tests doc: shows per-component test_cmd (AC1)" {
  grep -qE 'test_cmd' "$DOC"
}

@test "component-tests doc: documents cross_refs for inter-component dependencies (AC1)" {
  grep -qE 'cross_refs' "$DOC"
}

@test "component-tests doc: includes a setup checklist (AC1)" {
  grep -qiE 'setup checklist|gaia-config-validate' "$DOC"
}

@test "component-tests doc: is linked from the selective-test-execution tutorial nav (AC1)" {
  grep -q 'selective-tests-by-component.html' "$REPO_ROOT/documentation/tutorials/selective-test-execution.html"
}
