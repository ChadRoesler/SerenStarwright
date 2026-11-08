#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-psycheion-setup.sh: the mind's workshop's card. Proves:
#    - --describe: group auxiliary, port 7429, loopback by default, accent
#      #f2aeb1 (the values seren_psycheion/_describe.py carries), recommends
#      Soma and requires nothing, no secrets (the body's tokens are POINTERS
#      to files), every flag says where it lives in the config
#    - its twin, seren-psycheion-setup.ps1, describes the same card (when a
#      PowerShell is on this box)
#    - setup-psycheion-service.sh under a root: unit seren-psycheion-wren
#      running seren_psycheion with its config, the manifest in <root>/manifests
#  Nothing real is installed: sudo is a stub that keeps the unit text.
#  Run:  bash services/tests/test-psycheion-card.sh   (Linux / WSL / Git Bash)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-psycheion-setup.sh"
TWIN="$HERE/services/powershell/seren-psycheion-setup.ps1"
WRAP="$HERE/services/bash/setup-psycheion-service.sh"
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
check "group auxiliary, port 7429, package seren-psycheion" \
  "[[ \$(field 'd[\"group\"]') == '\"auxiliary\"' && \$(field 'd[\"default_port\"]') == 7429 && \$(field 'd[\"package\"]') == '\"seren-psycheion\"' ]]"
check "loopback by default" "[[ \$(field 'd[\"default_host\"]') == '\"127.0.0.1\"' ]]"
check "accent #f2aeb1" "[[ \$(field 'd[\"accent\"]') == '\"#f2aeb1\"' ]]"
check "recommends Soma, requires nothing" \
  "[[ \$(field 'd[\"recommends\"]') == '[\"seren-soma\"]' && \$(field 'd[\"requires\"]') == '[]' ]]"
check "no secrets: the body's tokens are pointers to files" "[[ \$(field 'd[\"secrets\"]') == '{}' ]]"
check "it says where each flag lives in its config" \
  "[[ \$(field 'd[\"config_keys\"][\"robot-url\"]') == '\"soma.robot.url\"' && \$(field 'd[\"config_keys\"][\"voice-token-file\"]') == '\"soma.voice.token_file\"' ]]"
check "no pip extras" "[[ \$(field 'd[\"extras\"]') == '[]' ]]"
for f in host port token soma-config robot-url robot-token-file voice-url voice-token-file local wheel ref repo instance root venv no-updates; do
  check "flag --$f is advertised" "[[ \$(field '\"$f\" in d[\"flags\"]') == true ]]"
done

echo "== the package says the same"
PKG="$(d="$HERE"; while [[ "$d" != "/" ]]; do [[ -f "$d/SerenPsycheion/SerenPsycheion/seren_psycheion/_describe.py" ]] && { echo "$d/SerenPsycheion/SerenPsycheion/seren_psycheion/_describe.py"; break; }; d="$(dirname "$d")"; done)"
if [[ -n "$PKG" ]]; then
  check "_describe.py carries PORT = 7429" "grep -Eq '^PORT = 7429' \"$PKG\""
  check "_describe.py carries ACCENT = \"#f2aeb1\"" "grep -Eq '^ACCENT = \"#f2aeb1\"' \"$PKG\""
else
  echo "  skip no SerenPsycheion checkout beside this repo"
fi

echo "== its PowerShell twin"
PS=""; for c in pwsh powershell.exe; do command -v "$c" >/dev/null 2>&1 && { PS="$c"; break; }; done
if [[ -z "$PS" ]]; then
  echo "  skip no PowerShell here"
else
  W="$("$PS" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$TWIN" 2>/dev/null || echo "$TWIN")" -Describe | tr -d '\r')"
  same() { "$PY" -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); k=sys.argv[3]; sys.exit(0 if a[k]==b[k] else 1)' "$D" "$W" "$1"; }
  for k in name group default_port default_host recommends requires extras accent secrets config_keys flags switches; do
    check "both twins agree on $k" "same $k"
  done
fi

echo "== setup-psycheion-service.sh under a root"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/sudo" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" == tee ]] && cat > "$T/unit"
exit 0
SH
chmod +x "$T/bin/sudo"
H="$T/home"; R="$H/seren/wren"
mkdir -p "$R/apps/psycheion" "$R/venvs/psycheion/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/venvs/psycheion/bin/python"; chmod +x "$R/venvs/psycheion/bin/python"
: > "$R/apps/psycheion/seren-psycheion.yaml"
out="$(HOME="$H" PATH="$T/bin:$PATH" bash "$WRAP" --app-dir "$R/apps/psycheion" --venv "$R/venvs/psycheion" --instance -wren 2>&1)"
check "it runs seren_psycheion with its config" "grep -q 'seren_psycheion --config' \"$T/unit\""
check "PYTHONUTF8 for the log" "grep -q 'PYTHONUTF8=1' \"$T/unit\""
check "manifest in the root's roster: seren-psycheion-wren.json" "[[ -f \"$R/manifests/seren-psycheion-wren.json\" ]]"

echo
echo "$PASS passed, $FAILS failed"
exit "$FAILS"
