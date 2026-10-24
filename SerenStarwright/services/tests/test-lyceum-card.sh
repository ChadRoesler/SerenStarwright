#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The Lyceum card: a unit that leaves the trainer alone.
#
#  The Lyceum forks its trainer, detached, into the service's own cgroup.
#  systemd's default KillMode stops the whole cgroup, so restarting the
#  service would kill a run mid-epoch. Its wrapper asks the core for
#  KillMode=process, and no MemoryMax (that limit is the cgroup's, and the
#  trainer in it holds a model).
#
#  Proves:
#    - setup-lyceum-service.sh under a root: unit seren-lyceum-wren with
#      KillMode=process and no MemoryMax, its manifest in <root>/manifests
#    - the core without --kill-mode writes no KillMode line (every other
#      service is unchanged)
#    - --describe: the name, port, group and accent the package carries
#
#  Nothing real is installed: sudo is a stub that keeps the unit text.
#  Run:  bash services/tests/test-lyceum-card.sh   (Linux / WSL / Git Bash)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
WRAP="$HERE/services/bash/setup-lyceum-service.sh"
CARD="$HERE/services/bash/seren-lyceum-setup.sh"
CORE="$HERE/services/lib/setup-seren-service.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/sudo" <<SH
#!/usr/bin/env bash
# \`sudo tee <unit>\` keeps the unit text where the test can read it.
[[ "\${1:-}" == tee ]] && cat > "$T/unit"
exit 0
SH
chmod +x "$T/bin/sudo"
fake_install() {   # fake_install APP_DIR VENV_DIR
  mkdir -p "$1" "$2/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$2/bin/python"; chmod +x "$2/bin/python"
  : > "$1/seren-lyceum.yaml"
}

echo "== setup-lyceum-service.sh under a root"
H="$T/home"; R="$H/seren/wren"
fake_install "$R/apps/lyceum" "$R/venvs/lyceum"
out="$(HOME="$H" PATH="$T/bin:$PATH" bash "$WRAP" --app-dir "$R/apps/lyceum" --venv "$R/venvs/lyceum" --instance -wren 2>&1)"
grep -q '^KillMode=process$' "$T/unit" && ok_ "KillMode=process: a restart leaves the trainer running" \
                                       || bad "no KillMode=process in the unit: $(cat "$T/unit" 2>/dev/null) $out"
grep -q '^MemoryMax=' "$T/unit" && bad "a MemoryMax would fence the trainer too" || ok_ "no MemoryMax"
grep -q 'seren_lyceum --config' "$T/unit" && ok_ "it runs seren_lyceum with its config" || bad "ExecStart is not seren_lyceum"
[[ -f "$R/manifests/seren-lyceum-wren.json" ]] && ok_ "manifest in the root's roster: seren-lyceum-wren.json" \
                                               || bad "no manifest at $R/manifests/seren-lyceum-wren.json"

echo "== the core, asked for nothing"
rm -f "$T/unit"
fake_install "$H/seren-memory" "$H/seren-venvs/memory"
HOME="$H" PATH="$T/bin:$PATH" bash "$CORE" --service-name seren-memory --module seren_memory \
  --venv "$H/seren-venvs/memory" --app-dir "$H/seren-memory" --config "$H/seren-memory/seren-lyceum.yaml" \
  --no-health-check >/dev/null 2>&1
grep -q 'KillMode' "$T/unit" && bad "a KillMode line nobody asked for" || ok_ "no --kill-mode: no KillMode line"
grep -q '^MemoryMax=2G$' "$T/unit" && ok_ "...and the default MemoryMax stays" || bad "the default MemoryMax went missing"

echo "== --describe"
d="$(bash "$CARD" --describe)"
for want in '"name":"seren-lyceum"' '"default_port":7428' '"group":"auxiliary"' '"accent":"#a17056"' \
            '"recommends":["seren-hippocampus"]' '"hippocampus-token":"SEREN_HIPPOCAMPUS_TOKEN"'; do
  grep -qF "$want" <<<"$d" && ok_ "describe says $want" || bad "describe lacks $want: $d"
done

echo
echo "  $PASS passed, $FAILS failed"
[[ $FAILS -eq 0 ]]
