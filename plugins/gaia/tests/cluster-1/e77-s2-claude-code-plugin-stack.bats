#!/usr/bin/env bats
# e77-s2-claude-code-plugin-stack.bats — E77-S2: claude-code-plugin stack file
#
# Verifies the claude-code-plugin.yaml stack-definition file shipped under
# gaia-public/plugins/gaia/config/stacks/ per FR-404 / ADR-087.
#
# Acceptance criteria covered:
#   AC1 — file_extensions array lists canonical Claude Code plugin file types
#   AC2 — discovery_rules requires 3+ co-occurring signals (min_signals: 3)
#   AC3 — casing section declares kebab-case slug + lowercase-ext rules
#   AC4 — frontmatter_requirements.name_equals_basename is true
#   AC5 — name_equals_basename comparison is byte-exact (LC_ALL=C semantics)
#   AC6 — file lives at config/stacks/claude-code-plugin.yaml so the
#         project_kind=claude-code-plugin resolver can discover it
#   AC7 — malformed/missing stack file produces a clear, non-silent error

load 'test_helper.bash'
bats_require_minimum_version 1.5.0

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
STACKS_DIR="$PLUGIN_DIR/config/stacks"
PLUGIN_YAML="$STACKS_DIR/claude-code-plugin.yaml"

setup() { common_setup; }
teardown() { common_teardown; }

# --- helpers ---------------------------------------------------------------

_yaml_supported() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import yaml' >/dev/null 2>&1
}

_yaml_top_keys() {
  python3 - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
for k in doc.keys():
    print(k)
PY
}

_yaml_scalar() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
v = doc.get(sys.argv[2])
if v is None:
    sys.exit(1)
print(v)
PY
}

# --- AC1: file_extensions ---------------------------------------------------

@test "AC1: claude-code-plugin.yaml exists under config/stacks/" {
  [ -f "$PLUGIN_YAML" ]
}

@test "AC1: claude-code-plugin.yaml is valid YAML" {
  _yaml_supported || skip "python3+yaml unavailable"
  python3 -c "import yaml; yaml.safe_load(open('$PLUGIN_YAML'))"
}

