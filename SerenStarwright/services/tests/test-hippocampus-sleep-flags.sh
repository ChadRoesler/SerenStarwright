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

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
