#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  Service manifests go into the install's own roster.
#
#  Chad, 27 Sept 2026: two named installs on one host each run an
#  Observatory, and every manifest went into the one ~/.seren/services - so
#  each Observatory listed, restarted and reclaimed the other's services.
#  Under a root the roster is <root>/manifests, and the observatory card
#  points its config at it (server.manifests_dir).
#
#  Proves:
#    - setup-seren-service.sh: app dir <root>/apps/<svc> + venv
#      <root>/venvs/<svc> -> <root>/manifests/<unit>.json, nothing in
#      ~/.seren/services; the old layout -> ~/.seren/services; an apps/ and a
#      venvs/ under DIFFERENT parents is not mistaken for a root
#    - both observatory cards write manifests_dir: <root>/manifests under a
#      root, and nothing without one
#    - seren-register-services.sh backfills each unit into its own root's
#      roster, and a root-less unit into ~/.seren/services
#
#  Nothing real is installed: sudo and systemctl are stubs on PATH.
#  Run:  bash services/tests/test-manifests-dir.sh   (Linux / WSL)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
eq()   { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad "$1: got [$2] want [$3]"; fi; }
CORE="$HERE/services/lib/setup-seren-service.sh"
REGISTER="$HERE/services/lib/seren-register-services.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# -- stubs: the unit write and systemctl must not touch the machine ---------
mkdir -p "$T/bin"
cat > "$T/bin/sudo" <<'SH'
#!/usr/bin/env bash
# `sudo tee <unit>` swallows the unit text; every other sudo'd call is a no-op.
[[ "${1:-}" == tee ]] && cat >/dev/null
exit 0
SH
chmod +x "$T/bin/sudo"

# A fake install: <parent>/apps/<svc> and <parent>/venvs/<svc>/bin/python.
fake_install() {   # fake_install APP_DIR VENV_DIR
  mkdir -p "$1" "$2/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$2/bin/python"; chmod +x "$2/bin/python"
  : > "$1/config.yaml"
}
core() {   # core HOME APP_DIR VENV_DIR SERVICE_NAME
  HOME="$1" PATH="$T/bin:$PATH" bash "$CORE" --service-name "$4" --module seren_memory \
    --venv "$3" --app-dir "$2" --config "$2/config.yaml" --no-health-check 2>&1
}

echo "== setup-seren-service.sh"
H="$T/home1"; R="$H/seren/wren"
fake_install "$R/apps/memory" "$R/venvs/memory"
out="$(core "$H" "$R/apps/memory" "$R/venvs/memory" seren-memory-wren)"
M="$R/manifests/seren-memory-wren.json"
if [[ -f "$M" ]] && grep -q '"systemd_unit": "seren-memory-wren.service"' "$M"; then
  ok_ "under a root: <root>/manifests/seren-memory-wren.json"
else bad "under a root, no manifest at $M: $out"; fi
[[ -e "$H/.seren/services" ]] && bad "under a root, something still went to ~/.seren/services" \
                              || ok_ "under a root: nothing in ~/.seren/services"
grep -qF "$M" <<<"$out" && ok_ "the log names where it registered" || bad "log does not name $M"

H="$T/home2"
fake_install "$H/seren-memory" "$H/seren-venvs/memory"
core "$H" "$H/seren-memory" "$H/seren-venvs/memory" seren-memory >/dev/null
[[ -f "$H/.seren/services/seren-memory.json" ]] && ok_ "no root: ~/.seren/services, as before" \
                                               || bad "no root: no manifest in ~/.seren/services"

H="$T/home3"
fake_install "$H/a/apps/memory" "$H/b/venvs/memory"
core "$H" "$H/a/apps/memory" "$H/b/venvs/memory" seren-memory >/dev/null
if [[ -f "$H/.seren/services/seren-memory.json" && ! -e "$H/a/manifests" && ! -e "$H/b/manifests" ]]; then
  ok_ "apps/ and venvs/ under different parents: not a root"
else bad "apps/ and venvs/ under different parents were taken for a root"; fi

echo "== the observatory cards name the roster"
CARD="$HERE/services/bash/seren-observatory-setup.sh"
line="$(grep -F 'manifests_dir:' "$CARD" | grep -F '$ROOT/manifests' || true)"
if [[ -z "$line" ]]; then bad "bash card: no manifests_dir line"
else
  under="$(ROOT=/r/seren/wren bash -c 'eval "echo \"$1\""' _ "$line")"
  bare="$(ROOT='' bash -c 'eval "echo \"$1\""' _ "$line")"
  eq "bash card: under a root" "$under" "  manifests_dir: '/r/seren/wren/manifests'"
  eq "bash card: no root, no key" "$bare" ""
fi
grep -qF "manifests_dir: '\$(\$layout.Root)\\manifests'" "$HERE/services/powershell/seren-observatory-setup.ps1" \
  && grep -qF 'if ($layout.Root) { "`n  manifests_dir:' "$HERE/services/powershell/seren-observatory-setup.ps1" \
  && ok_ "powershell card: manifests_dir under a root only" || bad "powershell card: no rooted manifests_dir"

echo "== seren-register-services.sh backfills into each unit's roster"
H="$T/home4"; R="$H/seren/wren"
fake_install "$R/apps/loci" "$R/venvs/loci"
fake_install "$H/seren-margin" "$H/seren-venvs/margin"
cat > "$T/bin/systemctl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *list-unit-files*) printf 'seren-loci-wren.service enabled\nseren-margin.service enabled\n' ;;
  *"-p ExecStart --value seren-loci-wren.service"*)
    echo "{ path=$R/venvs/loci/bin/python ; argv[]=$R/venvs/loci/bin/python -m seren_loci --config $R/apps/loci/config.yaml ; ignore_errors=no }" ;;
  *"-p WorkingDirectory --value seren-loci-wren.service"*) echo "$R/apps/loci" ;;
  *"-p ExecStart --value seren-margin.service"*)
    echo "{ path=$H/seren-venvs/margin/bin/python ; argv[]=$H/seren-venvs/margin/bin/python -m seren_margin --config $H/seren-margin/config.yaml ; ignore_errors=no }" ;;
  *"-p WorkingDirectory --value seren-margin.service"*) echo "$H/seren-margin" ;;
  *"-p Description"*) echo "a seren service" ;;
esac
exit 0
SH
chmod +x "$T/bin/systemctl"
out="$(HOME="$H" PATH="$T/bin:$PATH" bash "$REGISTER" --apply 2>&1)"
[[ -f "$R/manifests/seren-loci-wren.json" ]] && ok_ "rooted unit -> <root>/manifests" \
                                             || bad "rooted unit not in $R/manifests: $out"
[[ -f "$H/.seren/services/seren-margin.json" ]] && ok_ "root-less unit -> ~/.seren/services" \
                                                || bad "root-less unit not in ~/.seren/services: $out"
[[ -e "$H/.seren/services/seren-loci-wren.json" ]] && bad "rooted unit ALSO landed in ~/.seren/services" \
                                                   || ok_ "rooted unit not in the shared roster"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
