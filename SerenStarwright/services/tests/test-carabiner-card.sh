#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  seren-carabiner-setup.sh: the card that clips a harness onto Seren. Proves:
#    - --describe: group carabiners, no port, recommends workbench + margin,
#      carabiner is a dropdown (choices), dry-wake is a switch
#    - a run with sibling configs writes connection files (host overridable,
#      the bearer carried as the sibling kept it), installs the .kbh, pushes
#      the yaml + framing, registers the Workbench with the harness through a
#      stand-in claude, installs the bookmark hook, belays, and records the
#      install in the ledger with port 0
#    - no token on any command line the card runs
#  Needs: a SerenCarabiners checkout beside this one (build.py), or
#  SEREN_KBH_FILE pointing at a built claude.kbh.
#  Run:  bash services/tests/test-carabiner-card.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-carabiner-setup.sh"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PY=""; for c in python3 python; do "$c" -c 'import json' >/dev/null 2>&1 && { PY="$(command -v $c)"; break; }; done
[[ -n "$PY" ]] || { echo "no python"; exit 1; }

echo "== --describe"
D="$(bash "$CARD" --describe)"
check() { local what="$1" expr="$2"; if eval "$expr" >/dev/null 2>&1; then ok_ "$what"; else bad "$what"; fi; }
check "group carabiners, port 0, package seren-carabiners" \
  "grep -q '\"group\":\"carabiners\"' <<<\"\$D\" && grep -q '\"default_port\":0' <<<\"\$D\" && grep -q '\"package\":\"seren-carabiners\"' <<<\"\$D\""
check "recommends the Workbench and Margin, requires nothing" \
  "grep -q '\"requires\":\[\]' <<<\"\$D\" && grep -q 'seren-workbench' <<<\"\$D\" && grep -q 'seren-margin' <<<\"\$D\""
check "carabiner is a dropdown of claude; dry-wake is a switch" \
  "grep -q '\"carabiner\":\[\"claude\"\]' <<<\"\$D\" && grep -q '\"switches\":\[[^]]*\"dry-wake\"' <<<\"\$D\""
for f in project python into workbench-url margin-url workbench-config margin-config host server kbh local ref repo-dir instance root; do
  check "flag --$f is advertised" "grep -q '\"$f\"' <<<\"\$D\""
done

echo "== a run, isolated from the real harness"
# sibling configs as the brain box's cards write them: bind-all host, a bearer
mkdir -p "$T/apps/workbench" "$T/apps/margin" "$T/proj" "$T/home"
printf 'server:\n  host: 0.0.0.0\n  port: 7255\n  bearer_token: "wb-secret"\ndashboard:\n  tools_dir: /x\n' > "$T/apps/workbench/seren-workbench.yaml"
printf 'server:\n  host: 0.0.0.0\n  port: 7251\n  bearer_token_env: MARGIN_TOKEN\nstorage:\n  db_path: /x/notes.db\n' > "$T/apps/margin/seren-margin.yaml"
# a stand-in claude that records registrations
cat > "$T/fake_claude.py" <<'PYF'
import json, os, sys
reg = os.environ["FAKE_REG"]; argv = sys.argv[1:]
data = json.load(open(reg)) if os.path.exists(reg) else {}
if argv[:2] == ["mcp", "add-json"]: data[argv[4]] = json.loads(argv[5])
elif argv[:2] == ["mcp", "remove"]: data.pop(argv[4], None)
elif argv[:1] == ["--version"]: print("fake claude 0.0")
json.dump(data, open(reg, "w"))
# like the real claude: the registry IS ~/.claude.json's user scope
cj = os.environ.get("SEREN_CLAUDE_JSON")
if cj:
    whole = json.load(open(cj)) if os.path.exists(cj) else {}
    whole["mcpServers"] = data
    json.dump(whole, open(cj, "w"))
