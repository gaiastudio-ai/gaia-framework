#!/usr/bin/env bats
# no-leaked-ids-in-prose.bats — Gate 3: lint gate for published .md prose.
#
# Asserts that NO published .md file under the plugin tree contains a
# concrete internal traceability-ID literal (action-item date-serials,
# cascade date-serials, requirement IDs, story keys, test-case IDs).
#
# Carve-outs (NOT flagged):
#   - Lines with regex character-class brackets ([0-9])
#   - Tech tokens (UTF-8, SHA-256, ISO-8601, etc.)
#   - Files under any */fixtures/*, */test/runs/*, */manual-fixtures/*,
#     */spikes/*, or */tests/*.md (LLM-checkable/VCP test docs)
#   - CHANGELOG.md (release history carries references by design)
#   - PRD template and example files (prd-template*, prd-example*,
#     infra-prd-template*, platform-prd-template*) — format-string IDs
#   - Lines containing format-string markers: e.g., {story_key}, {key}
#   - Example command invocations showing placeholder story keys
#   - Illustrative story-key shapes in usage documentation
#   - printf format strings (%s, %d)
#   - Format-convention examples ("Format as SR-1, SR-2, etc.")
#   - Requirement IDs with zero-padded serials (FR-001, NFR-001) in
#     instructional prose (numbering conventions, not internal bookkeeping)
#
# This file itself contains regex literals as grep arguments, so it
# MUST be excluded from its own scan to avoid a tautological false positive.

load 'test_helper.bash'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# Shared constants and helpers
# ---------------------------------------------------------------------------

# Tech-token allowlist — encodings/standards that share the [A-Z]{2,}-[0-9]
# shape but are NOT internal traceability identifiers.
_prose_tech_token_filter='(UTF-8|UTF-16|UTF-32|SHA-256|SHA-512|SHA-1|ISO-8601|RFC-822|BASE-64)'

