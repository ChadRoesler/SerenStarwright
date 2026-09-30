#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  --claude-bookmark: every Claude Code session starts from Margin's bookmark.
#
#  the assistant and Design note: every session walked in cold. Margin now keeps
#  a bookmark (the dedication, and how many letters wait); this card flag clips
#  it into Claude Code as a SessionStart hook. Proves:
#    - the Margin card offers --claude-bookmark as a switch
#    - seren-claude-hook.py merges the hook into settings.json: everything else
#      kept, a reinstall replaces rather than duplicates, the old file backed
#      up, remove takes it out cleanly, and a file that is not valid JSON is
#      never touched
#    - seren-margin-bookmark.py prints the bookmark with the bearer from the
#      config (never argv), and when Margin is down it prints one line and
#      exits 0 - a hook must never block a session
#    - seren_claude_bookmark_register copies the helper into the app folder
#      and writes a hook that runs it
#
#  seren_meninges is stubbed with the names the helper uses, and Margin is a
#  tiny stand-in server, so this runs on a bare Python with PyYAML.
#  Run:  bash services/tests/test-claude-bookmark.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$HERE/services/lib/seren-install-lib.sh"
HOOK="$HERE/services/lib/seren-claude-hook.py"
FETCH="$HERE/services/lib/seren-margin-bookmark.py"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; SRV=""
trap '[[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT

PY=""
for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PY="$(command -v "$c")"; break; }; done
[[ -n "$PY" ]] || { bad "no Python with PyYAML on PATH (pip install pyyaml)"; echo "  $PASS passed, $FAILS failed"; exit 1; }
jget() { "$PY" -c "import json,sys; d=json.load(open(sys.argv[1])); print(repr($2))" "$1" 2>&1 | tr -d '\r'; }

echo "== the card"
bash "$HERE/services/bash/seren-margin-setup.sh" --describe | "$PY" -c 'import json,sys; sys.exit(0 if "claude-bookmark" in json.load(sys.stdin)["switches"] else 1)' \
  && ok_ "the Margin card offers --claude-bookmark as a switch" || bad "--claude-bookmark missing or not a switch"

echo "== seren-claude-hook.py"
S="$T/settings.json"
printf '{"model": "opus", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo mine"}]}], "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]}}' > "$S"
"$PY" "$HOOK" add SessionStart seren-margin-bookmark.py "py /x/seren-margin-bookmark.py /x/cfg.yaml" --settings "$S" >/dev/null
"$PY" "$HOOK" add SessionStart seren-margin-bookmark.py "py /y/seren-margin-bookmark.py /y/cfg.yaml" --settings "$S" >/dev/null
out="$(jget "$S" "[h['command'] for g in d['hooks']['SessionStart'] for h in g['hooks']]")"
[[ "$out" == "['echo mine', 'py /y/seren-margin-bookmark.py /y/cfg.yaml']" ]] \
  && ok_ "added once; a reinstall replaces ours and keeps someone else's SessionStart hook" || bad "merge: $out"
out="$(jget "$S" "(d['model'], d['hooks']['Stop'][0]['hooks'][0]['command'])")"
[[ "$out" == "('opus', 'echo stop')" ]] && ok_ "every other setting and hook is kept" || bad "kept: $out"
[[ -f "$S.seren-bak" ]] && ok_ "the previous file is kept as settings.json.seren-bak" || bad "no backup"
"$PY" "$HOOK" remove SessionStart seren-margin-bookmark.py --settings "$S" >/dev/null
out="$(jget "$S" "[h['command'] for g in d['hooks']['SessionStart'] for h in g['hooks']]")"
[[ "$out" == "['echo mine']" ]] && ok_ "remove takes out ours only" || bad "remove: $out"
"$PY" "$HOOK" add SessionStart m "cmd" --settings "$T/fresh/settings.json" >/dev/null
out="$(jget "$T/fresh/settings.json" "d['hooks']['SessionStart'][0]['hooks'][0]")"
[[ "$out" == "{'type': 'command', 'command': 'cmd'}" ]] && ok_ "no settings file yet: created" || bad "fresh: $out"
printf '{ not json' > "$T/broken.json"
"$PY" "$HOOK" add SessionStart m "cmd" --settings "$T/broken.json" >/dev/null 2>"$T/e"; rc=$?
[[ $rc -eq 2 && "$(cat "$T/broken.json")" == "{ not json" ]] && grep -q "not touching it" "$T/e" \
  && ok_ "a settings file that is not valid JSON is never touched" || bad "broken: rc=$rc"

