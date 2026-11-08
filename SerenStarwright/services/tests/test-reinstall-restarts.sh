#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  A card run over a RUNNING service restarts it onto the new code.
#
#  `systemctl enable --now` only starts a unit that is stopped: a running one
#  keeps its old process, serving the old code with the old config. Found
#  7 Nov 2026 on the NUC, where seren-soma-wren kept its hours-old process
#  through a card install of 1.0.0 and ignored the bearer the card had just
#  written. Every card upgrade of every service went through this line.
#
#  Proves, for both systemd cores (python services and .NET services):
#    - unit already active  -> enable, then RESTART, and the banner says so
#    - unit not active      -> enable --now, as before
#  Nothing real is installed: sudo and systemctl are stubs that record calls.
#  Run:  bash services/tests/test-reinstall-restarts.sh   (Linux / WSL / Git Bash)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
CORE="$HERE/services/lib/setup-seren-service.sh"
DOTNET="$HERE/services/lib/setup-seren-dotnet-service.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
# sudo: `sudo tee <unit>` keeps the unit text; every other call is recorded.
cat > "$T/bin/sudo" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == tee ]]; then cat > "$T/unit"; exit 0; fi
echo "\$*" >> "$T/sudo.log"
exit 0
SH
# systemctl (unprivileged, for is-active): answers what the test says the unit is doing.
cat > "$T/bin/systemctl" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$T/systemctl.log"
if [[ "\${1:-}" == is-active ]]; then [[ -f "$T/ACTIVE" ]] && exit 0 || exit 3; fi
exit 0
SH
chmod +x "$T/bin/sudo" "$T/bin/systemctl"

run_core() {   # run_core <python|dotnet> <active|stopped>
  local which="$1" state="$2"
  rm -f "$T/sudo.log" "$T/systemctl.log" "$T/unit" "$T/ACTIVE"
  [[ "$state" == active ]] && : > "$T/ACTIVE"
  local H="$T/home-$which-$state"
  if [[ "$which" == python ]]; then
    mkdir -p "$H/seren-x" "$H/venvs/x/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$H/venvs/x/bin/python"; chmod +x "$H/venvs/x/bin/python"
    : > "$H/seren-x/x.yaml"
    HOME="$H" PATH="$T/bin:$PATH" bash "$CORE" --service-name seren-x --module seren_x \
      --venv "$H/venvs/x" --app-dir "$H/seren-x" --config "$H/seren-x/x.yaml" --no-health-check >"$T/out" 2>&1
  else
    mkdir -p "$H/deploy"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$H/deploy/App"; chmod +x "$H/deploy/App"
    HOME="$H" PATH="$T/bin:$PATH" bash "$DOTNET" --service-name seren-x --exec-name App --deploy-dir "$H/deploy" \
      --no-publish --no-deploy --no-health-check >"$T/out" 2>&1
  fi
}

for which in python dotnet; do
  echo "== $which core, unit already running"
  run_core "$which" active
  if [[ ! -f "$T/sudo.log" ]]; then bad "the $which core made no sudo calls at all: $(head -c 400 "$T/out")"; continue; fi
  grep -qx 'systemctl restart seren-x' "$T/sudo.log" && ok_ "restarted onto the new code" || bad "no restart; sudo saw: $(tr '\n' ';' < "$T/sudo.log")"
  grep -qx 'systemctl enable seren-x' "$T/sudo.log" && ok_ "still enabled" || bad "not enabled"
  grep -q 'enable --now' "$T/sudo.log" && bad "enable --now on a running unit (it would have done nothing)" || ok_ "no enable --now on a running unit"
  grep -q 'RESTARTED' "$T/out" && ok_ "the banner says it restarted" || bad "the banner is silent about the restart"

  echo "== $which core, unit not running"
  run_core "$which" stopped
  grep -qx 'systemctl enable --now seren-x' "$T/sudo.log" && ok_ "enable --now starts a stopped unit, as before" || bad "no enable --now; sudo saw: $(tr '\n' ';' < "$T/sudo.log" 2>/dev/null)"
  grep -q 'systemctl restart' "$T/sudo.log" && bad "a restart of a unit that was not running" || ok_ "no needless restart"
done

echo
echo "  $PASS passed, $FAILS failed"
[[ $FAILS -eq 0 ]]
