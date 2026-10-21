#!/usr/bin/env bats
# Tests for the concurrent-sprints glossary entries and related catalogue updates.
# Component: documentation

# Unified ID-scrub pattern used by all AC5 tests (exempt: regex literals in this file).
# Covers: FR-nnn, NFR-nnn, SR-nnn, ADR-nnn, E#-S#, TC-XXX-n, AF-20xx, AI-20xx

load 'test_helper.bash'

_ID_PATTERN='FR-[0-9]{2,}|NFR-[0-9]{2,}|SR-[0-9]{2,}|ADR-[0-9]{2,}|E[0-9]+-S[0-9]+|TC-[A-Z]+-[0-9]+|AF-20[0-9]{2}|AI-20[0-9]{2}'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GLOSSARY="$REPO_ROOT/documentation/glossary.html"
  HELP_CSV="$REPO_ROOT/plugins/gaia/knowledge/gaia-help.csv"
  MANIFEST_CSV="$REPO_ROOT/plugins/gaia/knowledge/workflow-manifest.csv"
  HELP_SKILL="$REPO_ROOT/plugins/gaia/skills/gaia-help/SKILL.md"
}

# --- AC1: glossary entries exist with correct anchors ---

@test "glossary entry for concurrent sprints exists with correct anchor" {
  grep -q 'id="concurrent-sprints"' "$GLOSSARY"
}

@test "glossary entry for phase-parallel execution exists with correct anchor" {
  grep -q 'id="phase-parallel-execution"' "$GLOSSARY"
}

@test "concurrent-sprints entry defines multiple sprints active simultaneously" {
  awk '/id="concurrent-sprints"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'multiple sprints.*active.*simultaneously'
}

@test "concurrent-sprints entry mentions own session" {
  awk '/id="concurrent-sprints"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'own session'
}

@test "phase-parallel-execution entry defines concurrent stories within a single sprint" {
  awk '/id="phase-parallel-execution"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'concurrent.*stories.*single sprint'
}

@test "phase-parallel-execution entry mentions dev-slot budget" {
  awk '/id="phase-parallel-execution"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'dev.slot'
}

@test "concurrent-sprints anchor appears between artifact and edge-types anchors" {
  art_line=$(grep -n 'id="artifact"' "$GLOSSARY" | head -1 | cut -d: -f1)
  cs_line=$(grep -n 'id="concurrent-sprints"' "$GLOSSARY" | head -1 | cut -d: -f1)
  et_line=$(grep -n 'id="edge-types"' "$GLOSSARY" | head -1 | cut -d: -f1)
  [ -n "$art_line" ] && [ -n "$cs_line" ] && [ -n "$et_line" ]
  [ "$art_line" -lt "$cs_line" ]
  [ "$cs_line" -lt "$et_line" ]
}

@test "phase-parallel-execution anchor appears between nfr and promotion-chain anchors" {
  nfr_line=$(grep -n 'id="nfr"' "$GLOSSARY" | head -1 | cut -d: -f1)
  ppe_line=$(grep -n 'id="phase-parallel-execution"' "$GLOSSARY" | head -1 | cut -d: -f1)
  pc_line=$(grep -n 'id="promotion-chain"' "$GLOSSARY" | head -1 | cut -d: -f1)
  [ -n "$nfr_line" ] && [ -n "$ppe_line" ] && [ -n "$pc_line" ]
  [ "$nfr_line" -lt "$ppe_line" ]
  [ "$ppe_line" -lt "$pc_line" ]
}

# --- AC2: orthogonality statement ---

@test "concurrent-sprints entry states orthogonality with phase-parallel execution" {
  awk '/id="concurrent-sprints"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'orthogonal'
}

@test "phase-parallel-execution entry states orthogonality with concurrent sprints" {
  awk '/id="phase-parallel-execution"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'orthogonal'
}

@test "concurrent-sprints entry says features can be used independently or together" {
  awk '/id="concurrent-sprints"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'independently.*together\|together.*independently'
}

@test "phase-parallel-execution entry says features can be used independently or together" {
  awk '/id="phase-parallel-execution"/,/<\/dd>/' "$GLOSSARY" | grep -qi 'independently.*together\|together.*independently'
}

# --- AC3: no parallel-sprint synonyms ---

@test "no parallel sprint synonyms after stripping phase-parallel" {
  hit_count=0
  while IFS= read -r file; do
    case "$file" in
      */tests/fixtures/*) continue ;;
      */tests/concurrent-sprint-glossary.bats) continue ;;
    esac
    if sed 's/phase-parallel//Ig' "$file" | grep -qi 'parallel sprint'; then
      echo "HIT: $file" >&2
      hit_count=$((hit_count + 1))
    fi
  done < <(find "$REPO_ROOT/plugins" "$REPO_ROOT/documentation" -type f \
    \( -name '*.md' -o -name '*.csv' -o -name '*.html' -o -name '*.sh' \
       -o -name '*.bats' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \
       -o -name '*.txt' -o -name '*.js' -o -name '*.ts' -o -name '*.py' \) \
    2>/dev/null)
  [ "$hit_count" -eq 0 ]
}

