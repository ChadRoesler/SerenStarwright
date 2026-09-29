#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  --claude-mcp: a card registers its service with Claude Code at USER scope.
#
#  Chad, 28 Sept 2026: added by hand from a home folder, the wren-* servers
#  landed at Claude Code's LOCAL scope (that one folder), and a Claude started
#  anywhere else woke without its memory. Proves:
#    - the five MCP cards offer --claude-mcp as a switch
#    - seren_claude_mcp_register runs `claude mcp remove` then `claude mcp
#      add-json --scope user <instance>-<short>` with an http entry: the URL and
#      a headersHelper - and NO token anywhere on the command line
#    - the helper is copied into the app folder (it outlives the bundle)
#    - seren-mcp-headers.py prints the Authorization header from the config
#      (inline or env var, by the service's rules), {} with no token, and
#      fails - not {} - when the config cannot be read (a silent 401 otherwise)
#    - no claude on PATH is a warning, never a failed install
#
#  seren_meninges is stubbed with the two names the helper uses, so this runs
#  on a bare Python with PyYAML.
#  Run:  bash services/tests/test-claude-mcp.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$HERE/services/lib/seren-install-lib.sh"
HEADERS="$HERE/services/lib/seren-mcp-headers.py"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

PY=""
for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PY="$(command -v "$c")"; break; }; done
[[ -n "$PY" ]] || { bad "no Python with PyYAML on PATH (pip install pyyaml)"; echo "  $PASS passed, $FAILS failed"; exit 1; }

# seren_meninges, stubbed: read_yaml + ServerConfig.from_dict(...).resolve_bearer()
mkdir -p "$T/stub/seren_meninges"
: > "$T/stub/seren_meninges/__init__.py"
cat > "$T/stub/seren_meninges/config.py" <<'PY'
import os, yaml
def read_yaml(path):
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}          # lenient, like the real one - the helper must not trust it
class ServerConfig:
    def __init__(self, d): self.d = d or {}
    @classmethod
    def from_dict(cls, d, **_): return cls(d)
    def resolve_bearer(self):
        return self.d.get("bearer_token") or os.environ.get(self.d.get("bearer_token_env") or "", "")
PY
export PYTHONPATH="$T/stub"

echo "== the cards"
for c in memory loci margin corpus-callosum hippocampus; do
  bash "$HERE/services/bash/seren-$c-setup.sh" --describe | "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "claude-mcp" in d["switches"] else 1)' \
    && ok_ "$c offers --claude-mcp as a switch" || bad "$c: --claude-mcp missing or not a switch"
done

echo "== seren-mcp-headers.py"
printf 'server:\n  port: 7267\n  bearer_token: s3cret-inline\n' > "$T/inline.yaml"
printf 'server:\n  port: 7267\n  bearer_token_env: WREN_TOK\n' > "$T/env.yaml"
printf 'server:\n  port: 7267\n' > "$T/none.yaml"
out="$("$PY" "$HEADERS" "$T/inline.yaml")"
[[ "$out" == '{"Authorization": "Bearer s3cret-inline"}' ]] && ok_ "inline token -> the header" || bad "inline: $out"
out="$(WREN_TOK=from-env "$PY" "$HEADERS" "$T/env.yaml")"
[[ "$out" == '{"Authorization": "Bearer from-env"}' ]] && ok_ "bearer_token_env -> the header, resolved at connect" || bad "env: $out"
out="$("$PY" "$HEADERS" "$T/none.yaml")"
[[ "$out" == '{}' ]] && ok_ "no token -> {}" || bad "none: $out"
"$PY" "$HEADERS" "$T/missing.yaml" >"$T/o" 2>"$T/e"; rc=$?
[[ $rc -eq 1 && ! -s "$T/o" ]] && grep -q "cannot read" "$T/e" && ok_ "an unreadable config fails loudly, never {}" || bad "missing: rc=$rc $(cat "$T/o" "$T/e")"