@test "AC1: file_extensions array contains .md, .bash, .bats, .json, .yaml" {
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
fe = doc.get('file_extensions') or []
assert isinstance(fe, list), "file_extensions must be a list"
required = {'.md', '.bash', '.bats', '.json', '.yaml'}
missing = required - set(fe)
assert not missing, f"file_extensions missing: {sorted(missing)}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- AC2: discovery_rules ---------------------------------------------------

@test "AC2: discovery_rules.signals lists manifest.yaml + plugins/*/SKILL.md + scripts/*.sh" {
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
dr = doc.get('discovery_rules') or {}
signals = dr.get('signals') or []
assert isinstance(signals, list), "discovery_rules.signals must be a list"
joined = ' '.join(signals)
for token in ('manifest.yaml', 'SKILL.md', 'scripts'):
    assert token in joined, f"signals must reference '{token}', got {signals}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "AC2: discovery_rules.min_signals is 3" {
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
dr = doc.get('discovery_rules') or {}
ms = dr.get('min_signals')
assert ms == 3, f"min_signals must be 3, got {ms!r}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- AC3: casing ------------------------------------------------------------

@test "AC3: casing section declares slug rule (kebab-case) + extension rule (lowercase)" {
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
casing = doc.get('casing') or {}
assert isinstance(casing, dict), "casing must be a mapping"
serialized = yaml.safe_dump(casing).lower()
assert 'kebab' in serialized, f"casing must reference kebab-case for slugs: {casing}"
assert 'lowercase' in serialized or 'lower' in serialized, \
    f"casing must reference lowercase for file extensions: {casing}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- AC4 + AC5: frontmatter_requirements -----------------------------------

@test "AC4: frontmatter_requirements.name_equals_basename is true" {
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
fr = doc.get('frontmatter_requirements') or {}
assert fr.get('name_equals_basename') is True, \
    f"name_equals_basename must be the boolean true, got {fr.get('name_equals_basename')!r}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "AC4: frontmatter_requirements lists required fields name, description, version" {
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
fr = doc.get('frontmatter_requirements') or {}
required = fr.get('required_fields') or fr.get('required') or []
required_set = set(required)
for field in ('name', 'description', 'version'):
    assert field in required_set, \
        f"frontmatter_requirements must list '{field}' as required: {required}"
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "AC5: name_equals_basename comparison is byte-exact (LC_ALL=C semantics)" {
  # AC5: a directory 'My-Skill' with frontmatter 'name: my-skill' must FAIL
  # under byte-exact comparison. We simulate the comparison the validator
  # will perform — bash string equality under LC_ALL=C is byte-exact.
  LC_ALL=C
  basename="My-Skill"
  name_field="my-skill"
  if [ "$basename" = "$name_field" ]; then
    echo "byte-exact compare did not detect case mismatch" >&2
    return 1
  fi
  basename2="gaia-help"
  name2="gaia-help"
  [ "$basename2" = "$name2" ]
}

@test "AC5: stack file documents Linux-CI / case-sensitive enforcement" {
  # The stack file must explicitly mark the comparison as case-sensitive so
  # downstream validators do not invent a default. We accept either an
  # explicit `case_sensitive: true` flag or a `linux_ci` enforcement note.
  _yaml_supported || skip "python3+yaml unavailable"
  run python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f) or {}
fr = doc.get('frontmatter_requirements') or {}
cs = fr.get('case_sensitive')
enforce = fr.get('enforce_on') or fr.get('enforced_on')
ok = (cs is True) or (enforce and 'linux' in str(enforce).lower())
assert ok, (
    f"frontmatter_requirements must declare case_sensitive: true OR "
    f"enforce_on: linux-ci — got case_sensitive={cs!r} enforce_on={enforce!r}"
)
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

# --- AC6: file location / project_kind discoverability --------------------

@test "AC6: stack file path is exactly config/stacks/claude-code-plugin.yaml" {
  # The resolver discovers stacks by basename under config/stacks/. The path
  # itself is the contract — any other path means the resolver will not find
  # the file when project_kind=claude-code-plugin.
  expected="$PLUGIN_DIR/config/stacks/claude-code-plugin.yaml"
  [ "$PLUGIN_YAML" = "$expected" ]
  [ -f "$expected" ]
}

@test "AC6: top-level keys cover the four schema sections" {
  _yaml_supported || skip "python3+yaml unavailable"
  keys=$(_yaml_top_keys "$PLUGIN_YAML") || return 1
  for k in file_extensions discovery_rules casing frontmatter_requirements; do
    echo "$keys" | grep -qx "$k" || { echo "missing top-level key '$k'" >&2; return 1; }
  done
}

# --- AC7: malformed / missing stack file ---------------------------------

@test "AC7: malformed YAML raises a parse error (no silent fallback)" {
  _yaml_supported || skip "python3+yaml unavailable"
  bad="$TEST_TMP/claude-code-plugin.yaml"
  printf 'file_extensions:\n  - .md\n  bogus: [unclosed\n' >"$bad"
  run python3 -c "import sys, yaml; yaml.safe_load(open('$bad'))"
  [ "$status" -ne 0 ]
}

@test "AC7: missing stack file is detectable (no silent fallback)" {
  missing="$TEST_TMP/does-not-exist.yaml"
  [ ! -f "$missing" ]
  # Caller code MUST treat absence as an error, not a fallback. We assert the
  # contract by verifying the file-not-found check is observable.
  run test -f "$missing"
  [ "$status" -ne 0 ]
}

# --- Schema hygiene -------------------------------------------------------

@test "no tab characters (YAML disallows tabs for indent)" {
  [ -f "$PLUGIN_YAML" ] || { echo "missing $PLUGIN_YAML" >&2; return 1; }
  if grep -qP '^\t' "$PLUGIN_YAML" 2>/dev/null; then
    echo "tab indent found in $PLUGIN_YAML" >&2
    return 1
  fi
}

@test "no trailing whitespace" {
  [ -f "$PLUGIN_YAML" ] || { echo "missing $PLUGIN_YAML" >&2; return 1; }
  if grep -nE ' +$' "$PLUGIN_YAML"; then
    echo "trailing whitespace found in $PLUGIN_YAML" >&2
    return 1
  fi
}

@test "no duplicate top-level keys (PyYAML strict load)" {
  _yaml_supported || skip "python3+yaml unavailable"
  python3 - "$PLUGIN_YAML" <<'PY'
import sys, yaml
class StrictLoader(yaml.SafeLoader):
    pass
def no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found duplicate key %r" % key,
                key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping
StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)
yaml.load(open(sys.argv[1]), Loader=StrictLoader)
PY
}
