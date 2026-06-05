---
name: gaia-shell-idioms
description: Reusable shell and awk idioms for GAIA scripts and bats tests. Captures recurring anti-patterns (like the awk range-bug) and the canonical state-machine fixes. Reference-only skill — loaded by authors writing new scripts or tests.
allowed-tools: [Read, Grep]
orchestration_class: light-procedural
---

## About

Project convention doc for small shell and awk idioms that have bitten the codebase more than once. Each idiom is presented as a pair: the broken form (and why it fails) followed by the state-machine fix (and a short runnable example).

This skill is prose-only — it documents conventions but does not execute anything. Authors reading this skill should apply the idiom directly in scripts under `gaia-framework/plugins/gaia/scripts/` and in bats tests under `gaia-framework/tests/`.

- Native execution model; this skill is consumed directly by the Skills runtime.
- Scripts-over-LLM for deterministic operations; the idioms here are the canonical shell-side implementations.

> **Scope:** GNU awk / POSIX awk / mawk. All examples are POSIX-compatible unless noted.

<!-- SECTION: awk-range-bug -->
## awk Range Bug — `/start/,/end/` Terminates at the Start Line

### The Broken Idiom

The classic awk range expression `/start/,/end/` selects every line from a line matching `/start/` up to and including the next line matching `/end/`. That works beautifully when the two patterns are disjoint. It **breaks silently** when both patterns can match the **same line** — the range opens and closes on that one line, and every subsequent line is dropped.

Concrete failure case: printing the body of a markdown section up to the next same-level heading.

```bash
# BROKEN — returns only the first "## Foo" line, not the section body.
# Both /^## Foo/ and /^## / match the heading line itself, so the range
# opens at "## Foo" and immediately closes on the same line.
awk '/^## Foo/,/^## /' README.md
```

### Why It Fails

The awk range `expr1,expr2` is a two-state toggle: once `expr1` matches a line, the range is "on" starting with that line. On every subsequent line (including the line that flipped the range on), awk re-evaluates `expr2`. If `expr2` matches the same line that `expr1` matched, the range flips back off on that one line — so only the start line is printed. `expr2` is not deferred to the next line; it is checked on the current line after `expr1` fires.

This bug has recurred **3 times** across this codebase — once in `verify-cluster-gates.sh`, once in section-scoped bats greps, and again in the section-queries for the migration guide tests. Codifying the fix here is the remediation.

### The State-Machine Fix

Replace the range expression with an explicit flag that is set when the start pattern matches and cleared when the end pattern matches. The key move is `flag && /end/{flag=0}` — the end check fires **only after** the flag is already on, so it cannot close the range on the same line that opened it.

```bash
# FIXED — prints the body of the "## Foo" section up to (but not including)
# the next "## " heading. The start line itself is skipped with `next`.
awk '
  /^## Foo/        { flag = 1; next }
  flag && /^## /   { flag = 0 }
  flag
' README.md
```

The three-line form generalises to any start/end pair that can collide on a single line:

```awk
/<start>/        { flag = 1; next }   # open the range (skip the start line)
flag && /<end>/  { flag = 0 }         # close only after the range is open
flag                                  # print lines while the flag is on
```

If the start line itself should be included in the output, drop the trailing `next` from the first rule and print the line before setting the flag:

```awk
/<start>/        { print; flag = 1; next }
flag && /<end>/  { flag = 0 }
flag
```

### Canonical Uses in This Codebase

- YAML frontmatter extraction (first pair of `---` delimiters only):

  ```awk
  /^---$/{n++; next} n==1{print}
  ```

  Seen in every `tests/skills/*.bats` frontmatter check and in `tests/cluster-13-parity/*.bats`.

- Markdown section extraction up to the next same-level heading (the recurring case above):

  ```awk
  /^## .*X/{flag=1; next} flag && /^## /{flag=0} flag
  ```

- Dropping a trailing section (e.g., everything after `## References`):

  ```awk
  /^## References/ { in_refs = 1 } !in_refs { print }
  ```

### Review Checklist

When reviewing a script or bats test, flag any occurrence of `awk '/start/,/end/'` where **both** regexes could match a single line. The fix is mechanical — rewrite it with the three-line state machine above.

<!-- SECTION: frontmatter-extraction -->
## YAML Frontmatter Extraction

### The Idiom

Markdown files in this repo carry YAML frontmatter between the first pair of `---` delimiters. A naive `sed -n '/^---$/,/^---$/p'` or `awk '/^---$/,/^---$/'` hits the range-bug above the moment the file contains a third `---` (for example, a horizontal rule inside the body).

### The Fix

Count delimiter hits and print only while the counter is exactly 1:

```awk
BEGIN { in_fm = 0; seen = 0 }
/^---[[:space:]]*$/ {
  if (seen == 0) { in_fm = 1; seen = 1; next }
  else if (in_fm == 1) { in_fm = 0; exit }
}
in_fm == 1 { print }
```

This is the `_frontmatter` helper used by `tests/cluster-15-parity/E28-S112-core-dev-skills-parity.bats` and by the newer skill-parity bats tests.

