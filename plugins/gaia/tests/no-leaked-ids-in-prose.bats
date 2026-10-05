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

# ---------------------------------------------------------------------------
# Alpha-FR / "FR ID" / EC-<n> scanners (no line-level carve-outs)
# ---------------------------------------------------------------------------

# _strip_fr_exempt FILE — strips only bounded exempt literals for the given
# file path, outputting the scrubbed content to stdout. Non-exempt files are
# passed through unchanged (cat). Each exemption removes only the exempt
# token (followed by a non-letter boundary), never the whole line.
#
# Named exemptions:
#   (i)   FR-xxx placeholder in gaia-trace/SKILL.md
#   (ii)  FR-N range-end in gaia-trace/SKILL.md
#   (iii) FR-NNN / NFR-NNN in gaia-test-gap-analysis and gaia-edit-test-plan
#   (iv)  fr=<FR-MTG-ID> telemetry template in gaia-meeting/SKILL.md
#   (v)   "FR-to-Screen Mapping" heading in gaia-create-ux and gaia-edit-ux
#   (vi)  "Columns: FR ID |" column header in gaia-trace/SKILL.md
_strip_fr_exempt() {
  local f="$1"
  case "$f" in
    */skills/gaia-trace/SKILL.md)
      # (i) FR-xxx bounded, (ii) FR-N bounded, (vi) "Columns: FR ID |"
      sed -E \
        -e 's/FR-xxx([^A-Za-z]|$)/\1/g' \
        -e 's/FR-N([^A-Za-z]|$)/\1/g' \
        -e 's/Columns: FR ID \|/Columns: |/g' \
        "$f" ;;
    */skills/gaia-test-gap-analysis/SKILL.md|*/skills/gaia-edit-test-plan/SKILL.md)
      # (iii) FR-NNN bounded (NFR-NNN never matched by [^A-Za-z] anchor)
      sed -E -e 's/FR-NNN([^A-Za-z]|$)/\1/g' "$f" ;;
    */skills/gaia-meeting/SKILL.md)
      # (iv) fr=<FR-MTG-ID> telemetry template
      sed -E -e 's/fr=<FR-MTG-ID>/fr=/g' "$f" ;;
    */skills/gaia-create-ux/SKILL.md|*/skills/gaia-edit-ux/SKILL.md)
      # (v) "FR-to-Screen Mapping" heading — strip "FR-to" when part of this
      sed -E -e 's/FR-to-Screen Mapping/Screen Mapping/g' "$f" ;;
    *)
      cat "$f" ;;
  esac
}

# _scan_prose_for_fr_alpha_ids FILE... — count lines with alpha/ellipsis
# FR- tokens: (^|[^A-Za-z])FR-([A-Za-z_]|\.\.\.)
# Numeric forms (FR-001) belong to _scan_prose_for_requirement_ids.
# NFR- is excluded by the [^A-Za-z] left-boundary anchor.
_scan_prose_for_fr_alpha_ids() {
  local f n total=0
  for f in "$@"; do
    n="$(_strip_fr_exempt "$f" | grep -cE '(^|[^A-Za-z])FR-([A-Za-z_]|\.\.\.)' || true)"
    total=$((total + ${n:-0}))
  done
  echo "$total"
}

# _scan_prose_for_fr_id_phrase FILE... — count lines with standalone
# "FR ID" or "FR IDs": (^|[^A-Za-z/])FR IDs?
# The / anchor excludes "FR/NFR IDs"; the letter anchor excludes "NFR ID".
_scan_prose_for_fr_id_phrase() {
  local f n total=0
  for f in "$@"; do
    n="$(_strip_fr_exempt "$f" | grep -cE '(^|[^A-Za-z/])FR IDs?' || true)"
    total=$((total + ${n:-0}))
  done
  echo "$total"
}