PYF
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) FAKE="$(cygpath -w "$T/claude.cmd")"; printf '@"%s" "%s" %%*\r\n' "$(cygpath -w "$PY")" "$(cygpath -w "$T/fake_claude.py")" > "$T/claude.cmd" ;;
  *) FAKE="$T/claude"; printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$PY" "$T/fake_claude.py" > "$FAKE"; chmod +x "$FAKE" ;;
esac
printf '{"mcpServers": {}, "projects": {}}' > "$T/claude.json"
KBH_ARGS=()
[[ -n "${SEREN_KBH_FILE:-}" ]] && KBH_ARGS=(--kbh "$SEREN_KBH_FILE")
have_checkout() { local d="$HERE"; while [[ -n "$d" && "$d" != "/" ]]; do [[ -f "$d/SerenCarabiners/build.py" ]] && return 0; d="$(dirname "$d")"; done; return 1; }
[[ -z "${SEREN_KBH_FILE:-}" ]] && ! have_checkout && { echo "  (no SerenCarabiners checkout and no SEREN_KBH_FILE: skipping the run)"; echo; echo "  $PASS passed, $FAILS failed"; exit $FAILS; }
OUT="$(FAKE_REG="$T/reg.json" SEREN_CLAUDE_BIN="$FAKE" SEREN_CLAUDE_JSON="$T/claude.json" SEREN_CLAUDE_SETTINGS="$T/settings.json" \
       SEREN_INSTALLED_DIR="$T/ledger" HOME="$T/home" USERPROFILE="$T/home" \
       bash "$CARD" --into "$T/clip" --project "$T/proj" --python "$PY" --instance wren --host 127.0.0.1 \
         --workbench-config "$T/apps/workbench/seren-workbench.yaml" --margin-config "$T/apps/margin/seren-margin.yaml" \
         ${KBH_ARGS[@]+"${KBH_ARGS[@]}"} --dry-wake 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok_ "the card ran to the end" || { bad "the card failed (rc=$rc)"; echo "$OUT" | tail -25; }
[[ -f "$T/clip/claude.kbh" && -f "$T/clip/claude.yaml" && -f "$T/clip/framing.md" ]] && ok_ "the .kbh, claude.yaml and framing.md sit in --into" || bad "clip files: $(ls "$T/clip" 2>/dev/null | tr '\n' ' ')"
Y="$(cat "$T/clip/claude.yaml")"
grep -q '  wren-workbench:' <<<"$Y" && grep -q 'url: http://127.0.0.1:7255' <<<"$Y" && grep -q 'bearer_token: wb-secret' <<<"$Y" \
  && ok_ "the Workbench is a ROUTE in claude.yaml: url and token, read out of its config (nothing copied)" || bad "workbench route: $(grep -A3 'wren-workbench' <<<"$Y")"
grep -q 'url: http://127.0.0.1:7251' <<<"$Y" && grep -q 'bearer_token_env: MARGIN_TOKEN' <<<"$Y" \
  && ok_ "Margin is a route too, its token a pointer as its config kept it" || bad "margin route: $(grep -A3 '^bookmark' <<<"$Y")"
[[ ! -d "$T/clip/connections" || -z "$(ls -A "$T/clip/connections")" ]] && ok_ "no connection files were needed" || bad "connections: $(ls "$T/clip/connections")"
REG="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); e=d.get("wren-workbench",{}); print(e.get("url"), "helper" if e.get("headersHelper") else "no-helper", "TOKEN" if "wb-secret" in json.dumps(d) else "clean")' "$T/reg.json" 2>&1)"
[[ "$REG" == "http://127.0.0.1:7255/mcp helper clean" ]] && ok_ "registered with the harness: the Workbench at nuc, a headers helper, no token in the registry" || bad "registry: $REG"
grep -q '"SessionStart"' "$T/settings.json" 2>/dev/null && grep -q '#bookmark' "$T/settings.json" && ok_ "the bookmark hook is installed, reading its route out of claude.yaml by reference" || bad "settings: $(cat "$T/settings.json" 2>/dev/null | head -c 300)"
# Nothing serves the Workbench in a test, so belay's `initialize` line lets go
# and the climb is not clean. What must hold: the registration is seen, the
# project would pre-approve it, the hook is there, the framing renders.
for want in 'register / on belay? / entries' 'wake / on belay? / project' 'bookmark / on belay? / hook' 'wake / on belay? / framing '; do
  grep -F "held     $want" <<<"$OUT" >/dev/null && ok_ "belay holds: $want" || { bad "belay: $want"; grep -F "$want" <<<"$OUT"; }
