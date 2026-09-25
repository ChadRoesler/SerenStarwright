#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
#  A card reads a sibling's config for its url and its bearer.
#
#  Proves, with no network and no venv:
#    - host/port from the server block become the url (0.0.0.0 -> 127.0.0.1)
#    - an inline bearer_token, a bearer_token_env name, a keyring ref each
#      come back as the matching yaml line, indented as asked
#    - quotes and trailing comments are stripped; a missing key is empty
#    - an unreadable path returns non-zero and sets nothing
#
#  Run:  bash services/tests/test-sibling-config.sh   (Git Bash is fine)
# ══════════════════════════════════════════════════════════════
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILS=0
ok_()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok_ "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
source "$HERE/services/lib/seren-install-lib.sh"

cat > "$T/memory.yaml" <<'YAML'
# SerenMemory config
server:
  host: 0.0.0.0        # LAN
  port: 7267
  bearer_token: "s3cret-inline"   # the token
storage:
  persist_dir: ~/.seren-memory/chroma
YAML
cat > "$T/loci.yaml" <<'YAML'
server:
  host: '127.0.0.1'
  port: '7266'
  bearer_token_env: SEREN_LOCI_TOKEN
YAML
cat > "$T/margin.yaml" <<'YAML'
server:
  host: 127.0.0.1
  port: 7265
  bearer_token_keyring: "seren-margin/bearer"
YAML
cat > "$T/open.yaml" <<'YAML'
server:
  host: 127.0.0.1
  port: 7421
YAML

echo "== inline bearer, LAN host"
seren_read_sibling_config "$T/memory.yaml"
check "url uses 127.0.0.1 for a 0.0.0.0 bind"   "[[ \"$SIB_URL\" == 'http://127.0.0.1:7267' ]]"
check "inline token, quotes and comment stripped" "[[ \"$SIB_TOKEN\" == 's3cret-inline' ]]"
check "no env / keyring pointer"                 "[[ -z \"$SIB_TOKEN_ENV\" && -z \"$SIB_TOKEN_KEYRING\" ]]"
LINES="$(seren_sibling_token_lines "      ")"
if [[ "$LINES" == '      bearer_token: "s3cret-inline"' ]]; then ok_ "token line indented six"; else bad "token line indented six: [$LINES]"; fi

echo "== env pointer, quoted host and port"
seren_read_sibling_config "$T/loci.yaml"
check "quoted values read"                       "[[ \"$SIB_URL\" == 'http://127.0.0.1:7266' ]]"
check "env pointer, no inline token"             "[[ \"$SIB_TOKEN_ENV\" == 'SEREN_LOCI_TOKEN' && -z \"$SIB_TOKEN\" ]]"
LINES="$(seren_sibling_token_lines "  ")"
check "env pointer becomes bearer_token_env"     "[[ \"$LINES\" == '  bearer_token_env: SEREN_LOCI_TOKEN' ]]"

echo "== keyring pointer"
seren_read_sibling_config "$T/margin.yaml"
LINES="$(seren_sibling_token_lines "  ")"
if [[ "$LINES" == '  bearer_token_keyring: "seren-margin/bearer"' ]]; then ok_ "keyring ref becomes bearer_token_keyring"; else bad "keyring ref becomes bearer_token_keyring: [$LINES]"; fi

echo "== an open store, and a missing file"
seren_read_sibling_config "$T/open.yaml"
check "open store: url only, no token lines"     "[[ \"$SIB_URL\" == 'http://127.0.0.1:7421' && -z \"$(seren_sibling_token_lines '  ')\" ]]"
if seren_read_sibling_config "$T/nope.yaml" 2>/dev/null; then bad "missing file returns non-zero"; else ok_ "missing file returns non-zero"; fi
check "missing file sets nothing"                "[[ -z \"$SIB_URL\" && -z \"$SIB_TOKEN\" ]]"

echo "== only the server block counts (a hippocampus config also holds Memory's bearer)"
cat > "$T/hippo.yaml" <<'YAML'
server:
  host: 127.0.0.1
  port: 7269
memory:
  url: http://127.0.0.1:7267
  bearer_token: "memorys-token-not-mine"
YAML
seren_read_sibling_config "$T/hippo.yaml"
check "server url read"                          "[[ \"$SIB_URL\" == 'http://127.0.0.1:7269' ]]"
check "memory's bearer is not taken as its own"  "[[ -z \"$SIB_TOKEN\" ]]"

echo "== a reinstall keeps the existing bearer"
TOKEN=""
seren_reuse_token "$T/memory.yaml" >/dev/null 2>&1
check "token reused from the existing config"    "[[ \"$TOKEN\" == 's3cret-inline' ]]"
TOKEN=""
seren_reuse_token "$T/hippo.yaml" >/dev/null 2>&1
check "no server token: nothing reused"          "[[ -z \"$TOKEN\" ]]"
TOKEN=""
seren_reuse_token "$T/nope.yaml" >/dev/null 2>&1
check "fresh install: nothing reused, no failure" "[[ -z \"$TOKEN\" ]]"
OUT="$(TOKEN=''; seren_reuse_token "$T/loci.yaml" 2>&1 >/dev/null)"
check "a pointer is warned about, not dropped silently" "grep -q 'bearer_token_env SEREN_LOCI_TOKEN' <<<\"\$OUT\""

echo
echo "  $PASS passed, $FAILS failed"
exit $FAILS