# _scan_prose_for_ec_ids FILE... — count lines with EC-<n> tokens:
# (^|[^A-Za-z-])EC-[0-9]+
# Folder exemptions: skills/edge-cases/ and skills/gaia-create-story/.
_scan_prose_for_ec_ids() {
  local f n total=0
  for f in "$@"; do
    case "$f" in
      */skills/edge-cases/*|*/skills/gaia-create-story/*) continue ;;
    esac
    n="$(grep -cE '(^|[^A-Za-z-])EC-[0-9]+' "$f" || true)"
    total=$((total + ${n:-0}))
  done
  echo "$total"
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

  count="$(_scan_prose_for_fr_alpha_ids "$@")"
  total=$((total + count))

  count="$(_scan_prose_for_fr_id_phrase "$@")"
  total=$((total + count))

  count="$(_scan_prose_for_ec_ids "$@")"
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

# ---------------------------------------------------------------------------
# Fixture builder helper: creates a fixture at $TEST_TMP/<relpath> with the
# given lines, returns the absolute path.
# ---------------------------------------------------------------------------
_fx() {
  local rel="$1"; shift
  local p="$TEST_TMP/$rel"
  mkdir -p "$(dirname "$p")"
  : > "$p"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$p"; done
  printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# Planted-token tests — scanner catches planted tokens
# Assembled via printf fragments so no concrete IDs appear in test names.
# ---------------------------------------------------------------------------

# Obfuscated tokens for printf assembly (the test-names guard flags
# [A-Z]{2,}-[0-9] in test names, so we build tokens at runtime).
# shellcheck disable=SC2034
_R="$(printf '%s%s' F R)"
_E="$(printf '%s%s' E C)"

@test "planted alpha requirement-identifier caught by guard" {
  local f
  f="$(_fx a.md "x ${_R}-traceability y")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted bracket-notation token caught by guard" {
  local f
  f="$(_fx a.md "traces_to: [${_R}-...]")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted standalone phrase caught by guard" {
  local f
  f="$(_fx a.md "uses ${_R} ID here")"
  local count
  count="$(_scan_prose_for_fr_id_phrase "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted paren edge-case citation caught by guard" {
  local f
  f="$(_fx a.md "x (${_E}-10).")"
  local count
  count="$(_scan_prose_for_ec_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted bare edge-case token caught by guard" {
  local f
  f="$(_fx a.md "per ${_E}-10 rule")"
  local count
  count="$(_scan_prose_for_ec_ids "$f")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Exclusion proofs — legitimate forms pass the guard
# ---------------------------------------------------------------------------

@test "guard passes prefixed non-requirement form" {
  local f
  f="$(_fx a.md "(N${_R}-xxx)")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -eq 0 ]]
}

@test "guard passes non-requirement phrases" {
  local f
  f="$(_fx a.md "an N${_R} ID" "the ${_R}/N${_R} IDs")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -eq 0 ]]
}

@test "guard passes numeric convention forms" {
  local f
  f="$(_fx a.md "Assign unique IDs: ${_R}-001, ${_R}-002, ...")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Bounded exemption-proof scenarios — same-line leak beside exempt token
# ---------------------------------------------------------------------------

@test "exempt placeholder in trace with boundary plant caught" {
  local f g
  # Leak on SAME line as exempt token
  f="$(_fx skills/gaia-trace/SKILL.md "(${_R}-xxx, N${_R}-xxx) ${_R}-xxxa" "(${_R}-xxx) ${_R}-Name")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  # Two lines; bounded placeholder stripped, leaked alpha tokens remain
  [ "$count" -eq 2 ]
  # Without leaks: only exempt tokens
  g="$(_fx skills/gaia-trace/SKILL.md "(${_R}-xxx, N${_R}-xxx)")"
  count="$(_scan_prose_for_fr_alpha_ids "$g")"
  [ "$count" -eq 0 ]
}

@test "exempt range-end in trace with boundary plant caught" {
  local f g
  # Leak on SAME line as exempt range-end token
  f="$(_fx skills/gaia-trace/SKILL.md "Rows: ${_R}-001 through ${_R}-N ${_R}-NNNa" "${_R}-N ${_R}-Navigation")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  # Two lines; bounded range-end stripped, leaked alpha tokens remain
  [ "$count" -eq 2 ]
  # Without leaks
  g="$(_fx skills/gaia-trace/SKILL.md "Rows: ${_R}-001 through ${_R}-N (from")"
  count="$(_scan_prose_for_fr_alpha_ids "$g")"
  [ "$count" -eq 0 ]
}

@test "exempt gap-analysis placeholder with boundary and leak caught" {
  local f g
  # Leak on SAME line as exempt placeholder
  f="$(_fx skills/gaia-test-gap-analysis/SKILL.md "for ${_R}-NNN/N${_R}-NNN ${_R}-NNNa" "${_R}-NNN ${_R}-traceability")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  # Two lines; bounded placeholder stripped, leaked alpha tokens remain
  [ "$count" -eq 2 ]
  # Without leaks
  g="$(_fx skills/gaia-test-gap-analysis/SKILL.md "for ${_R}-NNN/N${_R}-NNN id")"
  count="$(_scan_prose_for_fr_alpha_ids "$g")"
  [ "$count" -eq 0 ]
}

@test "exempt meeting telemetry with leak caught" {
  local f g
  f="$(_fx skills/gaia-meeting/SKILL.md "HALT fr=<${_R}-MTG-ID> ${_R}-traceability")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [ "$count" -eq 1 ]
  g="$(_fx skills/gaia-meeting/SKILL.md "HALT fr=<${_R}-MTG-ID> detail")"
  count="$(_scan_prose_for_fr_alpha_ids "$g")"
  [ "$count" -eq 0 ]
}

@test "meeting-telemetry exemption does not strip a leak on another line" {
  # The exemption must be token-level, not file-wide: a real leak on a
  # different line of the same meeting-skill fixture must still be caught.
  local f
  f="$(_fx skills/gaia-meeting/SKILL.md "HALT fr=<${_R}-MTG-ID> detail" "${_R}-traceability on separate line")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [ "$count" -eq 1 ]
}

@test "exempt ux heading with leak caught" {
  local f g
  f="$(_fx skills/gaia-create-ux/SKILL.md "${_R}-to-Screen Mapping ${_R}-traceability")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [ "$count" -eq 1 ]
  g="$(_fx skills/gaia-create-ux/SKILL.md "${_R}-to-Screen Mapping table")"
  count="$(_scan_prose_for_fr_alpha_ids "$g")"
  [ "$count" -eq 0 ]
}

@test "exempt column header with singular phrase leak caught" {
  local f g
  f="$(_fx skills/gaia-trace/SKILL.md "Columns: ${_R} ID | for ${_R} ID references")"
  local count
  count="$(_scan_prose_for_fr_id_phrase "$f")"
  # Standalone "for <requirement> ID references" = 1 hit; column header stripped
  [ "$count" -eq 1 ]
  g="$(_fx skills/gaia-trace/SKILL.md "Columns: ${_R} ID | Description")"
  count="$(_scan_prose_for_fr_id_phrase "$g")"
  [ "$count" -eq 0 ]
}

@test "exempt edge-case folder but requirement form fires" {
  local f
  f="$(_fx skills/edge-cases/SKILL.md "id: \"${_E}-1\" ${_R}-traceability")"
  # Edge-case ID exempt (folder skip); alpha requirement token caught
  local count
  count="$(_scan_prose_for_ec_ids "$f")"
  [ "$count" -eq 0 ]
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Combined gate — unhooking any scanner from the aggregate must be caught
# ---------------------------------------------------------------------------

@test "aggregate gate catches planted alpha requirement token" {
  local f
  f="$(_fx a.md "x ${_R}-traceability y")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -gt 0 ]]
}

@test "aggregate gate catches planted standalone phrase" {
  local f
  f="$(_fx a.md "uses ${_R} ID here")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -gt 0 ]]
}

@test "aggregate gate catches planted edge-case citation" {
  local f
  f="$(_fx a.md "x (${_E}-10).")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Old carve-out reuse — plants on lines with old exemption markers must fire
# ---------------------------------------------------------------------------

@test "alpha requirement token on line with old carve-out marker is caught" {
  local f
  # Lines carrying old exemption markers: e.g., Examples:, /gaia-
  f="$(_fx a.md "e.g. ${_R}-traceability here" "Examples: ${_R}-xxx leaks" "/gaia-foo ${_R}-Name" "[0-9] ${_R}-Navigation" "sequential ${_R}-xxx list" "IDs: ${_R}-xxx tag")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -eq 6 ]]
}

@test "standalone phrase on line with old carve-out marker is caught" {
  local f
  f="$(_fx a.md "e.g. ${_R} ID here" "Examples: ${_R} IDs doc" "/gaia-foo ${_R} ID" "[0-9] ${_R} IDs")"
  local count
  count="$(_scan_prose_for_fr_id_phrase "$f")"
  [[ "$count" -eq 4 ]]
}

@test "edge-case token on line with old carve-out marker is caught" {
  local f
  f="$(_fx a.md "e.g. ${_E}-1 here" "Examples: ${_E}-10 doc" "/gaia-foo ${_E}-99" "[0-9] ${_E}-5")"
  local count
  count="$(_scan_prose_for_ec_ids "$f")"
  [[ "$count" -eq 4 ]]
}

# ---------------------------------------------------------------------------
# Anchor and folder-skip edge cases
# ---------------------------------------------------------------------------

@test "guard passes hyphenated-prefix and slash-prefix negatives" {
  local f
  # Tokens that must NOT fire: prefixed forms, slash-delimited combined forms
  f="$(_fx a.md "AC-${_E}-1 test" "SPEC-1 doc" "N${_R}/N${_R} IDs" "N${_R}/${_R} IDs")"
  local count
  count="$(_scan_prose_all "$f")"
  [[ "$count" -eq 0 ]]
}

@test "alpha requirement plant inside edge-cases fixture is caught" {
  local f
  f="$(_fx skills/edge-cases/SKILL.md "${_R}-traceability planted")"
  local count
  # Edge-cases folder skip applies to edge-case IDs only, not alpha tokens
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "standalone phrase inside edge-cases fixture is caught" {
  local f
  f="$(_fx skills/edge-cases/SKILL.md "see ${_R} ID column")"
  local count
  # Edge-cases folder skip applies to edge-case IDs only, not phrase scanner
  count="$(_scan_prose_for_fr_id_phrase "$f")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Exempt literal in a non-exempt file is caught
# ---------------------------------------------------------------------------

@test "exempt literal in non-exempt file is caught" {
  local f
  f="$(_fx skills/gaia-qa-tests/SKILL.md "(${_R}-xxx)")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Edge-case plant in a non-exempt skills/ folder is caught
# ---------------------------------------------------------------------------

@test "edge-case token in a non-exempt skills folder is caught" {
  local f
  # The edge-case scanner exempts only edge-cases/ and gaia-create-story/;
  # a token in any other skills/ subfolder must be caught.
  f="$(_fx skills/gaia-qa-tests/SKILL.md "per ${_E}-10 rule")"
  local count
  count="$(_scan_prose_for_ec_ids "$f")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Multi-file scanning: leak only in second file is caught
# ---------------------------------------------------------------------------

@test "alpha requirement scanner catches leak in second of two files" {
  local clean leaky
  clean="$(_fx scan-a-clean.md "no leak here")"
  leaky="$(_fx scan-a-leaky.md "has ${_R}-traceability token")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$clean" "$leaky")"
  [[ "$count" -gt 0 ]]
}

@test "standalone phrase scanner catches leak in second of two files" {
  local clean leaky
  clean="$(_fx scan-b-clean.md "no leak here")"
  leaky="$(_fx scan-b-leaky.md "uses ${_R} ID here")"
  local count
  count="$(_scan_prose_for_fr_id_phrase "$clean" "$leaky")"
  [[ "$count" -gt 0 ]]
}

@test "edge-case scanner catches leak in second of two files" {
  local clean leaky
  clean="$(_fx scan-c-clean.md "no leak here")"
  leaky="$(_fx scan-c-leaky.md "per ${_E}-10 rule")"
  local count
  count="$(_scan_prose_for_ec_ids "$clean" "$leaky")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Optional hardening: planted requirement-identifier forms
# ---------------------------------------------------------------------------

@test "planted prefix-only requirement form in ux skill is caught" {
  # Ensures the ux heading exemption strips only the exact
  # "FR-to-Screen Mapping" phrase, not all "FR-to" prefixes.
  local f
  f="$(_fx skills/gaia-create-ux/SKILL.md "${_R}-tomato heading")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted requirement-identifier in a non-exempt file is caught" {
  # Ensures the gap-analysis/edit-test-plan exemption does NOT
  # extend to gaia-qa-tests, which is a non-exempt file.
  local f
  f="$(_fx skills/gaia-qa-tests/SKILL.md "for ${_R}-NNN mentions")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted format-convention form is caught by alpha scanner" {
  # Ensures the alpha scanner does NOT add old carve-outs
  # like "Format as" — those belong to the numeric requirement scanner only.
  local f
  f="$(_fx a.md "Format as ${_R}-xxx, ${_R}-yyy")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

@test "planted underscore-form requirement token is caught by alpha scanner" {
  # The alpha pattern has an underscore branch that is otherwise untested.
  local f
  f="$(_fx a.md "see ${_R}-some_thing doc")"
  local count
  count="$(_scan_prose_for_fr_alpha_ids "$f")"
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Test-gap-analysis SKILL.md has no internal test-case or feature-key tokens
# ---------------------------------------------------------------------------

@test "test-gap-analysis example uses neutral placeholders" {
  local skill="${BATS_TEST_DIRNAME}/../skills/gaia-test-gap-analysis/SKILL.md"
  [ -f "$skill" ] || { printf 'gap-analysis SKILL.md not found at expected path\n' >&2; return 1; }
  local count
  # Must not contain feature-key-shaped tokens or internal test-case IDs
  count="$(grep -cE 'TC-[A-Z]+-[0-9]|VSP' "$skill" || true)"
  [[ "$count" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Full published set green after sweep plus exemptions — deduplicates test 1
# by scanning only the three new scanner classes (alpha, phrase, edge-case)
# ---------------------------------------------------------------------------

@test "full published set green for extended scanners" {
  local -a prose_targets
  _build_prose_target_list

  [ ${#prose_targets[@]} -gt 0 ] || { printf 'FAIL: no .md files found under the published tree\n' >&2; return 1; }

  local count
  count="$(_scan_prose_for_fr_alpha_ids "${prose_targets[@]}")"
  [ "$count" -eq 0 ]
  count="$(_scan_prose_for_fr_id_phrase "${prose_targets[@]}")"
  [ "$count" -eq 0 ]
  count="$(_scan_prose_for_ec_ids "${prose_targets[@]}")"
  [ "$count" -eq 0 ]
}