done
grep -q 'LET GO   register / belay on. / initialize' <<<"$OUT" && ok_ "belay says the Workbench did not answer initialize (nothing serves it here)" || bad "belay initialize line"
grep -q 'belay let go somewhere above' <<<"$OUT" && ok_ "the card says belay let go, and still finished" || bad "card's belay verdict"
grep -q 'wake / belay on. / claude --version' <<<"$OUT" && ok_ "--dry-wake ran the stand-in binary once" || bad "dry wake"
L="$(cat "$T/ledger/seren-carabiner@wren.json" 2>/dev/null)"
grep -q '"port": 0' <<<"$L" && grep -q '"config": "'"$T"'/clip/claude.yaml"\|clip/claude.yaml' <<<"$L" && ok_ "the install ledger has the clip, port 0" || bad "ledger: $(echo "$L" | head -c 300)"
grep -q 'wb-secret' <<<"$OUT" && bad "a token appeared in the card's output" || ok_ "no token in the card's output"
grep -q 'Wake line for an Observatory' <<<"$OUT" && grep -q '"--config"' <<<"$OUT" && ok_ "the done banner shows the one-line wake command for an Observatory" || bad "wake line: $(grep 'Wake line' <<<"$OUT" | cut -c1-200)"

echo "== another box: --workbench-url with the token in the environment"
rm -rf "$T/clip2"; printf '{"mcpServers": {}, "projects": {}}' > "$T/claude2.json"
OUT2="$(FAKE_REG="$T/reg2.json" SEREN_CLAUDE_BIN="$FAKE" SEREN_CLAUDE_JSON="$T/claude2.json" SEREN_CLAUDE_SETTINGS="$T/settings2.json" \
        SEREN_INSTALLED_DIR="$T/ledger2" HOME="$T/home" USERPROFILE="$T/home" SEREN_WORKBENCH_TOKEN="far-secret" SEREN_MARGIN_TOKEN="mg-secret" \
        bash "$CARD" --into "$T/clip2" --project "$T/proj" --python "$PY" --instance wren \
          --workbench-url http://brainbox:7255 --margin-url http://brainbox:7251 ${KBH_ARGS[@]+"${KBH_ARGS[@]}"} 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok_ "the card ran with urls alone" || { bad "urls run (rc=$rc)"; echo "$OUT2" | tail -12; }
Y2="$(cat "$T/clip2/claude.yaml" 2>/dev/null)"
grep -q 'url: http://brainbox:7255' <<<"$Y2" && grep -q 'bearer_token: far-secret' <<<"$Y2" && grep -q 'url: http://brainbox:7251' <<<"$Y2" && grep -q 'bearer_token: mg-secret' <<<"$Y2" \
  && ok_ "both routes in the yaml with their tokens, from the environment" || bad "routes: $(grep -E 'url|bearer' <<<"$Y2")"
grep -q 'far-secret\|mg-secret' <<<"$OUT2" && bad "a token appeared in the card's output" || ok_ "no token in the output"
R2="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); e=d.get("wren-workbench",{}); print(e.get("url"), "#wren-workbench" in e.get("headersHelper",""), "far-secret" in json.dumps(d))' "$T/reg2.json" 2>&1)"
[[ "$R2" == "http://brainbox:7255/mcp True False" ]] && ok_ "registered at the url; the helper reads the route by reference; no token in the registry" || bad "registry 2: $R2"
grep -q '#bookmark' "$T/settings2.json" 2>/dev/null && ok_ "the bookmark hook reads its route by reference" || bad "settings 2: $(head -c 300 "$T/settings2.json" 2>/dev/null)"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
