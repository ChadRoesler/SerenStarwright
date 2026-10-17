#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-symposium-setup.sh: the desktop front door's card. Proves:
#    - --describe: group desktop, port 7426, recommends Lodestar and requires
#      nothing, voice is a dropdown (lodestar|claude), no-window and
#      no-shortcut are switches, every flag the TUI needs is advertised
#    - its twin, seren-symposium-setup.ps1, describes the same card (when
#      a PowerShell is on this box)
#    - a voice that is neither is refused before anything is installed
#  The full run (config, keep-config on reinstall, the locked file) is
#  proved against the real card in verify-powershell.ps1; a bash install
#  needs a POSIX venv, which Git Bash on Windows does not make.
#  Run:  bash services/tests/test-symposium-card.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-symposium-setup.sh"
TWIN="$HERE/services/powershell/seren-symposium-setup.ps1"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check() { local what="$1" expr="$2"; if eval "$expr" >/dev/null 2>&1; then ok_ "$what"; else bad "$what"; fi; }
PY=""; for c in python3 python; do "$c" -c 'import json' >/dev/null 2>&1 && { PY="$(command -v $c)"; break; }; done
[[ -n "$PY" ]] || { echo "no python"; exit 1; }

echo "== --describe"
D="$(bash "$CARD" --describe)"
field() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2], {}, {"d": d})))' "$D" "$1"; }
check "valid JSON" "[[ -n \"\$(field 'd[\"name\"]')\" ]]"
check "group desktop, port 7426, package seren-symposium" \
  "[[ \$(field 'd[\"group\"]') == '\"desktop\"' && \$(field 'd[\"default_port\"]') == 7426 && \$(field 'd[\"package\"]') == '\"seren-symposium\"' ]]"
check "recommends Lodestar, requires nothing" \
  "[[ \$(field 'd[\"recommends\"]') == '[\"seren-lodestar\"]' && \$(field 'd[\"requires\"]') == '[]' ]]"
check "voice is a dropdown of lodestar and claude" "[[ \$(field 'd[\"choices\"][\"voice\"]') == '[\"lodestar\", \"claude\"]' ]]"
check "no-window and no-shortcut are switches" \
  "[[ \$(field '\"no-window\" in d[\"switches\"] and \"no-shortcut\" in d[\"switches\"]') == true ]]"
check "no-autostart is a switch (the tray at login is the default)" "[[ \$(field '\"no-autostart\" in d[\"switches\"]') == true ]]"
check "startup-dir takes a value and no-start-now is a switch (the harness seams, same as the twin's)"   "[[ \$(field '\"startup-dir\" in d[\"flags\"] and \"startup-dir\" not in d[\"switches\"] and \"no-start-now\" in d[\"switches\"]') == true ]]"
check "it says where each flag lives in its config"   "[[ \$(field 'd[\"config_keys\"][\"claude-name\"]') == '\"claude.name\"' && \$(field 'd[\"config_keys\"][\"lodestar-token\"]') == '\"lodestar.bearer_token\"' ]]"
check "the only pick-list extra is corp ([desktop] rides on --no-window)" "[[ \$(field 'd[\"extras\"]') == '[\"corp\"]' ]]"
for f in host port lodestar-config lodestar-url voice claude-name claude-cwd claude-tools local wheel ref repo instance root venv no-updates corp; do
  check "flag --$f is advertised" "[[ \$(field '\"$f\" in d[\"flags\"]') == true ]]"
done

echo "== its PowerShell twin"
PS=""; for c in pwsh powershell.exe; do command -v "$c" >/dev/null 2>&1 && { PS="$c"; break; }; done
if [[ -z "$PS" ]]; then
  echo "  skip no PowerShell here"
else
  W="$("$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$TWIN" 2>/dev/null || echo "$TWIN")" -Describe | tr -d '\r')"
  same() { "$PY" -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); k=sys.argv[3]; sys.exit(0 if a[k]==b[k] else 1)' "$D" "$W" "$1"; }
  for k in name group default_port default_host recommends requires extras accent config_keys flags switches; do
    check "both twins agree on $k" "same $k"
  done
  check "both offer the same voices" "$PY -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); sys.exit(0 if a[\"choices\"][\"voice\"]==b[\"choices\"][\"voice\"] else 1)' \"\$D\" \"\$W\""
fi

echo "== refusals, before anything is installed"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
OUT="$(bash "$CARD" --voice robot --root "$T/root" 2>&1)"; RC=$?
check "--voice robot is refused" "[[ $RC -ne 0 ]] && grep -q 'lodestar or claude' <<<\"\$OUT\""
check "...and nothing was installed" "[[ ! -e \"$T/root/venvs\" ]]"

echo
echo "$PASS passed, $FAILS failed"
exit "$FAILS"
