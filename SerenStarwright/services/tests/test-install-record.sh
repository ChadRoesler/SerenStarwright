#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The install ledger: seren_record_install writes one record per install.
#
#  Proves, with no network and no venv:
#    - the record lands at $SEREN_INSTALLED_DIR/<service>[@<instance>].json
#    - service / instance / port / url / venv / config / app_dir / source
#    - has_token is true and the token itself is NOT in the file
#    - extras and the derived flag
#    - seren_emit_done writes it whether or not --json was asked for
#
#  Run:  bash services/tests/test-install-record.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok_ "$1"; else bad "$1"; fi; }

PY=""
for c in python python3; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 && { PY="$c"; break; }
done
[[ -n "$PY" ]] || { echo "no python found"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
LIB="$HERE/services/lib/seren-install-lib.sh"

field() {  # field <file> <expr on d>
  "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2"
}

echo "== a card's done step records the install"
(
  export SEREN_INSTALLED_DIR="$T/ledger"
  source "$LIB"
  INSTANCE="wren"; VENV_DIR="$T/venv"; CFG_PATH="$T/seren-memory/seren-memory.yaml"; APP_DIR="$T/seren-memory"
  PACKAGE="seren-memory"; MCP=true; CORP=false; LOCAL="$T/wheelhouse"; WHEEL=""; REF=""
  seren_emit_done "seren-memory" "127.0.0.1" "7267" "false" "s3cret-do-not-write-me" >/dev/null 2>&1
)
REC="$T/ledger/seren-memory@wren.json"
check "record at <service>@<instance>.json"          "[[ -f '$REC' ]]"
check "service / instance / port"                    "[[ \"\$(field '$REC' 'd[\"service\"], d[\"instance\"], d[\"port\"]')\" == \"('seren-memory', 'wren', 7267)\" ]]"
check "url and app_dir derived"                      "[[ \"\$(field '$REC' 'd[\"url\"]')\" == 'http://127.0.0.1:7267' && \"\$(field '$REC' 'd[\"app_dir\"]')\" == '$T/seren-memory' ]]"
check "source is the dev wheelhouse"                 "[[ \"\$(field '$REC' 'd[\"source\"]')\" == 'local' ]]"
check "has_token true"                               "[[ \"\$(field '$REC' 'd[\"has_token\"]')\" == 'True' ]]"
check "the token itself is never written"            "! grep -q 's3cret' '$REC'"
check "extras.mcp true, derived false"               "[[ \"\$(field '$REC' 'd[\"extras\"][\"mcp\"], d[\"derived\"]')\" == '(True, False)' ]]"
check "launcher named"                               "[[ \"\$(field '$REC' 'd[\"launcher\"]')\" == '$T/seren-memory/run-seren-memory.sh' ]]"

echo "== no instance: <service>.json, and a wheel beats local"
(
  export SEREN_INSTALLED_DIR="$T/ledger"
  source "$LIB"
  INSTANCE=""; VENV_DIR="$T/venv"; CFG_PATH="$T/seren-loci/seren-loci.yaml"; APP_DIR="$T/seren-loci"
  LOCAL="$T/wheelhouse"; WHEEL="$T/seren_loci-1.0.0-py3-none-any.whl"
  seren_emit_done "seren-loci" "0.0.0.0" "7422" "true" "" >/dev/null 2>&1
)
REC2="$T/ledger/seren-loci.json"
check "record at <service>.json"                     "[[ -f '$REC2' ]]"
check "autostart true, no token"                     "[[ \"\$(field '$REC2' 'd[\"autostart\"], d[\"has_token\"]')\" == '(True, False)' ]]"
check "source is the wheel"                          "[[ \"\$(field '$REC2' 'd[\"source\"]')\" == 'wheel' ]]"

echo "== --json mode: the ledger is written AND an installed event is emitted"
OUT="$(
  export SEREN_INSTALLED_DIR="$T/ledger2"
  source "$LIB"
  seren_json_on
  INSTANCE=""; VENV_DIR=""; CFG_PATH="$T/x/seren-margin.yaml"; APP_DIR="$T/x"
  seren_emit_done "seren-margin" "127.0.0.1" "7421" "false" "" 2>/dev/null
)"
if grep -q '"event":"installed"' <<<"$OUT"; then ok_ "installed event on the stream"; else bad "installed event on the stream"; fi
if grep -q '"event":"done"' <<<"$OUT"; then ok_ "done event still follows"; else bad "done event still follows"; fi
check "record written in json mode too"              "[[ -f '$T/ledger2/seren-margin.json' ]]"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
