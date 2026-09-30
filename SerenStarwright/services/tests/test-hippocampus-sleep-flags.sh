#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  The hippocampus card: bedtime and the draft cap.
#
#  Design note: the sleep schedule (a time, or every X hours) and the
#  draft cap (max rounds of draft and critique, so no endless loop) must be
#  configurable - they existed in the config but no card ever wrote them, so
#  nobody could see them. Proves:
#    - a bad value is refused with its reason before anything is installed
#    - the sleep block the card writes: the given values active, the rest
#      commented with their defaults (visible, and a hand edit survives a
#      reinstall because a commented key is a missing key to keep-config)
#
#  Run:  bash services/tests/test-hippocampus-sleep-flags.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CARD="$HERE/services/bash/seren-hippocampus-setup.sh"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== bad values are refused before anything happens"
refused() {   # refused LABEL WANT -- args...
  local label="$1" want="$2"; shift 2
  local out; out="$(HOME="$T/home" bash "$CARD" "$@" 2>&1)"; local rc=$?
  if [[ $rc -ne 0 && "$out" == *"$want"* && ! -e "$T/home/seren-venvs" ]]; then ok_ "$label"; else bad "$label (rc=$rc): $out"; fi
}
mkdir -p "$T/home"
refused "--sleep-at 25:00"        "wants HH:MM"   --sleep-at 25:00
refused "--sleep-at 3pm"          "wants HH:MM"   --sleep-at 3pm
refused "--sleep-every 0.05 (3m)" "at least 0.17" --sleep-every 0.05
refused "--sleep-every abc"       "wants hours"   --sleep-every abc
refused "--max-attempts 0"        "wants 1-10"    --max-attempts 0
refused "--max-attempts 11"       "wants 1-10"    --max-attempts 11
refused "--ripple carrier-pigeon"   "wants script, endpoint or off" --ripple carrier-pigeon
refused "--ripple endpoint, no url" "needs --ripple-url" --ripple endpoint
refused "--model-server alone"    "needs --model-path" --model-server /opt/llama-server

echo "== the sleep block"
# The block's three lines, evaluated as the card evaluates them.
render() {   # render SLEEP_AT SLEEP_EVERY_SECONDS MAX_ATTEMPTS
  local lines; lines="$(awk '/^sleep:$/{on=1;next} on&&/^YAML$/{exit} on' "$CARD" | grep '^\$(')"
  SLEEP_AT="$1" SLEEP_EVERY_SECONDS="$2" MAX_ATTEMPTS="$3" bash -c "while IFS= read -r l; do eval \"echo \\\"\$l\\\"\"; done <<'L'
$lines
L"
}
out="$(render "" "" "")"
[[ "$out" == *'# at: "03:30"'* && "$out" == *'# interval_seconds: 72000'* && "$out" == *'# max_attempts: 3'* ]] \
  && ok_ "no flags: all three visible, commented with their defaults" || bad "no flags: $out"
out="$(render "03:30" "" "5")"
[[ "$out" == *'  at: "03:30"'* && "$out" != *'# at:'* && "$out" == *'  max_attempts: 5'* && "$out" == *'# interval_seconds'* ]] \
  && ok_ "flags given: active, the rest still commented" || bad "flags: $out"
out="$(render "" "21600" "")"
[[ "$out" == *'  interval_seconds: 21600'* ]] && ok_ "--sleep-every 6 becomes interval_seconds 21600" || bad "every: $out"
grep -q 'SLEEP_EVERY_SECONDS="$(awk' "$CARD" && ok_ "hours are converted to seconds by the card" || bad "no hour conversion"

echo "== the model lifecycle and the ripple (28 Sept 2026)"
# The card builds both blocks before writing the config; run that part alone,
# then parse the result as YAML, so quoting (a Windows path, a quote in the
# command) is checked by a real parser and not by eye.
block() {   # block VAR=value ... ; prints the config the two blocks produce
  local body; body="$(awk '/^# The model lifecycle and the ripple/{on=1} on{print} on&&/^esac$/{exit}' "$CARD")"
  env "$@" HOME="$T/home" bash -c 'die() { echo "DIE: $*"; exit 3; }
'"$body"'
printf "model:
  url: x
%s
%s
" "$MODEL_LIFECYCLE_LINES" "$RIPPLE_LINES"'
}
PYY=""
for c in python3 python; do "$c" -c 'import yaml' >/dev/null 2>&1 && { PYY="$c"; break; }; done
[[ -n "$PYY" ]] || bad "no Python with PyYAML on PATH - these checks parse the card's YAML (pip install pyyaml)"
yamlget() {   # yamlget EXPR  (stdin = yaml; d is the parsed document)
  "$PYY" -c "import sys, yaml; d = yaml.safe_load(sys.stdin); print(repr($1))" 2>&1
}
out="$(block MODEL_SERVER='C:\llama\llama-server.exe' MODEL_PATH="C:\models\it's-q5.gguf" MODEL_ARGS='-ngl 99 -fa on' \
  | yamlget "d['model']['lifecycle'] == {'server': r'C:\llama\llama-server.exe', 'model_path': r\"C:\models\it's-q5.gguf\", 'server_args': '-ngl 99 -fa on'}")"