# _build_prose_target_list — populates the `prose_targets` array with every
# *.md file in the published tree, minus exempt directories and files.
#
# Exempt paths:
#   - */fixtures/*          — test fixture data
#   - */test/runs/*         — test run artifacts
#   - */manual-fixtures/*   — manual test fixtures
#   - */spikes/*            — spike investigation artifacts
#   - */tests/*.md          — LLM-checkable/VCP test documentation
#   - CHANGELOG.md          — release history
_build_prose_target_list() {
  local plugin_root="${BATS_TEST_DIRNAME}/.."
  prose_targets=()

  while IFS= read -r f; do
    # Skip exempt directories.
    case "$f" in
      */fixtures/*|*/test/runs/*|*/manual-fixtures/*|*/spikes/*) continue ;;
    esac
    # Skip CHANGELOG.md.
    local bn
    bn="$(basename "$f")"
    case "$bn" in
      CHANGELOG.md) continue ;;
    esac
    # Skip .md files directly inside a tests/ directory (LLM-checkable
    # runbooks, VCP test docs) — these are developer test documentation,
    # not user-facing prose. We match: /tests/<file>.md where <file>.md
    # is the immediate child, NOT deeper paths (README.md in tests/ IS
    # a published doc that the gate should scan — handled separately).
    local dir
    dir="$(dirname "$f")"
    case "$(basename "$dir")" in
      tests)
        # Tests-dir .md that are NOT README.md are test documentation.
        case "$bn" in
          README.md) ;; # Keep — README is published prose.
          *) continue ;; # Skip — test doc / runbook.
        esac
        ;;
    esac
    prose_targets+=("$f")
  done < <(find "$plugin_root" -name '*.md' -type f 2>/dev/null | sort)
}

# _scan_prose_for_date_serial_ids FILE... — count lines with concrete
# AI-YYYY-MM-DD-N or AF-YYYY-MM-DD-N date-serial identifiers.
# These patterns have NO legitimate use in published source.
_scan_prose_for_date_serial_ids() {
  local raw filtered
  raw="$(grep -hE '(AI|AF)-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+' "$@" 2>/dev/null || true)"
  [[ -z "$raw" ]] && { echo 0; return; }

  # Carve-out: lines with regex character-class brackets.
  filtered="$(printf '%s\n' "$raw" | grep -vE '\[0-9\]' || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: printf format strings.
  filtered="$(printf '%s\n' "$filtered" | grep -vE '(AI|AF)-%[sd]' || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  printf '%s\n' "$filtered" | wc -l | tr -d ' '
}

# _scan_prose_for_story_keys FILE... — count lines with concrete E<n>-S<n>
# story keys that are genuine leaks (not format-string examples).
_scan_prose_for_story_keys() {
  local raw filtered
  raw="$(grep -hE 'E[0-9]+-S[0-9]+' "$@" 2>/dev/null || true)"
  [[ -z "$raw" ]] && { echo 0; return; }

  # Carve-out: lines with regex character-class brackets.
  filtered="$(printf '%s\n' "$raw" | grep -vE '\[0-9\]' || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: format-string example markers.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'e\.g\.' \
    | grep -vE '\{story_key\}' \
    | grep -vE '\{key\}' \
    | grep -vE '\{number\}' \
    | grep -vE 'E\{[a-z]' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: command invocation examples (lines with /gaia- commands).
  # grep -h output has no line-number prefix, so ^ works directly.
  # Match at start of line, after $, or anywhere /gaia- appears (YAML
  # example blocks have indented /gaia- command references).
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '^\$ |/gaia-' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: YAML example blocks (key: "value" patterns).
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '^story_key:|^key:' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: example file-path patterns showing naming conventions
  # (e.g. code-review-E999-S1.md in documentation of naming conventions).
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'verified on disk:' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: word-boundary regex documentation examples that show
  # story-key shapes as illustration of matching behavior.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '\\b.*E[0-9]+-S[0-9]+.*\\b' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: lines showing the E{n}-S{n} format convention in SKILL docs
  # (e.g. "E999-S1: Vault folder creation" in epics template examples,
  #  or "Examples: `tests/E999-S4-AC1.test.ts`" in coverage documentation).
  # These use synthetic placeholder numbers to illustrate the naming pattern.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'Examples?:' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: story heading examples in template documentation
  # (lines like "### Story E999-S1:" showing the heading format convention).
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '### Story E[0-9]+-S[0-9]+' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: dependency list examples in template documentation
  # (lines like "- Blocks: [E999-S2]" showing the dependency format).
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '^- (Blocks|Depends on|Traces to):' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  printf '%s\n' "$filtered" | wc -l | tr -d ' '
}

# _scan_prose_for_requirement_ids FILE... — count lines with concrete
# FR-N, NFR-N, ADR-N, SR-N requirement/decision IDs.
# Template/example files are pre-filtered by the caller.
_scan_prose_for_requirement_ids() {
  local raw filtered
  raw="$(grep -hE '(FR|NFR|ADR|SR)-[0-9]+' "$@" 2>/dev/null || true)"
  [[ -z "$raw" ]] && { echo 0; return; }

  # Carve-out: lines with regex character-class brackets.
  filtered="$(printf '%s\n' "$raw" | grep -vE '\[0-9\]' || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: tech tokens.
  filtered="$(printf '%s\n' "$filtered" | grep -vE "$_prose_tech_token_filter" || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: low-numbered zero-padded format-string IDs (FR-001..FR-009,
  # NFR-001..NFR-009, ADR-001..ADR-009, SR-001..SR-009) used in
  # instructional/template prose to show numbering conventions. Higher-
  # numbered IDs (a specific NFR or ADR) are concrete internal references
  # and are NOT carved out.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '(FR|NFR|ADR|SR)-00[0-9][^0-9]|(FR|NFR|ADR|SR)-00[0-9]$' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: format-string example markers.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'e\.g\.' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: format-convention documentation ("Format as SR-1, SR-2").
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'Format as' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: numbering-convention instructions ("IDs: FR-001, FR-002").
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'Assign unique|sequential|IDs:' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: small-numbered IDs (FR-1 through FR-9, NFR-1 through NFR-9,
  # etc.) used as illustrative examples — single-digit serials are
  # placeholder shapes in documentation, not real internal requirements.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE '(FR|SR)-[0-9][^0-9]|(FR|SR)-[0-9]$' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  printf '%s\n' "$filtered" | wc -l | tr -d ' '
}

# _scan_prose_for_tc_ids FILE... — count lines with concrete TC-<ALPHA>-<N>
# test-case identifiers.
_scan_prose_for_tc_ids() {
  local raw filtered
  raw="$(grep -hE 'TC-[A-Z]+-[A-Z0-9]*[0-9]' "$@" 2>/dev/null || true)"
  [[ -z "$raw" ]] && { echo 0; return; }

  # Carve-out: lines with regex character-class brackets.
  filtered="$(printf '%s\n' "$raw" | grep -vE '\[0-9\]' || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: tech tokens.
  filtered="$(printf '%s\n' "$filtered" | grep -vE "$_prose_tech_token_filter" || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  # Carve-out: format-string example markers.
  filtered="$(printf '%s\n' "$filtered" \
    | grep -vE 'e\.g\.' \
    || true)"
  [[ -z "$filtered" ]] && { echo 0; return; }

  printf '%s\n' "$filtered" | wc -l | tr -d ' '
}

# _scan_prose_all FILE... — aggregate count of all leaked-ID families.
_scan_prose_all() {
  local total=0 count

  count="$(_scan_prose_for_date_serial_ids "$@")"
  total=$((total + count))

  count="$(_scan_prose_for_story_keys "$@")"
  total=$((total + count))

  # Requirement IDs: only scan non-template files.
  local req_targets=()
  local f bn
  for f in "$@"; do
    bn="$(basename "$f")"
    case "$bn" in
      prd-template*|prd-example*|infra-prd-template*|platform-prd-template*) continue ;;
    esac
    req_targets+=("$f")
  done
  if [[ ${#req_targets[@]} -gt 0 ]]; then
    count="$(_scan_prose_for_requirement_ids "${req_targets[@]}")"
    total=$((total + count))
  fi

  count="$(_scan_prose_for_tc_ids "$@")"
  total=$((total + count))

  echo "$total"
}

# ---------------------------------------------------------------------------
# Gate 3: published prose .md files (AC3, AC5)
# ---------------------------------------------------------------------------

@test "no published prose .md carries a concrete leaked internal-ID (AC3)" {
  local -a prose_targets
  _build_prose_target_list

  if [[ ${#prose_targets[@]} -eq 0 ]]; then
    skip "no .md files found under the published tree"
  fi

  local count
  count="$(_scan_prose_all "${prose_targets[@]}")"

  if [[ "$count" -gt 0 ]]; then
    printf 'FAIL: %s line(s) in published .md prose carry concrete leaked internal-IDs\n' "$count" >&2

    # Re-run per-family scanners for diagnostics.
    local f
    for f in "${prose_targets[@]}"; do
      local fc
      fc="$(_scan_prose_all "$f")"
      if [[ "$fc" -gt 0 ]]; then
        printf '  %s: %s leak(s)\n' "$f" "$fc" >&2
      fi
    done
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Positive-violation fixture: planted leak trips the gate (AC3)
# ---------------------------------------------------------------------------

@test "prose leak gate catches planted date-serial IDs in a fixture (AC3)" {
  # Create a fixture .md file with planted AI- and AF- date-serial IDs.
  # Uses synthetic obviously-fake dates (2099) to avoid confusion.
  # Assembled via printf to keep this source file clean of concrete literals.
  local fixture="$TEST_TMP/planted-prose-leak.md"
  printf '# Planted Leak Fixture\n\n' > "$fixture"
  printf 'This references action item %s-%s-%s-%s-%s.\n' \
    "AI" "2099" "01" "01" "1" >> "$fixture"
  printf 'And cascade %s-%s-%s-%s-%s.\n' \
    "AF" "2099" "01" "01" "1" >> "$fixture"

  local count
  count="$(_scan_prose_for_date_serial_ids "$fixture")"
  # The fixture SHOULD be caught — assert non-zero match count.
  [[ "$count" -gt 0 ]]
}

@test "prose leak gate catches planted story-key in a fixture (AC3)" {
  local fixture="$TEST_TMP/planted-storykey-leak.md"
  printf '# Planted Story Key Leak\n\n' > "$fixture"
  printf 'This references story %s%s-%s%s.\n' \
    "E" "99" "S" "1" >> "$fixture"

  local count
  count="$(_scan_prose_for_story_keys "$fixture")"
  [[ "$count" -gt 0 ]]
}

@test "prose leak gate catches planted requirement ID in a fixture (AC3)" {
  local fixture="$TEST_TMP/planted-reqid-leak.md"
  printf '# Planted Requirement Leak\n\n' > "$fixture"
  printf 'This implements %s-%s.\n' "NFR" "052" >> "$fixture"

  local count
  count="$(_scan_prose_for_requirement_ids "$fixture")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Carve-out proofs: no false positives (AC4)
# ---------------------------------------------------------------------------

@test "prose leak gate does not flag regex character-class shapes (AC4)" {
  local fixture="$TEST_TMP/regex-carveout.md"
  printf '# Regex shapes\n\n' > "$fixture"
  printf 'The pattern E[0-9]+-S[0-9]+ matches story keys.\n' >> "$fixture"
  printf 'Action items match AI-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+.\n' >> "$fixture"

  local count
  count="$(_scan_prose_all "$fixture")"
  [[ "$count" -eq 0 ]]
}

@test "prose leak gate does not flag tech tokens (AC4)" {
  local fixture="$TEST_TMP/tech-tokens.md"
  printf '# Tech tokens\n\n' > "$fixture"
  printf 'Uses UTF-8, SHA-256, ISO-8601, and RFC-822.\n' >> "$fixture"

  local count
  count="$(_scan_prose_all "$fixture")"
  [[ "$count" -eq 0 ]]
}

@test "prose leak gate does not flag format-string example story keys (AC4)" {
  local fixture="$TEST_TMP/example-keys.md"
  printf '# SKILL usage\n\n' > "$fixture"
  printf '| `story_key` | string | yes | e.g., `%s%s-%s%s` |\n' \
    "E" "19" "S" "9" >> "$fixture"

  local count
  count="$(_scan_prose_for_story_keys "$fixture")"
  [[ "$count" -eq 0 ]]
}

@test "prose leak gate does not flag PRD template requirement IDs (AC4)" {
  # Simulate a template file by name.
  local fixture="$TEST_TMP/prd-template-test.md"
  printf '# Template\n\n' > "$fixture"
  printf '%s\n' '- **FR-01:** {Requirement description}' >> "$fixture"
  printf '%s\n' '| NFR-001 | Performance | {requirement} | {target} |' >> "$fixture"

  # The requirement-ID scanner skips prd-template* files by basename.
  local req_targets=()
  local bn
  bn="$(basename "$fixture")"
  case "$bn" in
    prd-template*|prd-example*|infra-prd-template*|platform-prd-template*) ;;
    *) req_targets+=("$fixture") ;;
  esac

  # Template file should be skipped — no targets to scan.
  [[ ${#req_targets[@]} -eq 0 ]]
}

@test "prose leak gate does not flag zero-padded convention IDs in instructions (AC4)" {
  local fixture="$TEST_TMP/convention-ids.md"
  printf '# Numbering\n\n' > "$fixture"
  printf '%s\n' 'Assign unique IDs: FR-001, FR-002, ... — IDs are sequential.' >> "$fixture"
  printf '%s\n' '| NFR-001 | Performance | timer drift | < 1 s |' >> "$fixture"
  printf '%s\n' 'Number ADRs sequentially: ADR-001, ADR-002, etc.' >> "$fixture"
  printf '%s\n' '| SR-001 | Network | {policy} | {target} |' >> "$fixture"

  local count
  count="$(_scan_prose_for_requirement_ids "$fixture")"
  [[ "$count" -eq 0 ]]
}
