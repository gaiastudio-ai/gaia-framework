#!/usr/bin/env bats
# generate-config.sh yaml_quote newline hardening.
#
# A JSON-sourced config field value containing a newline previously took the
# bare (unquoted) branch of yaml_quote, emitting a raw line break into the YAML
# stream. A value whose own line was `---`/`...` became a YAML document
# separator, corrupting the generated config into a multi-document stream.
# yaml_quote must now force-quote AND escape \n/\r so the generated config
# stays a single document.

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GEN="$PLUGIN_ROOT/skills/gaia-init/scripts/generate-config.sh"
}

@test "yaml_quote force-quotes and escapes newlines (AC1/AC4)" {
  grep -qF '"\n" in s or "\r" in s' "$GEN"
  grep -qF ".replace('\\n', '\\\\n')" "$GEN"
}

@test "newline-bearing scalar keeps the generated config a single YAML document (AC2)" {
  cd "$BATS_TEST_TMPDIR"
  python3 -c 'import json,sys; json.dump({"project_name":"myproj\n---\nfoo","project_kind":"service","stacks":[{"name":"b","language":"python","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["server"]}, sys.stdout)' > bundle.json
  run bash "$GEN" --path . --name myproj --phase full < bundle.json
  [ "$status" -eq 0 ]
  # No raw document separator line emitted.
  run grep -c '^---$' .gaia/config/project-config.yaml
  [ "$output" = "0" ]
  # And it parses as exactly one document when pyyaml is available.
  if python3 -c 'import yaml' 2>/dev/null; then
    run python3 -c 'import yaml; print(len(list(yaml.safe_load_all(open(".gaia/config/project-config.yaml")))))'
    [ "$output" = "1" ]
  fi
}

@test "carriage-return-bearing scalar is also quoted+escaped (AC1)" {
  cd "$BATS_TEST_TMPDIR"
  python3 -c 'import json,sys; json.dump({"project_name":"a\rb","project_kind":"service","stacks":[{"name":"b","language":"python","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["server"]}, sys.stdout)' > bundle.json
  run bash "$GEN" --path . --name a --phase full < bundle.json
  [ "$status" -eq 0 ]
  if python3 -c 'import yaml' 2>/dev/null; then
    run python3 -c 'import yaml; print(len(list(yaml.safe_load_all(open(".gaia/config/project-config.yaml")))))'
    [ "$output" = "1" ]
  fi
}

@test "ordinary single-line scalar quoting is unchanged (AC3)" {
  cd "$BATS_TEST_TMPDIR"
  python3 -c 'import json,sys; json.dump({"project_name":"plainproj","project_kind":"service","stacks":[{"name":"b","language":"python","paths":["src/"]}],"ci_platform":{"provider":"github-actions"},"platforms":["server"]}, sys.stdout)' > bundle.json
  run bash "$GEN" --path . --name plainproj --phase full < bundle.json
  [ "$status" -eq 0 ]
  cfg="$(cat .gaia/config/project-config.yaml)"
  # plainproj has no special char → still bare (unquoted), no spurious quoting.
  [[ "$cfg" == *"project_name: plainproj"* ]]
  [[ "$cfg" == *"provider: github-actions"* ]]
}
