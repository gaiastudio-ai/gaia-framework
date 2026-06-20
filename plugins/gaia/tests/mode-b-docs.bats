#!/usr/bin/env bats

# Doc-guard tests for the Mode B (Agent Teams) user documentation page.
# The page is hand-authored HTML under the doc site at documentation/mode-b.html.

setup() {
  DOC_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../documentation" && pwd)"
  PAGE="$DOC_ROOT/mode-b.html"
}

@test "mode-b page exists in the documentation site (AC1)" {
  [ -f "$PAGE" ]
}

@test "mode-b page carries the standard site chrome (AC1)" {
  grep -q 'href="styles.css"' "$PAGE"
  grep -q 'class="sidebar"' "$PAGE"
}

@test "mode-b page has a Mode A vs Mode B comparison table (AC2)" {
  grep -q '<table>' "$PAGE"
  grep -q 'Mode A' "$PAGE"
  grep -q 'Mode B' "$PAGE"
  grep -qi 'one-shot' "$PAGE"
  grep -qi 'persistent' "$PAGE"
}

@test "mode-b page documents the dispatch model contrast (AC2)" {
  grep -qi 'subagent' "$PAGE"
  grep -qi 'teammate' "$PAGE"
}

@test "mode-b page has a How to Enable section (AC3)" {
  grep -qi 'How to Enable' "$PAGE"
  grep -qi 'opt-in' "$PAGE"
}

@test "mode-b page covers project-level and per-skill enablement (AC3)" {
  grep -qi 'project' "$PAGE"
  grep -qi 'per-skill' "$PAGE"
}

@test "mode-b page has a Windowed Teammates UX section (AC5)" {
  grep -qi 'Windowed Teammates' "$PAGE"
  grep -qi 'interjection' "$PAGE"
}

@test "mode-b page has a Known Limitations section (AC5)" {
  grep -qi 'Known Limitations' "$PAGE"
}

@test "mode-b page states the eight-teammate ceiling (AC5)" {
  grep -qi 'eight' "$PAGE"
}

@test "mode-b page states the clean-room reviewer exclusion (AC5)" {
  grep -qi 'clean-room' "$PAGE"
}

@test "mode-b page is honest about fallback to Mode A when the substrate is absent (substrate honesty)" {
  grep -qi 'fall back\|falls back\|fallback' "$PAGE"
  grep -qi 'substrate' "$PAGE"
}

@test "mode-b page is linked from the site index nav (AC1)" {
  grep -q 'mode-b.html' "$DOC_ROOT/index.html"
}

@test "mode-b page links itself into its own sidebar nav (AC1)" {
  grep -q 'mode-b.html' "$PAGE"
}
