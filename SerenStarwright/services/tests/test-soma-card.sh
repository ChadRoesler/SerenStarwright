#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-soma-setup.sh: the body's card. Proves:
#    - --describe: group auxiliary, port 7480 (the firmware's check-in port),
#      host 0.0.0.0 (the robot dials in over the LAN), accent #8fbf88 (the
#      same values seren_soma/_describe.py carries), recommends Lodestar and
#      requires nothing, the two secrets ride in the environment, every flag
#      says where it lives in the config, every flag the TUI needs is there
#    - its twin, seren-soma-setup.ps1, describes the same card (when a
#      PowerShell is on this box)
#    - setup-soma-service.sh under a root: unit seren-soma-wren running
#      seren_soma with its config, an env file for the bearer, PYTHONUTF8,
#      and the manifest in <root>/manifests
#  Nothing real is installed: sudo is a stub that keeps the unit text.
#  Run:  bash services/tests/test-soma-card.sh   (Linux / WSL / Git Bash)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-soma-setup.sh"
TWIN="$HERE/services/powershell/seren-soma-setup.ps1"
WRAP="$HERE/services/bash/setup-soma-service.sh"
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
check "group auxiliary, port 7480, package seren-soma" \
  "[[ \$(field 'd[\"group\"]') == '\"auxiliary\"' && \$(field 'd[\"default_port\"]') == 7480 && \$(field 'd[\"package\"]') == '\"seren-soma\"' ]]"
check "binds 0.0.0.0 by default: the robot dials in over the LAN" "[[ \$(field 'd[\"default_host\"]') == '\"0.0.0.0\"' ]]"
check "accent #8fbf88, the sweater the face wears" "[[ \$(field 'd[\"accent\"]') == '\"#8fbf88\"' ]]"
check "recommends Lodestar, requires nothing" \
  "[[ \$(field 'd[\"recommends\"]') == '[\"seren-lodestar\"]' && \$(field 'd[\"requires\"]') == '[]' ]]"
check "the robot's token and Lodestar's bearer ride in the environment" \
  "[[ \$(field 'd[\"secrets\"][\"robot-token\"]') == '\"SEREN_SOMA_ROBOT_TOKEN\"' && \$(field 'd[\"secrets\"][\"lodestar-token\"]') == '\"SEREN_LODESTAR_TOKEN\"' ]]"
check "it says where each flag lives in its config" \
  "[[ \$(field 'd[\"config_keys\"][\"robot-url\"]') == '\"robot.url\"' && \$(field 'd[\"config_keys\"][\"robot-token\"]') == '\"robot.token_file\"' && \$(field 'd[\"config_keys\"][\"voice\"]') == '\"voice\"' ]]"
check "device-from lives at robot.device_from" "[[ \$(field 'd[\"config_keys\"][\"device-from\"]') == '\"robot.device_from\"' ]]"
check "no pip extras" "[[ \$(field 'd[\"extras\"]') == '[]' ]]"
check "gen-token, pypi, service and no-updates are switches" \
  "[[ \$(field '\"gen-token\" in d[\"switches\"] and \"pypi\" in d[\"switches\"] and \"service\" in d[\"switches\"] and \"no-updates\" in d[\"switches\"]') == true ]]"
for f in host port token robot-url robot-token device-from advertise voice lodestar-url lodestar-token lodestar-config symposium-yaml state-dir local wheel ref repo instance root venv no-updates; do
  check "flag --$f is advertised" "[[ \$(field '\"$f\" in d[\"flags\"]') == true ]]"
done

echo "== the package says the same"
PKG="$(cd "$HERE/.." 2>/dev/null && find_up=1; d="$HERE"; while [[ "$d" != "/" ]]; do [[ -f "$d/SerenSoma/SerenSoma/seren_soma/_describe.py" ]] && { echo "$d/SerenSoma/SerenSoma/seren_soma/_describe.py"; break; }; d="$(dirname "$d")"; done)"
if [[ -n "$PKG" ]]; then
  check "_describe.py carries PORT = 7480" "grep -Eq '^PORT = 7480' \"$PKG\""
  check "_describe.py carries ACCENT = \"#8fbf88\"" "grep -Eq '^ACCENT = \"#8fbf88\"' \"$PKG\""
  check "_describe.py carries GROUP = \"auxiliary\"" "grep -Eq '^GROUP = \"auxiliary\"' \"$PKG\""
else
  echo "  skip no SerenSoma checkout beside this repo"
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

echo "== setup-soma-service.sh under a root"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/sudo" <<SH
#!/usr/bin/env bash
[[ "\${1:-}" == tee ]] && cat > "$T/unit"
exit 0
SH
chmod +x "$T/bin/sudo"
H="$T/home"; R="$H/seren/wren"
mkdir -p "$R/apps/soma" "$R/venvs/soma/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/venvs/soma/bin/python"; chmod +x "$R/venvs/soma/bin/python"
: > "$R/apps/soma/seren-soma.yaml"
: > "$R/apps/soma/seren-soma.env"     # the installer writes it when a bearer was given; the core wires it only when it exists
out="$(HOME="$H" PATH="$T/bin:$PATH" bash "$WRAP" --app-dir "$R/apps/soma" --venv "$R/venvs/soma" --instance -wren 2>&1)"
check "it runs seren_soma with its config" "grep -q 'seren_soma --config' \"$T/unit\""
check "the bearer rides in an env file, not the unit" "grep -q '^EnvironmentFile=.*seren-soma.env' \"$T/unit\" && ! grep -q 'BEARER' \"$T/unit\""
check "PYTHONUTF8 for the log" "grep -q 'PYTHONUTF8=1' \"$T/unit\""
check "no KillMode line (the body has no detached children)" "! grep -q 'KillMode' \"$T/unit\""
check "manifest in the root's roster: seren-soma-wren.json" "[[ -f \"$R/manifests/seren-soma-wren.json\" ]]"

echo
echo "$PASS passed, $FAILS failed"
exit "$FAILS"
