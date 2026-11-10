#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-kitchen-setup.sh: the kitchen's card. Proves:
#    - --describe: group auxiliary, port 7431, loopback by default, accent
#      #e0514b (the values seren_kitchen/_describe.py carries), requires and
#      recommends nothing, no secrets (the GitHub token travels as an env
#      var's NAME), every flag says where it lives in the config
#    - its twin, seren-kitchen-setup.ps1, describes the same card (when a
#      PowerShell is on this box)
#    - setup-kitchen-service.sh under a root: unit seren-kitchen-home running
#      seren_kitchen with its config, the manifest in <root>/manifests
#  Nothing real is installed: sudo is a stub that keeps the unit text.
#  Run:  bash services/tests/test-kitchen-card.sh   (Linux / WSL / Git Bash)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-kitchen-setup.sh"
TWIN="$HERE/services/powershell/seren-kitchen-setup.ps1"
WRAP="$HERE/services/bash/setup-kitchen-service.sh"
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
check "group auxiliary, port 7431, package seren-kitchen" \
  "[[ \$(field 'd[\"group\"]') == '\"auxiliary\"' && \$(field 'd[\"default_port\"]') == 7431 && \$(field 'd[\"package\"]') == '\"seren-kitchen\"' ]]"
check "loopback by default" "[[ \$(field 'd[\"default_host\"]') == '\"127.0.0.1\"' ]]"
check "accent #e0514b" "[[ \$(field 'd[\"accent\"]') == '\"#e0514b\"' ]]"
check "requires and recommends nothing" \
  "[[ \$(field 'd[\"recommends\"]') == '[]' && \$(field 'd[\"requires\"]') == '[]' ]]"
check "no secrets: the GitHub token is the NAME of an env var" "[[ \$(field 'd[\"secrets\"]') == '{}' ]]"
check "it says where each flag lives in its config" \
  "[[ \$(field 'd[\"config_keys\"][\"font-hand\"]') == '\"fonts.hand\"' && \$(field 'd[\"config_keys\"][\"github-token-env\"]') == '\"github.token_env\"' && \$(field 'd[\"config_keys\"][\"sour-days\"]') == '\"sour_after_days\"' ]]"
check "no pip extras" "[[ \$(field 'd[\"extras\"]') == '[]' ]]"
for f in host port token state-dir font-name font-freezer font-hand github-token-env github-interval sour-days local wheel ref repo instance root venv no-updates; do
  check "flag --$f is advertised" "[[ \$(field '\"$f\" in d[\"flags\"]') == true ]]"
done

echo "== the package says the same"
PKG="$(d="$HERE"; while [[ "$d" != "/" ]]; do [[ -f "$d/SerenKitchen/SerenKitchen/seren_kitchen/_describe.py" ]] && { echo "$d/SerenKitchen/SerenKitchen/seren_kitchen/_describe.py"; break; }; d="$(dirname "$d")"; done)"
if [[ -n "$PKG" ]]; then
  check "_describe.py carries PORT = 7431" "grep -Eq '^PORT = 7431' \"$PKG\""
  check "_describe.py carries ACCENT = \"#e0514b\"" "grep -Eq '^ACCENT = \"#e0514b\"' \"$PKG\""
else
  echo "  skip no SerenKitchen checkout beside this repo"
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

echo "== setup-kitchen-service.sh under a root"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/sudo" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" == tee ]] && cat > "$T/unit"
exit 0
SH
chmod +x "$T/bin/sudo"
H="$T/home"; R="$H/seren/home"
mkdir -p "$R/apps/kitchen" "$R/venvs/kitchen/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/venvs/kitchen/bin/python"; chmod +x "$R/venvs/kitchen/bin/python"
: > "$R/apps/kitchen/seren-kitchen.yaml"
: > "$R/apps/kitchen/seren-kitchen.env"     # the installer writes it when a bearer was given; the core wires it only when it exists
out="$(HOME="$H" PATH="$T/bin:$PATH" bash "$WRAP" --app-dir "$R/apps/kitchen" --venv "$R/venvs/kitchen" --instance -home 2>&1)"
check "it runs seren_kitchen with its config" "grep -q 'seren_kitchen --config' \"$T/unit\""
check "the bearer and the GitHub token ride in an env file, not the unit" "grep -q '^EnvironmentFile=.*seren-kitchen.env' \"$T/unit\" && ! grep -q 'TOKEN=' \"$T/unit\""
check "PYTHONUTF8 for the log" "grep -q 'PYTHONUTF8=1' \"$T/unit\""
check "manifest in the root's roster: seren-kitchen-home.json" "[[ -f \"$R/manifests/seren-kitchen-home.json\" ]]"

echo
echo "$PASS passed, $FAILS failed"
exit "$FAILS"