<!-- SECTION: awk-word-boundaries -->
## awk Word-Boundary Anchors — `\<...\>` Is Not Portable

### The Broken Idiom

GNU awk supports the word-boundary anchors `\<` (start of word) and `\>` (end of word). **mawk** and **BSD awk** (the awk shipped with macOS) do not — under those implementations the regex is silently treated as something else, producing false negatives. The match never fires, the script reports "not found", and the failure is invisible until someone runs the same code on macOS or in a mawk-based CI image.

### The Portable Fix

Anchor on a non-alphanumeric neighbour or beginning/end-of-line instead. The replacement form `(^|[^A-Za-z0-9])TOKEN([^A-Za-z0-9]|$)` is accepted by GNU awk, mawk, and BSD awk identically:

```awk
# BROKEN — passes on Linux CI (gawk), silently fails on macOS (BSD awk / mawk).
$0 ~ /\<NPS\>/ { found = 1 }

# FIXED — identical behaviour across gawk, mawk, and BSD awk.
$0 ~ /(^|[^A-Za-z0-9])NPS([^A-Za-z0-9]|$)/ { found = 1 }
```

### Review Checklist

When reviewing a script or bats test, flag any `\<` or `\>` inside an awk regex. The fix is mechanical — substitute the character-class form. The regression guard `tests/no-bsd-awk-incompatible-anchors.bats` enforces this across `scripts/`, `tests/`, and `skills/*/scripts/`.

<!-- SECTION: safe-grep-log -->
## `safe_grep_log` — SIGPIPE-Safe `git log | grep` Replacement

### The Broken Idiom

```bash
set -euo pipefail
if git log --oneline main | grep -iqE "\b${STORY_KEY}\b"; then
  echo "found"
fi
```

Looks fine. **Breaks** the moment `grep -q` matches: grep exits 0 and closes the pipe; `git log` then receives SIGPIPE and exits 141; with `pipefail` the pipeline's overall status is 141; `set -e` aborts the caller — even though the user-visible outcome was "match found". Symptom is the same when the grep pattern is regex-heavy and grep terminates after the first hit.

### Why It Fails

Three things have to line up: (1) `set -e` is on, (2) `pipefail` is on, (3) grep early-exits while git is still streaming. The recurring workaround was to capture `git log` into a variable first, then grep the variable — turning the long-lived producer into a short-lived `printf '%s\n' "$var"` that cannot SIGPIPE. The capture pattern was duplicated in `verify-pr-merged.sh` (twice) and was a foreseeable second-occurrence in any new `git log | grep` site.

### The Fix — Source `shell-idioms.sh` and Call `safe_grep_log`

```bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib" && pwd)/shell-idioms.sh"

if safe_grep_log -i -q -E "\b${STORY_KEY}\b" --oneline "$TARGET"; then
  log "merge commit found"
fi
```

### Signature

```
safe_grep_log [grep_flags...] <pattern> [git_log_args...]
```

- Leading args starting with `-` are forwarded to grep (`-i`, `-q`, `-E`, etc.).
- The first non-flag arg is the grep pattern.
- Remaining args are forwarded to `git log` (`--oneline`, a branch name, `--format='%B'`, etc.).
- Exit 0 = match, exit 1 = no-match (clean), exit 2 = usage error.

### Strict-Mode Caller Pattern

Because `safe_grep_log` returns 1 on no-match (correctly), callers under `set -e` must guard the call — exactly as you would for `grep` itself:

```bash
# Use `if`:
if safe_grep_log "$pattern" --oneline "$branch"; then ...; fi

# Or `|| true` when the result is irrelevant:
safe_grep_log "$pattern" --oneline "$branch" || true
```

### Canonical Uses in This Codebase

- `plugins/gaia/skills/gaia-dev-story/scripts/verify-pr-merged.sh` — both the primary `--oneline` check and the `--format='%B'` fallback.

### Review Checklist

When reviewing a script, flag any occurrence of `git log ... | grep` (or `git log ... | grep -q`) under `set -euo pipefail`. The fix is mechanical — source `shell-idioms.sh` and replace with `safe_grep_log`. Do not re-introduce the inline capture-then-grep workaround.

<!-- SECTION: review-notes -->
## Review Notes

- Prefer an explicit `flag` state machine over range expressions whenever the start/end patterns share any overlap. The range form is only safe when the two patterns are provably disjoint.
- Always use `next` after the start rule fires (unless you want the start line itself in the output) so the end rule cannot evaluate against the same line.
- Keep the flag check (`flag && /end/`) ahead of the print rule so the end line is not printed.
- For bats tests, this idiom is preferred over piping to `sed` or `grep -A`/`-B` with magic line counts — those are fragile when section bodies grow.

## References

- First recurrence in `verify-cluster-gates.sh`.
- Second recurrence, documented state-machine fix.
- Third recurrence; triage finding promoted to a fix story.
- `set -euo pipefail` + `git log | grep` SIGPIPE workaround documented inline; later extracted `safe_grep_log()` into `scripts/lib/shell-idioms.sh` and migrated both call sites in `verify-pr-merged.sh`.
