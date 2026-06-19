#!/usr/bin/env bats
# e65-s7-performance-review-migration.bats — structural assertions for the
# `gaia-performance-review` migration to the E65-S2 review-skill template.
#
# Pattern-matches against E65-S6 (gaia-test-review). Verifies:
#   - TC-DEJ-PHASE-S7   — seven canonical phase headers in order
#   - TC-DEJ-DET-S7     — determinism settings (temperature: 0, model pin, prompt_hash)
#   - TC-DEJ-TOOLKIT-PR-01 — perf toolkit declared (N+1 + complexity + bundle/memory)
#   - TC-DEJ-RUBRIC-S7  — severity rubric carries ≥2 examples per tier for performance categories
#   - TC-DEJ-WRITE-S7-1 — FR-402 review-file path declared (performance-review-{story_key}.md)
#   - TC-DEJ-WRITE-S7-2 — fork allowlist exactly [Read, Grep, Glob, Bash]
#   - TC-DEJ-PARITY-S7  — gaia-performance-review registered in evidence-judgment-parity.bats
#
# Edge-case coverage (all static-text reads against migrated SKILL.md):
#   - EC-1  — per-stack ORM patterns + raw-SQL fallback documented
#   - EC-2  — bundle 30s timeout cap documented
#   - EC-3  — recursive-function exemption documented
#   - EC-4  — runtime profiling out-of-scope (Lighthouse) documented
#   - EC-5  — go heap analysis out-of-scope; static patterns only
#   - EC-6  — canonical N+1 (ORM call inside loop) documented
#   - EC-7  — known-small-collection downgrade documented
#   - EC-8  — hot-path tagging documented
#   - EC-9  — per-stack complexity tools documented (radon, gocyclo, PMD, dart_code_metrics)
#   - EC-10 — blocking sync I/O per stack documented
#   - EC-11 — bounded-vs-unbounded memory idiom documented
#   - EC-12 — index-hint analysis schema-gated documented
#   - EC-13 — large dep import threshold documented
#   - EC-14 — per-tool timeout caps (N+1 ≤15s, complexity ≤15s, bundle ≤30s, memory ≤10s)
#
# All assertions are static-text reads against the migrated SKILL.md — no
# fork/subagent dispatch, no network. Suite is fast (<1s wall-clock).

load 'test_helper.bash'

bats_require_minimum_version 1.5.0

SKILL_FILE="$BATS_TEST_DIRNAME/../skills/gaia-performance-review/SKILL.md"

setup() { common_setup; }
teardown() { common_teardown; }

# --- TC-DEJ-WRITE-S7-2 — fork allowlist read-only ---

@test "allowed-tools is exactly [Read, Grep, Glob, Bash]" {
  run grep -E '^allowed-tools:' "$SKILL_FILE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E '\[Read, Grep, Glob, Bash\]' >/dev/null
}

@test "no Write or Edit appears in allowed-tools" {
  run grep -E '^allowed-tools:.*(Write|Edit)' "$SKILL_FILE"
  [ "$status" -ne 0 ]
}

