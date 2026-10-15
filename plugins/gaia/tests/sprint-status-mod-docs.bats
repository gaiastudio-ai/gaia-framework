#!/usr/bin/env bats
# sprint-status-mod-docs.bats — guards for the sprint status mod
# documentation pages: leaked-identifier scan and internal link check.
#
# No project-root .gaia/ access; all paths are relative to the repo root.
# No internal identifiers in @test names.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  common_setup
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOC_DIR="$REPO_ROOT/documentation"
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# Leaked-identifier regex — same families as the repo-wide gates.
# ---------------------------------------------------------------------------
_leak_regex() {
  printf '%s' 'FR-[0-9]+|NFR-[0-9]+|ADR-[0-9]+|E[0-9]+-S[0-9]+|TC-[A-Z][A-Z0-9]*-|SR-[0-9]+|(AF|AI)-[0-9]{4}|T-DPS-[0-9]+|GitHub #[0-9]+|(^|[^A-Za-z0-9])(T|F)-[0-9]+([^0-9]|$)'
}

# Named allow-list: synthetic keys that appear deliberately on these pages.
# Each entry is a fixed string. sprint-12 is not matched by the leak regex.
_ALLOWED_KEYS=(
  "E1-S1"     # index.html example
  "FR-001"    # glossary.html example
  "E5-S14"    # gaia-sprint-status.html example
  "E3-S9"     # gaia-sprint-status.html example
  "E3-S10"    # gaia-sprint-status.html example
  "E4-S6"     # gaia-sprint-status.html example
  "E4-S7"     # gaia-sprint-status.html example
  "E5-S12"    # sprint-status-mod.html example
  "E3-S7"     # sprint-status-mod.html example
  "E5-S18"    # sprint-status-mod.html example
)

# _filter_allowed FILE — grep for leaks, then strip allow-listed keys.
_filter_allowed() {
  local file="$1"
  local raw
  raw="$(grep -nE "$(_leak_regex)" "$file" 2>/dev/null || true)"
  [ -n "$raw" ] || return 0
  local filtered="$raw"
  local key
  for key in "${_ALLOWED_KEYS[@]}"; do
    filtered="$(printf '%s\n' "$filtered" | grep -vF "$key" || true)"
  done
  # Also allow E[0-9]+-S[0-9]+ patterns inside regex literals (test code)
  filtered="$(printf '%s\n' "$filtered" | grep -v 'E\[0-9\]' || true)"
  printf '%s' "$filtered"
}

# ---------------------------------------------------------------------------
# Leak scan — new pages
# ---------------------------------------------------------------------------

@test "no leaked identifier in sprint-status-mod.html" {
  [ -f "$DOC_DIR/sprint-status-mod.html" ] || fail "sprint-status-mod.html not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/sprint-status-mod.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in sprint-status-mod.html:" >&2
    echo "$hits" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Leak scan — edited pages (scoped to changed regions)
# ---------------------------------------------------------------------------

@test "no leaked identifier in gaia-sprint-status.html" {
  [ -f "$DOC_DIR/commands/gaia-sprint-status.html" ] || fail "page not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/commands/gaia-sprint-status.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in gaia-sprint-status.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no leaked identifier in gaia-statusline.html" {
  [ -f "$DOC_DIR/commands/gaia-statusline.html" ] || fail "page not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/commands/gaia-statusline.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in gaia-statusline.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no leaked identifier in sprint-management category page" {
  [ -f "$DOC_DIR/categories/sprint-management.html" ] || fail "page not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/categories/sprint-management.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in sprint-management.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no leaked identifier in configuration category page" {
  [ -f "$DOC_DIR/categories/configuration.html" ] || fail "page not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/categories/configuration.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in configuration.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no leaked identifier in index.html" {
  [ -f "$DOC_DIR/index.html" ] || fail "page not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/index.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in index.html:" >&2
    echo "$hits" >&2; return 1
  }
}

@test "no leaked identifier in glossary.html" {
  [ -f "$DOC_DIR/glossary.html" ] || fail "page not found"
  local hits
  hits="$(_filter_allowed "$DOC_DIR/glossary.html")"
  [ -z "$hits" ] || {
    echo "FAIL: leaked identifier(s) in glossary.html:" >&2
    echo "$hits" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Internal link check — verify href targets exist on disk
# ---------------------------------------------------------------------------

# _check_links PAGE — extract href values from a page and verify each
# target file exists relative to the page's directory.
_check_links() {
  local page="$1"
  local page_dir
  page_dir="$(dirname "$page")"
  local missing=""
  local href
  # Extract href="..." values, skip external links, anchors, and mailto
  while IFS= read -r href; do
    # Strip anchor fragments
    href="${href%%#*}"
    [ -n "$href" ] || continue
    # Skip external URLs
    case "$href" in
      http://*|https://*|mailto:*) continue ;;
    esac
    local target="$page_dir/$href"
    [ -f "$target" ] || missing="${missing}  missing: ${href} (from $(basename "$page"))"$'\n'
  done < <(grep -oE 'href="[^"]*"' "$page" | sed 's/^href="//;s/"$//')
  printf '%s' "$missing"
}

@test "all internal links resolve in sprint-status-mod.html" {
  [ -f "$DOC_DIR/sprint-status-mod.html" ] || fail "page not found"
  local missing
  missing="$(_check_links "$DOC_DIR/sprint-status-mod.html")"
  [ -z "$missing" ] || {
    echo "FAIL: broken internal links:" >&2
    echo "$missing" >&2; return 1
  }
}

@test "all internal links resolve in gaia-sprint-status.html" {
  [ -f "$DOC_DIR/commands/gaia-sprint-status.html" ] || fail "page not found"
  local missing
  missing="$(_check_links "$DOC_DIR/commands/gaia-sprint-status.html")"
  [ -z "$missing" ] || {
    echo "FAIL: broken internal links:" >&2
    echo "$missing" >&2; return 1
  }
}

@test "all internal links resolve in gaia-statusline.html" {
  [ -f "$DOC_DIR/commands/gaia-statusline.html" ] || fail "page not found"
  local missing
  missing="$(_check_links "$DOC_DIR/commands/gaia-statusline.html")"
  [ -z "$missing" ] || {
    echo "FAIL: broken internal links:" >&2
    echo "$missing" >&2; return 1
  }
}

# ---------------------------------------------------------------------------
# Content presence checks
# ---------------------------------------------------------------------------

@test "sprint-status-mod.html exists at doc root" {
  [ -f "$DOC_DIR/sprint-status-mod.html" ]
}

@test "index.html nav sidebar links sprint-status-mod.html" {
  grep -q 'sprint-status-mod.html' "$DOC_DIR/index.html"
}

@test "glossary.html has band entry" {
  grep -q 'id="band"' "$DOC_DIR/glossary.html"
}

@test "glossary.html has sidebar entry" {
  grep -q 'id="sidebar"' "$DOC_DIR/glossary.html"
}

@test "sprint management category links sprint-status-mod.html" {
  grep -q 'sprint-status-mod.html' "$DOC_DIR/categories/sprint-management.html"
}

@test "configuration category links sprint_status_mod config section" {
  grep -q 'sprint-status-mod.html#configuration' "$DOC_DIR/categories/configuration.html"
}

@test "gaia-statusline.html has sprint progress segment section" {
  grep -q 'id="sprint-segment"' "$DOC_DIR/commands/gaia-statusline.html"
}

@test "gaia-sprint-status.html has graceful degradation section" {
  grep -q 'id="degradation"' "$DOC_DIR/commands/gaia-sprint-status.html"
}