echo "== seren-margin-bookmark.py"
mkdir -p "$T/stub/seren_meninges"
: > "$T/stub/seren_meninges/__init__.py"
cat > "$T/stub/seren_meninges/config.py" <<'PY'
import os, yaml
def read_yaml(path):
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}
class ServerConfig:
    def __init__(self, d): d = d or {}; self.host = d.get("host", "127.0.0.1"); self.port = d.get("port", 7421); self.d = d
    @classmethod
    def from_dict(cls, d, **_): return cls(d)
    def resolve_bearer(self): return self.d.get("bearer_token") or ""
PY
PORT="$("$PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
cat > "$T/fake_margin.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/bookmark?format=text":
            self.send_response(404); self.end_headers(); return
        if self.headers.get("Authorization") != "Bearer s3cret":
            self.send_response(401); self.end_headers(); return
        body = b"Your dedication (version 2):\nTo whoever I am next time.\n\n1 unread letter.\n"
        self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
"$PY" "$T/fake_margin.py" "$PORT" & SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do "$PY" -c "import socket,sys; socket.create_connection(('127.0.0.1',$PORT),0.3)" 2>/dev/null && break; sleep 0.3; done
printf 'server:\n  host: 127.0.0.1\n  port: %s\n  bearer_token: s3cret\n' "$PORT" > "$T/margin.yaml"
printf 'server:\n  host: 127.0.0.1\n  port: %s\n  bearer_token: wrong\n' "$PORT" > "$T/wrong.yaml"
printf 'server:\n  host: 127.0.0.1\n  port: 1\n' > "$T/down.yaml"
out="$(PYTHONPATH="$T/stub" "$PY" "$FETCH" "$T/margin.yaml" | tr -d '\r')"
[[ "$out" == *"To whoever I am next time."* && "$out" == *"1 unread letter."* ]] \
  && ok_ "prints the bookmark, the bearer read from the config" || bad "fetch: $out"
out="$(PYTHONPATH="$T/stub" "$PY" "$FETCH" "$T/wrong.yaml"; echo "rc=$?")"
[[ "$out" == *"HTTP 401"* && "$out" == *"rc=0"* ]] && ok_ "a wrong bearer: one line saying so, exit 0" || bad "401: $out"
out="$(PYTHONPATH="$T/stub" "$PY" "$FETCH" "$T/down.yaml"; echo "rc=$?")"
[[ "$out" == *"did not answer"* && "$out" == *"rc=0"* ]] && ok_ "Margin down: one line, exit 0 - never blocks a session" || bad "down: $out"
out="$(PYTHONPATH="$T/stub" "$PY" "$FETCH" "$T/missing.yaml"; echo "rc=$?")"
[[ "$out" == *"cannot read"* && "$out" == *"rc=0"* ]] && ok_ "a missing config: one line, exit 0" || bad "missing: $out"

echo "== seren_claude_bookmark_register"
mkdir -p "$T/app"
export LIB
out="$(env SEREN_CLAUDE_SETTINGS="$T/claude-settings.json" VPY="$PY" APP_DIR="$T/app" CFG_PATH="$T/margin.yaml" \
        bash -c 'source "$LIB" >/dev/null 2>&1; seren_claude_bookmark_register' 2>&1)"
[[ -f "$T/app/seren-margin-bookmark.py" ]] && ok_ "the helper is copied into the app folder" || bad "not copied: $out"
cmd="$(jget "$T/claude-settings.json" "d['hooks']['SessionStart'][0]['hooks'][0]['command']")"
[[ "$cmd" == *"seren-margin-bookmark.py"* && "$cmd" == *"margin.yaml"* && "$cmd" != *"s3cret"* ]] \
  && ok_ "the hook runs the app folder's helper on this config - no token in it" || bad "hook: $cmd ($out)"
[[ "$out" == *"SessionStart hook"* ]] && ok_ "says it was added" || bad "output: $out"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