# --- AC4: help routing ---

@test "gaia-help.csv sprint-plan description contains concurrent sprints" {
  awk -F',' '$4 ~ /^"?sprint-plan"?$/' "$HELP_CSV" | grep -qi 'concurrent sprints'
}

@test "gaia-help.csv run-sprint description contains concurrent sprints" {
  awk -F',' '$4 ~ /^"?run-sprint"?$/' "$HELP_CSV" | grep -qi 'concurrent sprints'
}

@test "gaia-help.csv sprint-status description contains concurrent sprints" {
  awk -F',' '$4 ~ /^"?sprint-status"?$/' "$HELP_CSV" | grep -qi 'concurrent sprints'
}

@test "gaia-help SKILL.md has Terminology note outside Quick Actions" {
  qa_line=$(grep -n '## Quick Actions' "$HELP_SKILL" | head -1 | cut -d: -f1)
  ref_line=$(grep -n '## References' "$HELP_SKILL" | head -1 | cut -d: -f1)
  term_line=$(grep -n 'Terminology' "$HELP_SKILL" | head -1 | cut -d: -f1)
  [ -n "$qa_line" ] && [ -n "$ref_line" ] && [ -n "$term_line" ]
  [ "$qa_line" -lt "$term_line" ]
  [ "$term_line" -lt "$ref_line" ]
}

@test "gaia-help SKILL.md Terminology note points to glossary concurrent-sprints anchor" {
  grep -i 'Terminology' "$HELP_SKILL" -A5 | grep -q 'glossary.html#concurrent-sprints'
}

@test "workflow-manifest.csv sprint-planning description contains concurrent sprints" {
  awk -F',' '$1 ~ /^"?sprint-planning"?$/' "$MANIFEST_CSV" | grep -qi 'concurrent sprints'
}

@test "workflow-manifest.csv run-sprint description contains concurrent sprints" {
  awk -F',' '$1 ~ /^"?run-sprint"?$/' "$MANIFEST_CSV" | grep -qi 'concurrent sprints'
}

@test "workflow-manifest.csv sprint-status description contains concurrent sprints" {
  awk -F',' '$1 ~ /^"?sprint-status"?$/' "$MANIFEST_CSV" | grep -qi 'concurrent sprints'
}

# --- AC4: CSV non-description columns are byte-identical to staging ---

