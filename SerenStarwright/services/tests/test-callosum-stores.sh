#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The callosum card writes only the stores it was given.
#
#  Chad, 25 Sept 2026: the callosum holds n stores, better with one of each,
#  either alone works - "im a warning message not a cop." The card used to
#  write memory:7420 AND loci:7422 whatever it was handed, so a Memory-only
#  callosum reported a dead Loci on every search.
#
#  Runs the REAL card, with a stand-in python on PATH (no venv, no pip, no
#  network; the keep-config step goes to the real python). Proves:
#    - --describe recommends memory and loci and requires nothing
#    - a memory config only: one memory store, url and bearer read from that
#      config (the token never crossed a command line), no loci entry
#    - a loci url only: one loci store, no memory entry
#    - both: both
#    - neither: it installs, warns, and writes no stores: key
#    - a reinstall given memory only drops the old loci entry; a reinstall
#      given nothing keeps the stores the last config had
#
#  Run:  bash services/tests/test-callosum-stores.sh   (Linux, macOS or WSL:
#        the bash card is the Linux one, <venv>/bin/python)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-corpus-callosum-setup.sh"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
has()  { if grep -qF -- "$2" "$3"; then ok_ "$1"; else bad "$1"; sed 's/^/        /' "$3"; fi; }
hasnt(){ if grep -qF -- "$2" "$3"; then bad "$1"; sed 's/^/        /' "$3"; else ok_ "$1"; fi; }

REAL=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 && { REAL="$(command -v "$c")"; break; }
done
[[ -n "$REAL" ]] || { echo "no python found"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# The stand-in: first on PATH as python3.13, so the card picks it whatever
# the box has. It answers the version probe and the import check, makes a
# "venv" of itself, and skips pip; anything else goes to the real python.
mkdir -p "$T/bin"
cat > "$T/bin/python3.13" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -m) case "\${2:-}" in
        venv) mkdir -p "\$3/bin" && cp "\$0" "\$3/bin/python" && exit 0 ;;
        pip)  exit 0 ;;
      esac ;;
  -c) case "\${2:-}" in
        *'[:3]'*)       echo 3.13.0; exit 0 ;;
        *version_info*) echo 3.13;   exit 0 ;;
      esac ;;
  -)  cat >/dev/null; echo OK; exit 0 ;;
esac
exec "$REAL" "\$@"
SH
chmod +x "$T/bin/python3.13"
WHEEL="$T/seren_corpus_callosum-0.0.0-py3-none-any.whl"; : > "$WHEEL"

# The siblings, as their own cards write them.
cat > "$T/memory.yaml" <<'YAML'
server:
  host: 0.0.0.0
  port: 7267
  bearer_token: "memory-bearer"
YAML
cat > "$T/loci.yaml" <<'YAML'
server:
  host: 127.0.0.1
  port: 7266
  bearer_token_env: SEREN_LOCI_TOKEN
YAML

install() {   # install HOME_NAME -- card args...  -> $CFG, $OUT, $RC
  local h="$T/$1"; shift
  mkdir -p "$h"
  OUT="$T/out-$(basename "$h")-$RANDOM.txt"
  PATH="$T/bin:$PATH" HOME="$h" SEREN_INSTALLED_DIR="$h/ledger" \
    bash "$CARD" --wheel "$WHEEL" "$@" >"$OUT" 2>&1
  RC=$?
  CFG="$h/seren-corpus-callosum/seren-corpus-callosum.yaml"
  [[ -f "$CFG" ]] || : > "$T/missing.yaml"
  [[ -f "$CFG" ]] || CFG="$T/missing.yaml"
}
installed() {   # installed LABEL
  if [[ $RC -eq 0 && -s "$CFG" ]]; then ok_ "$1"; else bad "$1 (rc=$RC)"; sed 's/^/        /' "$OUT"; fi
}

echo "== --describe"
d="$(HOME="$T/describe" bash "$CARD" --describe)"
if "$REAL" -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["recommends"]==["seren-memory","seren-loci"] and d["requires"]==[] else 1)' "$d"; then
  ok_ "recommends memory and loci, requires nothing"
else bad "describe: $d"; fi
[[ ! -e "$T/describe" ]] && ok_ "...and touched nothing" || bad "--describe created $T/describe"

echo "== a memory config only"
install mem --memory-config "$T/memory.yaml"
installed "it installs"
has   "the memory store, url from its config"   "url: http://127.0.0.1:7267" "$CFG"
has   "...with its bearer, read by the card"     '      bearer_token: "memory-bearer"' "$CFG"
hasnt "no loci entry"                            "name: loci" "$CFG"
hasnt "no default loci port"                     "7422" "$CFG"
hasnt "no 'nothing given' warning"               "No Memory or Loci was given" "$OUT"
if [[ "$(stat -c %a "$CFG" 2>/dev/null || stat -f %Lp "$CFG")" == 600 ]]; then ok_ "a config holding a bearer is 600"; else bad "config mode: $(ls -l "$CFG")"; fi

echo "== a loci url only"
install loci --loci-url http://127.0.0.1:7266
installed "it installs"
has   "the loci store"                           "url: http://127.0.0.1:7266" "$CFG"
hasnt "no memory entry"                          "name: memory" "$CFG"
hasnt "no default memory port"                   "7420" "$CFG"

echo "== both"
install both --memory-config "$T/memory.yaml" --loci-config "$T/loci.yaml"
installed "it installs"
has   "memory"                                   "name: memory" "$CFG"
has   "loci"                                     "name: loci" "$CFG"
has   "loci's bearer pointer carried over"       "      bearer_token_env: SEREN_LOCI_TOKEN" "$CFG"
has   "the output names both"                    "fanning memory http://127.0.0.1:7267 + loci http://127.0.0.1:7266" "$OUT"

echo "== neither"
install none
installed "it installs anyway (a warning, not a cop)"
has   "it warns"                                 "No Memory or Loci was given" "$OUT"
hasnt "no stores: key"                           "stores:" "$CFG"
hasnt "no memory entry"                          "name: memory" "$CFG"
hasnt "no loci entry"                            "name: loci" "$CFG"
has   "the file says why it is empty"            "None was given at install" "$CFG"
has   "the federation block is still there"      "federation:" "$CFG"

echo "== reinstalls"
install re1 --memory-url http://127.0.0.1:7267 --loci-url http://127.0.0.1:7266
install re1 --memory-url http://127.0.0.1:7267
installed "given memory only, it reinstalls"
has   "memory stays"                             "name: memory" "$CFG"
hasnt "the old loci entry is gone"               "name: loci" "$CFG"
install re2 --memory-url http://127.0.0.1:7267 --loci-url http://127.0.0.1:7266
install re2
installed "given nothing, it reinstalls"
has   "the last config's memory is kept"         "name: memory" "$CFG"
has   "...and its loci"                          "name: loci" "$CFG"
if [[ "$(grep -c 'stores:' "$CFG")" == 1 ]]; then ok_ "one stores: key"; else bad "stores: keys: $(grep -c 'stores:' "$CFG")"; sed 's/^/        /' "$CFG"; fi

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
