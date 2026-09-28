#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The Lodestar card: routing a ripple (28 Sept 2026).
#
#  With a Lodestar the hippocampus needs one address and one token; Lodestar
#  knows where the model lives. Proves:
#    - --describe offers --ripple-target / --ripple-command / --ripple-run-as
#    - a node target writes only the target (its Observatory's config runs it)
#    - local writes the command (claude by default) and run_as (the installer)
#    - no --ripple-target writes nothing (keep-config keeps an old block)
#
#  Run:  bash services/tests/test-lodestar-ripple.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-lodestar-setup.sh"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PYY=""
for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PYY="$c"; break; }; done
[[ -n "$PYY" ]] || bad "no Python with PyYAML on PATH - these checks parse the card's YAML (pip install pyyaml)"

d="$(bash "$CARD" --describe)"
for f in ripple-target ripple-command ripple-run-as; do
  grep -q "\"$f\"" <<<"$d" && ok_ "--describe offers --$f" || bad "--describe is missing --$f"
done

render() {
  local body; body="$(awk '/^if \[\[ -n "\$RIPPLE_TARGET" \]\]; then$/{on=1} on{print} on&&/^fi$/{exit}' "$CARD")"
  : > "$T/cfg.yaml"
  env "$@" CFG_PATH="$T/cfg.yaml" bash -c "$body" && cat "$T/cfg.yaml"
}
yamlget() { "$PYY" -c "import sys, yaml; d = yaml.safe_load(sys.stdin) or {}; print(repr($1))" 2>&1; }
me="$(id -un)"
out="$(render RIPPLE_TARGET=desktop | yamlget "d['ripple']")"
[[ "$out" == "{'target': 'desktop'}" ]] && ok_ "a node target writes only the target" || bad "node: $out"
out="$(render RIPPLE_TARGET=local | yamlget "d['ripple']")"
[[ "$out" == "{'target': 'local', 'command': 'claude -p \"{message}\"', 'run_as': '$me'}" ]] \
  && ok_ "local: claude by default, run as the installer ($me)" || bad "local: $out"
out="$(render RIPPLE_TARGET="" | yamlget "d")"
[[ "$out" == "{}" ]] && ok_ "no --ripple-target writes nothing" || bad "unset: $out"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
