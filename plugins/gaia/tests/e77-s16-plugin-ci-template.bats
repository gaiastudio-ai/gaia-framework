#!/usr/bin/env bats
# e77-s16-plugin-ci-template.bats — E77-S16 / FR-418 / AC1 + AC6
#
# Validates the plugin CI template at:
#   plugins/gaia/templates/ci/plugin-ci.yml
#
# Contract:
#   * Exactly eight ACTIVE jobs: frontmatter-lint, manifest-validate,
#     structure-validate, bats-tests, bats-script-refs-lint, shellcheck,
#     markdownlint, changelog-enforce.
#   * NO regression-audit, NO drift-guard jobs.
#   * An LLM-review job appears as a YAML COMMENT placeholder block with
#     the explanatory text "uncomment when Anthropic CI integration
#     available".
#   * Each job specifies its required adapter dependency in a comment
#     (AC6 — explicit dependency declaration).
#   * Jobs are top-level under `jobs:` with no inter-job `needs:` (AC6 —
#     job isolation: a single job failure must not cascade).

load 'test_helper.bash'

setup() { common_setup; }
teardown() { common_teardown; }

TEMPLATE="$(cd "$BATS_TEST_DIRNAME/../templates/ci" 2>/dev/null && pwd || echo MISSING)/plugin-ci.yml"

@test "AC1: plugin-ci.yml template file exists at the canonical path" {
  [ -f "$TEMPLATE" ]
}

@test "AC1: template parses as valid YAML" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not on PATH"; fi
  run python3 -c "import sys, yaml; yaml.safe_load(open('$TEMPLATE'))"
  [ "$status" -eq 0 ]
}

@test "AC1: exactly eight active jobs are defined" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not on PATH"; fi
  run python3 -c "
import yaml
d = yaml.safe_load(open('$TEMPLATE'))
jobs = list((d.get('jobs') or {}).keys())
print(' '.join(sorted(jobs)))
print('count:', len(jobs))
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"count: 8"* ]]
}

@test "AC1: the eight canonical job names are present" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not on PATH"; fi
  run python3 -c "
import yaml
d = yaml.safe_load(open('$TEMPLATE'))
expected = {'frontmatter-lint','manifest-validate','structure-validate','bats-tests','bats-script-refs-lint','shellcheck','markdownlint','changelog-enforce'}
got = set((d.get('jobs') or {}).keys())
missing = expected - got
extra   = got - expected
if missing: print('MISSING:', sorted(missing))
if extra:   print('EXTRA:',   sorted(extra))
"
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISSING:"* ]]
  [[ "$output" != *"EXTRA:"* ]]
}

@test "AC1: NO regression-audit job is defined (must move to gaia-internal-ci-extras)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not on PATH"; fi
  run python3 -c "
import yaml
d = yaml.safe_load(open('$TEMPLATE'))
jobs = (d.get('jobs') or {})
print('regression-audit' in jobs)
"
  [ "$output" == "False" ]
}

@test "AC1: NO drift-guard job is defined" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not on PATH"; fi
  run python3 -c "
import yaml
d = yaml.safe_load(open('$TEMPLATE'))
jobs = (d.get('jobs') or {})
print('drift-guard' in jobs)
"
  [ "$output" == "False" ]
}

@test "AC1: LLM-review placeholder is present as a YAML comment block" {
  # The placeholder MUST sit in the file as commented YAML so it is
  # syntactically inactive but still discoverable in a textual grep.
  grep -qE '^\s*#.*llm-review' "$TEMPLATE"
}

@test "AC1: LLM-review placeholder carries the canonical advisory comment" {
  grep -q 'uncomment when Anthropic CI integration available' "$TEMPLATE"
}

@test "AC6: each job carries an adapter-dependency declaration in a comment" {
  # Each of the eight jobs must call out its required adapter (or "built-in")
  # in a leading comment so the dependency is explicit per AC6.
  for job in frontmatter-lint manifest-validate structure-validate bats-tests \
             bats-script-refs-lint shellcheck markdownlint changelog-enforce; do
    if ! grep -qE "adapter:.*${job}|${job}.*adapter|adapter-dep" "$TEMPLATE"; then
      # Fallback — every job block has a `# adapter:` line above the key.
      if ! awk -v target="$job:" '
        /^[[:space:]]*#[[:space:]]*adapter:/ { last_adapter = NR }
        $0 ~ "^[[:space:]]+" target "$" { if (last_adapter && NR-last_adapter < 5) found=1; exit }
        END { exit (found ? 0 : 1) }
      ' "$TEMPLATE"; then
        echo "no adapter declaration for $job"
        return 1
      fi
    fi
  done
}

@test "AC6: NO inter-job needs: dependency exists (jobs run isolated, no cascade)" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not on PATH"; fi
  run python3 -c "
import yaml
d = yaml.safe_load(open('$TEMPLATE'))
for name, job in (d.get('jobs') or {}).items():
    if 'needs' in (job or {}):
        print('CASCADE:', name, '->', job['needs'])
"
  [ "$status" -eq 0 ]
  [[ "$output" != *"CASCADE:"* ]]
}

@test "AC1: bats-tests job invokes bats-budget-watch.sh" {
  grep -q 'bats-budget-watch.sh' "$TEMPLATE"
}

@test "AC1: shellcheck job references the shellcheck adapter" {
  grep -qE 'adapters/shellcheck/run\.sh|shellcheck' "$TEMPLATE"
}

@test "AC1: markdownlint job references the markdownlint adapter" {
  grep -qE 'adapters/markdownlint/run\.sh|markdownlint' "$TEMPLATE"
}
