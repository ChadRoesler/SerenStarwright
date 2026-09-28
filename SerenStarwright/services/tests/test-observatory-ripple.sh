#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The Observatory card: receiving a ripple.
#
#  Design note: the hippocampus moves to the Nano and the model lives
#  on the desktop, so a ripple has to cross boxes - the Nano POSTs it to the
#  desktop's Observatory, which starts the command AS the person. Proves:
#    - --describe offers --ripple (a switch), --ripple-command, --ripple-run-as
#    - with --ripple the card appends an enabled ripple block whose run_as is
#      the person running the install, and whose command defaults to claude
#    - --ripple-run-as / --ripple-command override them, quoting intact
#    - without --ripple nothing is written (keep-config keeps an old block)
#
#  Run:  bash services/tests/test-observatory-ripple.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-observatory-setup.sh"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

PYY=""
for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PYY="$c"; break; }; done
[[ -n "$PYY" ]] || bad "no Python with PyYAML on PATH - these checks parse the card's YAML (pip install pyyaml)"

echo "== --describe"
d="$(bash "$CARD" --describe)"
for f in ripple ripple-command ripple-run-as; do
  grep -q "\"$f\"" <<<"$d" && ok_ "offers --$f" || bad "--describe is missing --$f"
done
grep -q '"switches":\[[^]]*"ripple"' <<<"$d" && ok_ "--ripple is a switch (a checkbox in the TUI)" || bad "--ripple is not a switch"

echo "== the ripple block"
render() {   # render VAR=value ... ; prints the config the card appends
  local body; body="$(awk '/^if \$RIPPLE; then$/{on=1} on{print} on&&/^fi$/{exit}' "$CARD")"
  : > "$T/cfg.yaml"
  env "$@" CFG_PATH="$T/cfg.yaml" bash -c "$body" && cat "$T/cfg.yaml"
}
yamlget() { "$PYY" -c "import sys, yaml; d = yaml.safe_load(sys.stdin) or {}; print(repr($1))" 2>&1; }
me="$(id -un)"
out="$(render RIPPLE=true | yamlget "d['ripple']")"
[[ "$out" == "{'enabled': True, 'command': 'claude -p \"{message}\"', 'run_as': '$me'}" ]] \
  && ok_ "--ripple: enabled, claude by default, runs as the installer ($me)" || bad "default: $out"
out="$(render RIPPLE=true RIPPLE_RUN_AS=wren RIPPLE_COMMAND="C:\\tools\\claude.exe -p \"{message}\"" | yamlget "d['ripple']")"
[[ "$out" == *"'run_as': 'wren'"* && "$out" == *'C:\\tools\\claude.exe'* ]] \
  && ok_ "--ripple-run-as and --ripple-command override, a Windows path intact" || bad "override: $out"
out="$(render RIPPLE=false | yamlget "d")"
[[ "$out" == "{}" ]] && ok_ "without --ripple nothing is written" || bad "unset: $out"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