[[ "$out" == "True" ]] && ok_ "lifecycle: Windows paths and a quote survive as YAML" || bad "lifecycle: $out"
mkdir -p "$T/home/llama.cpp/build/bin"; printf '#!/bin/sh
' > "$T/home/llama.cpp/build/bin/llama-server"; chmod +x "$T/home/llama.cpp/build/bin/llama-server"
out="$(block MODEL_PATH=/mnt/nvme/models/q.gguf | yamlget "d['model']['lifecycle']['server']")"
[[ "$out" == *"/llama.cpp/build/bin/llama-server"* ]] && ok_ "on a node the llama component is the default server" || bad "node default: $out"
out="$(block | yamlget "d")"
[[ "$out" != *lifecycle* && "$out" != *ripple* ]] && ok_ "no flags: neither block is written (keep-config keeps the old ones)" || bad "unset: $out"
out="$(block RIPPLE=script | yamlget "(d['ripple']['type'], d['ripple']['command'])")"
[[ "$out" == "('script', 'claude -p \"{message}\"')" ]] && ok_ "--ripple script defaults to claude -p \"{message}\"" || bad "script default: $out"
out="$(block RIPPLE=endpoint RIPPLE_URL=http://127.0.0.1:6361/hooks/ripple | yamlget "(d['ripple']['type'], d['ripple']['url'])")"
[[ "$out" == "('endpoint', 'http://127.0.0.1:6361/hooks/ripple')" ]] && ok_ "--ripple endpoint writes the url" || bad "endpoint: $out"
out="$(block RIPPLE=off | yamlget "d['ripple']")"
[[ "$out" == "{'type': ''}" ]] && ok_ "--ripple off writes type \"\" only (keep-config keeps the command for next time)" || bad "off: $out"
me="$(id -un)"
out="$(block RIPPLE=script | yamlget "d['ripple']['run_as']")"
[[ "$out" == "'$me'" ]] && ok_ "--ripple script runs as the person installing it ($me) unless told otherwise" || bad "run_as default: $out"
out="$(block RIPPLE=script RIPPLE_RUN_AS=wren | yamlget "d['ripple']['run_as']")"
[[ "$out" == "'wren'" ]] && ok_ "--ripple-run-as names someone else" || bad "run_as: $out"
out="$(block RIPPLE=endpoint RIPPLE_URL=http://desktop:7777/api/v1/system/ripple RIPPLE_TOKEN="t'0k" \
  | yamlget "(d['ripple']['url'], d['ripple']['bearer_token'])")"
[[ "$out" == "('http://desktop:7777/api/v1/system/ripple', \"t'0k\")" ]] \
  && ok_ "--ripple endpoint carries the desktop Observatory's bearer" || bad "endpoint token: $out"
out="$(block RIPPLE=script RIPPLE_STDIN=true RIPPLE_COMMAND='ssh desktop claude -p' | yamlget "(d['ripple']['command'], d['ripple'].get('stdin'))")"
[[ "$out" == "('ssh desktop claude -p', True)" ]] && ok_ "--ripple-stdin: the message goes on stdin (ssh with no Lodestar or Observatory)" || bad "stdin: $out"
out="$(block RIPPLE=script | yamlget "d['ripple'].get('stdin')")"
[[ "$out" == "None" ]] && ok_ "without --ripple-stdin no stdin line is written" || bad "stdin default: $out"
bash "$CARD" --describe | grep -q '"choices":{"ripple":\["script","endpoint","off"\]}'   && ok_ "--describe offers the ripple as a choice" || bad "no ripple choices in --describe"

echo "== --voice-card (opt in; 29 Sept 2026)"
bash "$CARD" --describe | grep -q '"switches":\[[^]]*"voice-card"' && ok_ "--voice-card is a switch (a checkbox in the TUI)" || bad "--voice-card is not a switch"
vline="$(grep -E '^\$VOICE_CARD && printf' "$CARD")"
: > "$T/voice.yaml"
VOICE_CARD=true CFG_PATH="$T/voice.yaml" bash -c "$vline"
out="$(yamlget "d['voice']" < "$T/voice.yaml")"
[[ "$out" == "{'enabled': True}" ]] && ok_ "--voice-card: voice.enabled true, and no card text (the model writes that)" || bad "voice: $out"
: > "$T/voice.yaml"
VOICE_CARD=false CFG_PATH="$T/voice.yaml" bash -c "$vline"
[[ ! -s "$T/voice.yaml" ]] && ok_ "without it nothing is written (keep-config keeps an earlier opt in)" || bad "voice written without the flag"

echo "== --model-max-tokens and --keep-warm (30 Sept 2026)"
# The first sleep that ran on its own lost 7 of 11 answers to a 900-token cap
# nobody could set from the installer.
d="$(bash "$CARD" --describe)"
for f in model-max-tokens keep-warm; do
  grep -q "\"$f\"" <<<"$d" && ok_ "--describe offers --$f" || bad "--describe is missing --$f"
done
out="$(bash "$CARD" --model-max-tokens 12 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"256 or more"* ]] && ok_ "--model-max-tokens 12 is refused before anything installs" || bad "low cap: rc=$rc $out"
mline="$(grep -F 'MODEL_MAX_TOKENS" ]] && printf' "$CARD")"
printf 'cat <<YAML
model:
  url: x
%s
YAML
' "$mline" > "$T/m.sh"
out="$(MODEL_MAX_TOKENS=4096 bash "$T/m.sh" | yamlget "d['model'].get('max_tokens')")"
[[ "$out" == "4096" ]] && ok_ "--model-max-tokens 4096 writes model.max_tokens, in the model block" || bad "max_tokens: $out"
out="$(MODEL_MAX_TOKENS="" bash "$T/m.sh" | yamlget "d['model'].get('max_tokens')")"
[[ "$out" == "None" ]] && ok_ "without it the key is a comment (the config default, or the old value, applies)" || bad "unset: $out"

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