@test "gaia-help.csv non-description columns match expected values" {
  # gaia-help.csv columns: module,phase,name,code,command,required,agent-name,description,output-location
  # Assert that only the description (column 8, index 7) was changed by
  # verifying the other columns match the known, stable identifiers.
  _assert_help_row() {
    local code="$1" expected_nondesc="$2"
    local row nondesc
    row=$(awk -F',' -v c="$code" '$4 ~ "\"?"c"\"?"' "$HELP_CSV")
    nondesc=$(python3 -I -c "
import csv, io, sys
for row in csv.reader(io.StringIO(sys.argv[1])):
    if len(row) >= 9:
        print(','.join([row[i] for i in range(len(row)) if i != 7]))
" "$row")
    if [ "$nondesc" != "$expected_nondesc" ]; then
      echo "Non-description columns differ for code=$code" >&2
      echo "  expected: $expected_nondesc" >&2
      echo "  actual:   $nondesc" >&2
      return 1
    fi
  }
  _assert_help_row "sprint-plan" "lifecycle,4-implementation,sprint-planning,sprint-plan,gaia-sprint-plan,true,sm,.gaia/artifacts/implementation-artifacts"
  _assert_help_row "run-sprint" "lifecycle,4-implementation,run-sprint,run-sprint,gaia-run-sprint,false,sm,.gaia/state/sprint-status.yaml"
  _assert_help_row "sprint-status" "lifecycle,4-implementation,sprint-status,sprint-status,gaia-sprint-status,false,sm,.gaia/artifacts/implementation-artifacts"
}

@test "workflow-manifest.csv non-description columns match expected values" {
  # workflow-manifest.csv columns: name,displayName,description,module,phase,path,command,agent
  # Assert that only the description (column 3, index 2) was changed.
  _assert_manifest_row() {
    local name="$1" expected_nondesc="$2"
    local row nondesc
    row=$(awk -F',' -v n="$name" '$1 ~ "\"?"n"\"?"' "$MANIFEST_CSV")
    nondesc=$(python3 -I -c "
import csv, io, sys
for row in csv.reader(io.StringIO(sys.argv[1])):
    if len(row) >= 8:
        print(','.join([row[i] for i in range(len(row)) if i != 2]))
" "$row")
    if [ "$nondesc" != "$expected_nondesc" ]; then
      echo "Non-description columns differ for name=$name" >&2
      echo "  expected: $expected_nondesc" >&2
      echo "  actual:   $nondesc" >&2
      return 1
    fi
  }
  _assert_manifest_row "sprint-planning" "sprint-planning,Sprint Planning,lifecycle,4-implementation,_gaia/lifecycle/workflows/4-implementation/sprint-planning/workflow.yaml,gaia-sprint-plan,sm"
  _assert_manifest_row "run-sprint" "run-sprint,Run Sprint,lifecycle,4-implementation,_gaia/core/workflows/run-sprint/workflow.yaml,gaia-run-sprint,sm"
  _assert_manifest_row "sprint-status" "sprint-status,Sprint Status,lifecycle,4-implementation,_gaia/lifecycle/workflows/4-implementation/sprint-status/workflow.yaml,gaia-sprint-status,sm"
}

# --- AC1 link integrity: every href added by this story resolves ---

@test "hrefs in concurrent-sprints glossary entry resolve to existing files or anchors" {
  # Extract hrefs from the concurrent-sprints entry
  while IFS= read -r href; do
    case "$href" in
      \#*) # Anchor-only: check the anchor exists in the same file
        anchor="${href#\#}"
        grep -q "id=\"$anchor\"" "$GLOSSARY" || {
          echo "Dead anchor: $href" >&2; return 1
        }
        ;;
      *\#*) # File#anchor
        file="${href%%#*}"
        anchor="${href#*#}"
        target="$REPO_ROOT/documentation/$file"
        [ -f "$target" ] || { echo "Dead file: $target" >&2; return 1; }
        grep -q "id=\"$anchor\"" "$target" || { echo "Dead anchor $anchor in $file" >&2; return 1; }
        ;;
      *) # Plain file
        target="$REPO_ROOT/documentation/$href"
        [ -f "$target" ] || { echo "Dead href: $href (expected $target)" >&2; return 1; }
        ;;
    esac
  done < <(awk '/id="concurrent-sprints"/,/<\/dd>/' "$GLOSSARY" \
    | grep -oE 'href="[^"]*"' | sed 's/href="//;s/"$//')
}

@test "hrefs in phase-parallel-execution glossary entry resolve to existing files or anchors" {
  while IFS= read -r href; do
    case "$href" in
      \#*)
        anchor="${href#\#}"
        grep -q "id=\"$anchor\"" "$GLOSSARY" || {
          echo "Dead anchor: $href" >&2; return 1
        }
        ;;
      *\#*)
        file="${href%%#*}"
        anchor="${href#*#}"
        target="$REPO_ROOT/documentation/$file"
        [ -f "$target" ] || { echo "Dead file: $target" >&2; return 1; }
        grep -q "id=\"$anchor\"" "$target" || { echo "Dead anchor $anchor in $file" >&2; return 1; }
        ;;
      *)
        target="$REPO_ROOT/documentation/$href"
        [ -f "$target" ] || { echo "Dead href: $href (expected $target)" >&2; return 1; }
        ;;
    esac
  done < <(awk '/id="phase-parallel-execution"/,/<\/dd>/' "$GLOSSARY" \
    | grep -oE 'href="[^"]*"' | sed 's/href="//;s/"$//')
}

# --- AC5: internal ID scrub on lines this story adds or changes ---

@test "new glossary entries contain no internal traceability identifiers" {
  cs_block=$(awk '/id="concurrent-sprints"/,/<\/dd>/' "$GLOSSARY")
  ppe_block=$(awk '/id="phase-parallel-execution"/,/<\/dd>/' "$GLOSSARY")
  combined="$cs_block
$ppe_block"
  if grep -Eq "$_ID_PATTERN" <<< "$combined"; then
    echo "Found leaked ID in glossary entries" >&2
    return 1
  fi
  if grep -qi 'per the PRD' <<< "$combined"; then
    echo "Found internal doc reference in glossary entries" >&2
    return 1
  fi
}

@test "updated CSV descriptions contain no internal traceability identifiers" {
  for code in sprint-plan run-sprint sprint-status; do
    desc=$(awk -F',' -v c="$code" '$4 ~ "\"?"c"\"?"' "$HELP_CSV")
    if grep -Eq "$_ID_PATTERN" <<< "$desc"; then
      echo "Found leaked ID in gaia-help.csv description for $code" >&2
      return 1
    fi
  done
  for name in sprint-planning run-sprint sprint-status; do
    desc=$(awk -F',' -v n="$name" '$1 ~ "\"?"n"\"?"' "$MANIFEST_CSV")
    if grep -Eq "$_ID_PATTERN" <<< "$desc"; then
      echo "Found leaked ID in workflow-manifest.csv description for $name" >&2
      return 1
    fi
  done
}

@test "gaia-help SKILL.md Terminology note contains no internal traceability identifiers" {
  grep -qi 'Terminology' "$HELP_SKILL"
  term_block=$(grep -i 'Terminology' "$HELP_SKILL" -A10 -B1)
  if grep -Eq "$_ID_PATTERN" <<< "$term_block"; then
    echo "Found leaked ID in SKILL.md Terminology note" >&2
    return 1
  fi
  if grep -qi 'per the PRD' <<< "$term_block"; then
    echo "Found internal doc reference in Terminology note" >&2
    return 1
  fi
}
