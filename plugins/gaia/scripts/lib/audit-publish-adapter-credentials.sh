#!/usr/bin/env bash
# audit-publish-adapter-credentials.sh — pre-flight credential audit per SR-76 + NFR-081.
#
# Runs the SR-76 deny-list scan against a resolved publish-adapter directory.
# Used by /gaia-publish Step 1 to refuse to invoke run.sh on audit FAIL.
#
# Usage: audit-publish-adapter-credentials.sh <adapter-dir>
# Exit codes:
#   0 — audit passed
#   1 — audit failed (canonical stderr "HALT: adapter credential audit failed — undeclared credential source")

set -euo pipefail
LC_ALL=C
export LC_ALL

prog="$(basename "$0")"
err() { printf '%s: %s\n' "$prog" "$*" >&2; }

[ $# -eq 1 ] || { err "usage: $prog <adapter-dir>"; exit 2; }
ADAPTER_DIR="$1"
[ -d "$ADAPTER_DIR" ] || { err "adapter dir not found: $ADAPTER_DIR"; exit 2; }

# SR-76 deny-list — ambient credential reads adapters MUST NOT perform.
# Each pattern requires CONSUMING context (read|cat|source|.|stat|test/-f|etc.)
# OR is a CLI-tool invocation that reads ambient creds. Mere mention of a path
# in an error-message string ("refuses to fall back to ~/.npmrc per NFR-081")
# is INTENTIONAL refusal language and MUST NOT trip the audit.
DENY_PATTERNS=(
  # File reads via shell operators: cat <path>, source <path>, . <path>,
  # < <path>, < "<path>", redirected reads, conditional file tests.
  '(cat|source|read|\.|<<<|<|test|-[fde])[[:space:]]+["'\'']*[~$]?(/?HOME)?/?\.(npmrc|pypirc|aws/|docker/config\.json|gitconfig|netrc)'
  # CLI-tool invocations that read ambient credentials. Each pattern requires
  # invocation context (at line start, after `;`/`|`/`&`/`$(`/`=`/backtick)
  # so prose-mention inside string literals does not trip the audit.
  '(^|[;|&=`(\$])[[:space:]]*security[[:space:]]+find-internet-password'
  '(^|[;|&=`(\$])[[:space:]]*aws[[:space:]]+configure'
  '(^|[;|&=`(\$])[[:space:]]*gcloud[[:space:]]+auth'
  '(^|[;|&=`(\$])[[:space:]]*keychain[[:space:]]'
)

# Scan adapter source files (sh/py/js/yaml) for any deny-list pattern.
violations=""
for f in "$ADAPTER_DIR"/*.sh "$ADAPTER_DIR"/*.py "$ADAPTER_DIR"/*.js \
         "$ADAPTER_DIR"/*.yaml "$ADAPTER_DIR"/*.yml \
         "$ADAPTER_DIR"/providers/*.sh; do
  [ -f "$f" ] || continue
  for pat in "${DENY_PATTERNS[@]}"; do
    if grep -E "$pat" "$f" 2>/dev/null | grep -v '^[[:space:]]*#' | grep -q .; then
      violations="${violations}$f: matched deny-list pattern '$pat'"$'\n'
    fi
  done
done

if [ -n "$violations" ]; then
  err "HALT: adapter credential audit failed — undeclared credential source"
  err "$violations"
  exit 1
fi

exit 0