echo "== seren_claude_mcp_register"
# A fake claude that records each call, one argument per line.
mkdir -p "$T/bin" "$T/app"
cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
{ echo "--call"; printf '%s\n' "$@"; } >> "$CLAUDE_LOG"
SH
chmod +x "$T/bin/claude"
run_register() {   # run_register VAR=value ... ; the lib's function, as a card calls it
  env "$@" bash -c 'source "$LIB" >/dev/null 2>&1; seren_claude_mcp_register memory' 2>&1
}
export LIB CLAUDE_LOG="$T/claude.log"
: > "$CLAUDE_LOG"
out="$(run_register SEREN_CLAUDE_BIN="$T/bin/claude" VPY="$PY" APP_DIR="$T/app" CFG_PATH="$T/inline.yaml" \
        CONNECT_HOST=127.0.0.1 PORT=7267 INSTANCE=wren TOKEN=s3cret-inline)"
calls="$(grep -c -- '--call' "$CLAUDE_LOG")"
[[ "$calls" == 2 ]] && ok_ "two calls: remove, then add-json" || bad "calls: $calls ($out)"
"$PY" - "$CLAUDE_LOG" > "$T/parsed" <<'PY'
import json, sys
calls = open(sys.argv[1], encoding="utf-8").read().split("--call\n")[1:]
rm, add = [c.rstrip("\n").split("\n") for c in calls]
print(rm[:5] == ["mcp", "remove", "--scope", "user", "wren-memory"])
print(add[:5] == ["mcp", "add-json", "--scope", "user", "wren-memory"])
e = json.loads(add[5])
print(e["type"] == "http" and e["url"] == "http://127.0.0.1:7267/mcp")
print("seren-mcp-headers.py" in e["headersHelper"] and "inline.yaml" in e["headersHelper"])
print(not any("s3cret" in a for c in (rm, add) for a in c))
PY
mapfile -t r < <(tr -d "\r" < "$T/parsed")    # Windows Python writes CRLF
[[ "${r[0]}" == True ]] && ok_ "remove --scope user wren-memory first (a reinstall replaces it)" || bad "remove: ${r[0]}"
[[ "${r[1]}" == True ]] && ok_ "add-json --scope user wren-memory: <instance>-<short>, every folder" || bad "add-json: ${r[1]}"
[[ "${r[2]}" == True ]] && ok_ "an http entry at http://127.0.0.1:7267/mcp" || bad "entry: ${r[2]}"
[[ "${r[3]}" == True ]] && ok_ "a headersHelper: the service's python, the helper, this config" || bad "helper: ${r[3]}"
[[ "${r[4]}" == True ]] && ok_ "the token is on no command line" || bad "a token leaked onto a command line"
[[ -f "$T/app/seren-mcp-headers.py" ]] && ok_ "the helper is copied into the app folder" || bad "helper not copied"
[[ "$out" == *"registered"* && "$out" != *"cannot read the bearer"* ]] && ok_ "says it registered; the installer can read the bearer" || bad "output: $out"

: > "$CLAUDE_LOG"
out="$(run_register SEREN_CLAUDE_BIN="" PATH="/usr/bin:/bin" HOME="$T" VPY="$PY" APP_DIR="$T/app" CFG_PATH="$T/inline.yaml" \
        CONNECT_HOST=127.0.0.1 PORT=7267 INSTANCE=wren; echo "rc=$?")"
if command -v claude >/dev/null 2>&1 && PATH="/usr/bin:/bin" HOME="$T" bash -lc 'command -v claude' >/dev/null 2>&1; then
  echo "  skip  no-claude case: this box's login shell finds a real claude"
else
  [[ "$out" == *"no claude on"* && "$out" == *"rc=0"* ]] && ok_ "no claude on PATH: a warning with the command to run later, never a failure" || bad "no claude: $out"
fi

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