@test "context: fork declared in frontmatter" {
  grep -F 'context: fork' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-PHASE-S7 — unifying principle + seven phase headers in order ---

@test "unifying principle present verbatim" {
  grep -F 'Deterministic tools provide evidence. The LLM provides judgment. The LLM consumes deterministic output; it does not override it.' "$SKILL_FILE" >/dev/null
}

@test "seven canonical phase headers in order" {
  local got
  got="$(grep -nE '^### Phase [1-7]' "$SKILL_FILE" || true)"
  echo "$got" | grep -F 'Phase 1' >/dev/null
  echo "$got" | grep -F 'Phase 2' >/dev/null
  echo "$got" | grep -F 'Phase 3A' >/dev/null
  echo "$got" | grep -F 'Phase 3B' >/dev/null
  echo "$got" | grep -F 'Phase 4' >/dev/null
  echo "$got" | grep -F 'Phase 5' >/dev/null
  echo "$got" | grep -F 'Phase 6' >/dev/null
  echo "$got" | grep -F 'Phase 7' >/dev/null
}

# --- TC-DEJ-DET-S7 — determinism settings ---

@test "temperature: 0 declared" {
  grep -F 'temperature: 0' "$SKILL_FILE" >/dev/null
}

@test "model pinned to claude-opus-4-7" {
  grep -F 'claude-opus-4-7' "$SKILL_FILE" >/dev/null
}

@test "prompt_hash recording declared" {
  grep -F 'prompt_hash' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-TOOLKIT-PR-01 — perf toolkit declared ---

@test "N+1 query detection declared" {
  grep -iE 'N\+1' "$SKILL_FILE" >/dev/null
}

@test "complexity analysis declared" {
  grep -iE 'cyclomatic|complexity analysis' "$SKILL_FILE" >/dev/null
}

@test "bundle/memory budget checks declared" {
  grep -iE 'bundle' "$SKILL_FILE" >/dev/null
  grep -iE 'memory' "$SKILL_FILE" >/dev/null
}

@test "stack-toolkit table declares all seven canonical stacks" {
  grep -F 'ts-dev' "$SKILL_FILE" >/dev/null
  grep -F 'python-dev' "$SKILL_FILE" >/dev/null
  grep -F 'go-dev' "$SKILL_FILE" >/dev/null
  grep -F 'flutter-dev' "$SKILL_FILE" >/dev/null
  grep -F 'java-dev' "$SKILL_FILE" >/dev/null
  grep -F 'mobile-dev' "$SKILL_FILE" >/dev/null
  grep -F 'angular-dev' "$SKILL_FILE" >/dev/null
}

@test "per-stack ORM patterns declared" {
  grep -iE 'Prisma' "$SKILL_FILE" >/dev/null
  grep -iE 'JPA|@OneToMany' "$SKILL_FILE" >/dev/null
  grep -iE 'SQLAlchemy|Django' "$SKILL_FILE" >/dev/null
  grep -iE 'GORM' "$SKILL_FILE" >/dev/null
}

@test "raw-SQL fallback documented" {
  grep -iE 'raw[- ]SQL|raw-sql' "$SKILL_FILE" >/dev/null
  grep -iE 'fallback' "$SKILL_FILE" >/dev/null
}

@test "per-stack complexity tools declared" {
  grep -iE 'eslint-plugin-sonarjs|eslint-plugin-complexity' "$SKILL_FILE" >/dev/null
  grep -iE 'radon' "$SKILL_FILE" >/dev/null
  grep -iE 'gocyclo' "$SKILL_FILE" >/dev/null
  grep -iE 'PMD|Checkstyle' "$SKILL_FILE" >/dev/null
  grep -iE 'dart_code_metrics' "$SKILL_FILE" >/dev/null
}

@test "runtime profiling out-of-scope documented" {
  grep -iE 'out of scope|out-of-scope' "$SKILL_FILE" >/dev/null
  grep -iE 'Lighthouse' "$SKILL_FILE" >/dev/null
  grep -iE 'pprof|heap profiler|heap analysis' "$SKILL_FILE" >/dev/null
}

@test "hot-path tagging documented" {
  grep -iE 'hot[- ]path|hot_path' "$SKILL_FILE" >/dev/null
  grep -iE '/api/|handlers|routes|resolvers' "$SKILL_FILE" >/dev/null
}

@test "per-tool timeout caps documented" {
  grep -iE 'N\+1.*15s|15s.*N\+1' "$SKILL_FILE" >/dev/null
  grep -iE 'complexity.*15s|15s.*complexity' "$SKILL_FILE" >/dev/null
  grep -iE 'bundle.*30s|30s.*bundle' "$SKILL_FILE" >/dev/null
  grep -iE 'memory.*10s|10s.*memory' "$SKILL_FILE" >/dev/null
}

@test "cumulative 60s budget documented" {
  grep -iE '60s|NFR-DEJ-1' "$SKILL_FILE" >/dev/null
}

@test "blocking sync I/O per stack documented" {
  grep -iE 'readFileSync|fs\.\*Sync' "$SKILL_FILE" >/dev/null
  grep -iE 'requests\.|sync HTTP' "$SKILL_FILE" >/dev/null
}

@test "index-hint analysis schema-gated" {
  grep -iE 'index[- ]hint|missing index' "$SKILL_FILE" >/dev/null
  grep -iE 'schema' "$SKILL_FILE" >/dev/null
}

@test "cache key includes bundle_config_hash + schema_hash" {
  grep -F 'bundle_config_hash' "$SKILL_FILE" >/dev/null
  grep -F 'schema_hash' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-RUBRIC-S7 — severity rubric examples ---

@test "Critical tier present" {
  grep -E '^### Critical' "$SKILL_FILE" >/dev/null
}

@test "Warning tier present" {
  grep -E '^### Warning' "$SKILL_FILE" >/dev/null
}

@test "Suggestion tier present" {
  grep -E '^### Suggestion' "$SKILL_FILE" >/dev/null
}

@test "Critical examples include N+1 on hot path and blocking sync I/O" {
  grep -iE 'N\+1.*hot|hot.*N\+1' "$SKILL_FILE" >/dev/null
  grep -iE 'blocking.*sync|sync.*blocking|readFileSync' "$SKILL_FILE" >/dev/null
}

@test "Warning examples include high complexity and missing index hint and large dep import" {
  grep -iE 'cyclomatic complexity|high complexity' "$SKILL_FILE" >/dev/null
  grep -iE 'missing index' "$SKILL_FILE" >/dev/null
  grep -iE 'large dep import|30KB' "$SKILL_FILE" >/dev/null
}

@test "Suggestion examples include recursive-exempt and known-small-collection" {
  grep -iE 'recursive' "$SKILL_FILE" >/dev/null
  grep -iE 'known[- ]small|statically[- ]bounded|small collection' "$SKILL_FILE" >/dev/null
}

@test "bounded-vs-unbounded memory idiom documented" {
  grep -iE 'bounded' "$SKILL_FILE" >/dev/null
  grep -iE 'unbounded' "$SKILL_FILE" >/dev/null
  grep -iE 'shift|circular buffer|LRU' "$SKILL_FILE" >/dev/null
}

# --- TC-DEJ-WRITE-S7-1 — FR-402 review-file path declared ---

@test "path performance-review-{story_key}.md declared" {
  # AF-2026-05-21-23 canonicalized this path. Accept canonical or legacy.
  grep -F 'performance-review-' "$SKILL_FILE" | grep -qE '(docs|\.gaia/artifacts)/implementation-artifacts/'
}

@test "parent-mediated write (Option A) documented" {
  grep -iF 'parent-mediated' "$SKILL_FILE" >/dev/null
  grep -iF 'the parent writes the file' "$SKILL_FILE" >/dev/null
}

# --- shared-script invocation present ---

@test "shared scripts: load-stack-persona.sh referenced" {
  grep -F 'load-stack-persona.sh' "$SKILL_FILE" >/dev/null
}

@test "shared scripts: verdict-resolver.sh referenced" {
  grep -F 'verdict-resolver.sh' "$SKILL_FILE" >/dev/null
}

@test "shared scripts: file-list-diff-check.sh referenced" {
  grep -F 'file-list-diff-check.sh' "$SKILL_FILE" >/dev/null
}

@test "shared scripts: review-gate.sh referenced for Performance Review gate" {
  grep -F 'review-gate.sh' "$SKILL_FILE" >/dev/null
  grep -F '"Performance Review"' "$SKILL_FILE" >/dev/null
}

# --- evidence-judgment-parity.bats registration check ---

@test "gaia-performance-review registered in REVIEW_SKILLS array" {
  local parity="$BATS_TEST_DIRNAME/evidence-judgment-parity.bats"
  grep -F 'skills/gaia-performance-review/SKILL.md' "$parity" >/dev/null
}
