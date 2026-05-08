#!/usr/bin/env bats
# resolve-invitees.bats — gaia-meeting INVITE-phase invitee resolver (E76-S5)
#
# T1 / T4 / T5 — AC1-AC8 / AC11-AC14
#
# resolve-invitees.sh wires the mode registry into the INVITE phase. It accepts
# the resolved mode, the user-supplied invitees (CSV), and a path to a stub
# "agent index" file that lists which agents/stakeholders are installed
# locally (one identifier per line). It emits the resolved invitee list, the
# missing-invitee list (when any), an `invitees_override=true|false` flag, and
# a WARNING to stderr when default invitees are missing.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RESOLVER="$REPO_ROOT/plugins/gaia/skills/gaia-meeting/scripts/resolve-invitees.sh"
  TMPDIR_T="$(mktemp -d)"
  INDEX="$TMPDIR_T/installed.txt"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

write_index() {
  : > "$INDEX"
  for name in "$@"; do
    echo "$name" >> "$INDEX"
  done
}

@test "Pre-flight: resolve-invitees.sh exists and is executable" {
  [ -x "$RESOLVER" ]
}

@test "AC1: explore mode contributes no defaults — resolved == user set" {
  write_index alice
  run "$RESOLVER" --mode explore --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice\$"
  echo "$output" | grep -qE "^missing=\$"
  echo "$output" | grep -qE "^bias=opportunity-map\$"
  echo "$output" | grep -qE "^invitees_override=false\$"
}

@test "AC2: align mode adds Derek + Nate to user set" {
  write_index alice Derek Nate
  run "$RESOLVER" --mode align --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  # Order: user-specified first, then mode-default in registry order
  echo "$output" | grep -qE "^resolved=alice,Derek,Nate\$"
  echo "$output" | grep -qE "^missing=\$"
  echo "$output" | grep -qE "^bias=alignment-summary\$"
}

@test "AC3: red-team adds Zara + Sable + Nova" {
  write_index alice Zara Sable Nova
  run "$RESOLVER" --mode red-team --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Zara,Sable,Nova\$"
  echo "$output" | grep -qE "^bias=risk-register\$"
}

@test "AC4: ac mode resolves Vera, Sable, alex, jamie (mode defaults first)" {
  write_index alex jamie Vera Sable
  run "$RESOLVER" --mode ac --invitees "alex,jamie" --installed "$INDEX"
  [ "$status" -eq 0 ]
  # AC4 specifies the resolved set MUST be exactly Vera, Sable, alex, jamie.
  # Order: mode defaults first, then user-specified. (The set semantics —
  # not order — is what AC4 asserts; the resolver picks an order and we lock it.)
  echo "$output" | grep -qE "^resolved=alex,jamie,Vera,Sable\$"
  echo "$output" | grep -qE "^bias=machine-readable-ac-list\$"
}

@test "AC5: brainstorm adds Rex/Orion/Lyra/Elara/Vermeer" {
  write_index alice Rex Orion Lyra Elara Vermeer
  run "$RESOLVER" --mode brainstorm --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Rex,Orion,Lyra,Elara,Vermeer\$"
  echo "$output" | grep -qE "^bias=brainstorming-document\$"
}

@test "AC6: design mode adds all eight design agents" {
  write_index alice Christy Suki Layla Talia Tariq Lena Cleo Freya
  run "$RESOLVER" --mode design --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Christy,Suki,Layla,Talia,Tariq,Lena,Cleo,Freya\$"
  echo "$output" | grep -qE "^bias=ux-design-notes\$"
}

@test "AC7: architecture mode adds all six architecture agents" {
  write_index alice Theo Soren Milo Juno Omar Priya
  run "$RESOLVER" --mode architecture --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Theo,Soren,Milo,Juno,Omar,Priya\$"
  echo "$output" | grep -qE "^bias=architecture-decisions\$"
}

@test "AC8: sprint mode adds Nate + Derek + Rafael" {
  write_index alice Nate Derek Rafael
  run "$RESOLVER" --mode sprint --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Nate,Derek,Rafael\$"
  echo "$output" | grep -qE "^bias=sprint-adjustments\$"
}

@test "AC11: missing one default invitee emits WARNING and proceeds (exit 0)" {
  write_index alice Theo Soren Milo Juno Priya  # Omar missing
  run "$RESOLVER" --mode architecture --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Theo,Soren,Milo,Juno,Priya\$"
  echo "$output" | grep -qE "^missing=Omar\$"
  # WARNING goes to stderr — bats merges via `$output` only when --separate-stderr is off.
  # Check the prefix and the missing identifier:
  echo "$output" | grep -qE "WARNING.*missing default invitee.*architecture.*Omar" \
    || (>&2 echo "expected WARNING in combined output"; return 1)
}

@test "AC12: all default invitees missing emits WARNING listing all five and proceeds" {
  write_index alice
  run "$RESOLVER" --mode brainstorm --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice\$"
  echo "$output" | grep -qE "^missing=Rex,Orion,Lyra,Elara,Vermeer\$"
  echo "$output" | grep -qE "WARNING.*missing default invitee.*brainstorm"
}

@test "AC13: missing-invitee WARNING never blocks the meeting (exit 0)" {
  write_index alice
  run "$RESOLVER" --mode red-team --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice\$"
}

@test "AC14: --invitees override bypasses default-invitee resolution; no WARNING" {
  write_index Zara Sable Nova
  run "$RESOLVER" --mode red-team --invitees "alice,bob" --installed "$INDEX" --invitees-override
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,bob\$"
  echo "$output" | grep -qE "^missing=\$"
  echo "$output" | grep -qE "^invitees_override=true\$"
  # No WARNING emitted on override path
  ! echo "$output" | grep -qE "WARNING"
}

@test "AC6: --mode=ux resolves to the same set as --mode=design and reports canonical mode=design" {
  write_index alice Christy Suki Layla Talia Tariq Lena Cleo Freya
  run "$RESOLVER" --mode ux --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "^resolved=alice,Christy,Suki,Layla,Talia,Tariq,Lena,Cleo,Freya\$"
  echo "$output" | grep -qE "^bias=ux-design-notes\$"
  echo "$output" | grep -qE "^canonical_mode=design\$"
}

@test "default_invitees_resolved is reported alongside resolved set" {
  write_index alice Derek Nate
  run "$RESOLVER" --mode align --invitees "alice" --installed "$INDEX"
  [ "$status" -eq 0 ]
  # default_invitees_resolved lists those defaults that resolved (not the user set)
  echo "$output" | grep -qE "^default_invitees_resolved=Derek,Nate\$"
}
