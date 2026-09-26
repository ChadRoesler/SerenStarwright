#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  --root: one folder per named install.
#
#  Chad, 26 Sept 2026: "everything gets pushed into its per named install" -
#  two clusters on one host must not share a Lodestar, an Observatory, Probe's
#  results or Theatre's archive, and you should be able to see what belongs to
#  which. Found the same day: the wren set's configs said ~/.seren-memory...,
#  the services ran as LocalSystem, and all of Wren's memory lived in the
#  Windows system profile. Under a root every path is absolute.
#
#  Proves:
#    - seren_layout: <root>/venvs|apps|stores/<svc> and <root>/logs, absolute,
#      ~ expanded; the service name suffix is -<instance>; no root = the old
#      layout and the old concatenated suffix
#    - every card calls seren_layout and hands the SUFFIX to autostart
#    - every card's store path: absolute and quoted under a root, the old
#      literal ~ path (with its instance) without one
#    - the ledger record carries the root
#    - autostart tells the wrapper the app dir and the suffixed instance
#
#  Run:  bash services/tests/test-install-root.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
eq()   { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad "$1: got [$2] want [$3]"; fi; }
LIB="$HERE/services/lib/seren-install-lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

run() {   # run BODY - in its own bash, library sourced, a fake HOME
  HOME="$T/home" bash -c "source '$LIB'; die() { echo \"[die] \$1\"; exit 1; }; $1" 2>&1
}
mkdir -p "$T/home"

echo "== seren_layout"
out="$(run 'ROOT="~/seren/wren"; INSTANCE=wren; VENV_DIR=/x; APP_DIR=/y; seren_layout memory
           echo "$ROOT|$VENV_DIR|$APP_DIR|$DATA_DIR|$LOG_DIR|$SVC_SUFFIX"')"
R="$T/home/seren/wren"
R="$(cd "$R" 2>/dev/null && pwd)"
eq "a root: ~ expanded, the four folders, the dash suffix" "$out" \
   "$R|$R/venvs/memory|$R/apps/memory|$R/stores/memory|$R/logs|-wren"
out="$(run 'ROOT="~/seren/default"; INSTANCE=""; seren_layout loci; echo "$SVC_SUFFIX|$APP_DIR"')"
eq "the default install: no suffix, so the service keeps its plain name" "${out%%|*}" ""
out="$(run 'ROOT=""; INSTANCE=Test; VENV_DIR=/v/memory; APP_DIR=/a/seren-memory; seren_layout memory
           echo "$VENV_DIR|$APP_DIR|$DATA_DIR|$SVC_SUFFIX"')"
eq "no root: the old layout, the old concatenated suffix" "$out" "/v/memoryTest|/a/seren-memoryTest||Test"

echo "== every card"
for f in "$HERE"/services/bash/seren-*-setup.sh; do
  card="$(basename "$f" -setup.sh)"
  n_layout="$(grep -c '^seren_layout "' "$f")"
  n_suffix="$(grep -c 'setup_autostart .*"\$SVC_SUFFIX"' "$f")"
  n_root="$(grep -cE '^\s+--root\)' "$f")"
  if [[ "$n_layout" == 1 && "$n_suffix" == 1 && "$n_root" == 1 ]]; then ok_ "$card: --root, seren_layout, the suffix to autostart"
  else bad "$card: layout=$n_layout suffix=$n_suffix root-flag=$n_root"; fi
  line="$(grep -E '^if \[\[ -n "\$DATA_DIR" \]\]; then STORE_PATH=' "$f" || true)"
  [[ -z "$line" ]] && continue
  under="$(bash -c "DATA_DIR=/r/stores/x; INSTANCE=Test; $line; echo \"\$STORE_PATH\"")"
  bare="$(bash -c "DATA_DIR=''; INSTANCE=Test; $line; echo \"\$STORE_PATH\"")"
  [[ "$under" == "'/r/stores/x/"* ]] && ok_ "$card: store path absolute and quoted under a root ($under)" \
                                      || bad "$card: store path under a root: $under"
  [[ "$bare" == "~/"* && ( "$bare" == *Test* || "$card" == seren-workbench ) ]] \
      && ok_ "$card: without a root, the old literal ~ path ($bare)" \
      || bad "$card: without a root: $bare"
done
grep -q "archive:" "$HERE/services/bash/seren-theatre-setup.sh" && grep -q "dsn: '\$DATA_DIR/archive.db'" "$HERE/services/bash/seren-theatre-setup.sh" \
  && ok_ "theatre: archive and recipes into the root's store" || bad "theatre: archive not rooted"
grep -q "state_dir: " "$HERE/services/bash/seren-probe-setup.sh" && ok_ "probe: storage.state_dir into the root's store" || bad "probe: state_dir"
grep -q 'SECRETS_FILE="$DATA_DIR/secrets.json"' "$HERE/services/bash/seren-observatory-setup.sh" \
  && grep -q "secrets_path: " "$HERE/services/bash/seren-observatory-setup.sh" \
  && ok_ "observatory: the token file in the root's store, named in the config" || bad "observatory: secrets not rooted"

echo "== the ledger carries the root"
export SEREN_INSTALLED_DIR="$T/ledger"
run 'ROOT="$HOME/seren/wren"; mkdir -p "$ROOT"; INSTANCE=wren; VENV_DIR="$ROOT/venvs/memory"; CFG_PATH="$ROOT/apps/memory/seren-memory.yaml"
     seren_record_install seren-memory 127.0.0.1 7267 true "" >/dev/null'
rec="$T/ledger/seren-memory@wren.json"
if [[ -f "$rec" ]] && grep -q "\"root\": \"$T/home/seren/wren\"" "$rec"; then ok_ "record names the root"; else bad "record: $(cat "$rec" 2>/dev/null)"; fi

echo "== autostart gets the app dir and the suffixed instance"
FAKE="$T/cards"; mkdir -p "$FAKE"
cat > "$FAKE/setup-memory-service.sh" <<'SH'
#!/usr/bin/env bash
echo "WRAPPER $*"
SH
out="$(run "find_upward() { echo '$LIB'; }; setup_autostart '$FAKE' seren-memory /root/apps/memory '' -wren /root/venvs/memory ''")"
case "$out" in
  *"WRAPPER --app-dir /root/apps/memory --venv /root/venvs/memory --instance -wren"*) ok_ "wrapper called with --app-dir and --instance -wren" ;;
  *) bad "wrapper call: $out" ;;
esac

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
