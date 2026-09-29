#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-claude-ripple.py: the ripple command for Claude Code, read off a
#  Claude Code settings file (Chad, 28 Sept 2026: "so that YOU can use it
#  here"). Proves:
#    - servers are gathered from all three scopes: user (top-level
#      mcpServers), local (projects[<dir>].mcpServers) and project (.mcp.json)
#    - --yaml N prints `command:` and `cwd:` lines, a JSON list that parses as
#      YAML, with every server pre-approved by name
#    - a project with no servers, a missing settings file and a missing
#      folder each refuse (exit 2) with the reason - a ripple would wake the
#      model without its memory
#    - another project's local servers are not borrowed
#
#  Run:  bash services/tests/test-claude-ripple.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$HERE/services/lib/seren-claude-ripple.py"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

PY=""; PYY=""
for c in python3 python; do "$c" -c 'import json' >/dev/null 2>&1 && { PY="$c"; break; }; done
for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PYY="$c"; break; }; done
[[ -n "$PY" ]] || { echo "no python"; exit 1; }
[[ -n "$PYY" ]] || bad "no Python with PyYAML on PATH - the --yaml check parses the lines (pip install pyyaml)"

mkdir -p "$T/proj" "$T/other" "$T/bare"
# The key Claude Code writes is the folder as it saw it; the helper compares
# normalised paths, so write it the way this Python spells the folder.
PROJ="$("$PY" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$T/proj")"
OTHER="$("$PY" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$T/other")"
"$PY" - "$T/claude.json" "$PROJ" "$OTHER" <<'PY'
import json, sys
path, proj, other = sys.argv[1:4]
json.dump({
    "mcpServers": {"everywhere": {"type": "http", "url": "http://127.0.0.1:1/mcp"}},
    "projects": {
        proj:  {"mcpServers": {"wren-memory": {"type": "http", "url": "http://127.0.0.1:7267/mcp"}}},
        other: {"mcpServers": {"not-mine": {"type": "http", "url": "http://127.0.0.1:2/mcp"}}},
    },
}, open(path, "w"))
PY
printf '{"mcpServers": {"from-mcp-json": {"type": "http", "url": "http://127.0.0.1:3/mcp"}}}' > "$T/proj/.mcp.json"

echo "== the three scopes"
out="$(SEREN_CLAUDE_JSON="$T/claude.json" "$PY" "$HELPER" "$T/proj")"
servers="$("$PY" -c 'import json,sys; print(",".join(json.loads(sys.stdin.read())["servers"]))' <<<"$out")"
[[ "$servers" == "everywhere,from-mcp-json,wren-memory" ]] \
  && ok_ "user, local and project scope all found; another project's are not" || bad "servers: $servers"

echo "== --yaml"
y="$(SEREN_CLAUDE_JSON="$T/claude.json" "$PY" "$HELPER" "$T/proj" --yaml 2)"
[[ "$y" == "  command: "* ]] && ok_ "indented as asked" || bad "indent: $y"
if [[ -n "$PYY" ]]; then
  got="$("$PYY" -c 'import sys, yaml; d = yaml.safe_load(sys.stdin); print(d["command"][:3], d["command"][4], bool(d["cwd"]))' <<<"$y" 2>&1)"
  [[ "$got" == "['claude', '-p', '{message}'] mcp__everywhere,mcp__from-mcp-json,mcp__wren-memory True" ]] \
    && ok_ "parses as YAML: claude -p {message} --allowedTools mcp__<each>, and a cwd" || bad "yaml: $got"
fi
y2="$("$PY" "$HELPER" "$T/proj" --yaml 2 --claude-json "$T/claude.json")"
[[ "$y2" == "$y" ]] && ok_ "--claude-json reads the same file (another user's settings, under sudo)" || bad "--claude-json: $y2"

echo "== refusals"
# `everywhere` is user scope, so an empty folder still has one server; a
# settings file with none at all is the refusal.
printf '{"projects": {}}' > "$T/empty.json"
SEREN_CLAUDE_JSON="$T/empty.json" "$PY" "$HELPER" "$T/bare" >/dev/null 2>"$T/err"; rc=$?
[[ $rc -eq 2 ]] && grep -q "no MCP servers" "$T/err" && ok_ "no servers anywhere: refused, and says so" || bad "no servers: rc=$rc $(cat "$T/err")"
SEREN_CLAUDE_JSON="$T/nope.json" "$PY" "$HELPER" "$T/proj" >/dev/null 2>"$T/err"; rc=$?
[[ $rc -eq 2 ]] && grep -q "no Claude Code settings" "$T/err" && ok_ "no settings file: refused, and says where it looked" || bad "no file: rc=$rc"
SEREN_CLAUDE_JSON="$T/claude.json" "$PY" "$HELPER" "$T/missing" >/dev/null 2>"$T/err"; rc=$?
[[ $rc -eq 2 ]] && grep -q "no such project folder" "$T/err" && ok_ "no such folder: refused" || bad "no folder: rc=$rc"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
