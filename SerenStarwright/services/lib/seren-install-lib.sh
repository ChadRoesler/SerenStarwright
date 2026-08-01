#!/usr/bin/env bash
# ==========================================================================
#  seren-install-lib.sh  -  Shared installer library for all seren services
#
#  Source this from any seren-X-setup.sh to get common functions:
#    find_python, resolve_wheel, create_venv, pip_install, sanity_check,
#    write_launcher, setup_autostart, print_done
#
#  Memory and Loci are the template leaders — see seren-memory-setup.sh and
#  seren-loci-setup.sh for the canonical reference implementations.
#
#  USAGE (sourced, not exec'd):
#    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#    source "$SCRIPT_DIR/../services/lib/seren-install-lib.sh"  # or find_upward
#
#  Each installer sets its own identity vars, then calls these functions.
#  The only unique part per service is the config YAML content.
# ==========================================================================

# -- guard against multiple sources -------------------------------------------
if [[ -n "${SEREN_INSTALL_LIB_SOURCED:-}" ]]; then return 0; fi
SEREN_INSTALL_LIB_SOURCED=1

# -- OS detection -----------------------------------------------------------
OS="$(uname -s)"
IS_MAC=false; [[ "$OS" == "Darwin" ]] && IS_MAC=true

# ══════════════════════════════════════════════════════════════════════════
#  Machine-readable contracts (for Seren Starwright and anything like it)
# ══════════════════════════════════════════════════════════════════════════
#
#  Two contracts, both opt-in, both invisible unless asked for:
#
#    --describe   print service metadata as JSON on stdout, exit 0.
#                 ZERO side effects: no venv, no network, no python
#                 required. This is how a front-end builds its menu
#                 without hardcoding a table that drifts from reality.
#
#    --json       stream structured events on stdout while installing.
#                 Human output keeps going to stderr exactly as before.
#
#  WHY THE fd JUGGLING BELOW IS THE WHOLE TRICK:
#
#  step/ok/warn/die already wrote to stderr, but each installer ALSO has
#  9-13 bare `echo` banner lines going to stdout. Auditing and editing
#  every one of those would be tedious and easy to get wrong - and one
#  missed echo corrupts the event stream for a parser downstream.
#
#  So instead: stash the real stdout on fd 3, then point fd 1 at stderr.
#  Every existing print in every installer - stdout or stderr, banner or
#  step - now lands on stderr as human output, without a single line of
#  it being edited. fd 3 carries nothing but JSON. Adding a new echo
#  later can't break the stream, because stdout isn't the stream anymore.
#
#  Contract for consumers: stdout is JSON Lines, one object per line, or
#  empty. stderr is for humans. Exit code still means what it always did.
# ══════════════════════════════════════════════════════════════════════════

SEREN_JSON=false

# -- seren_json_on - flip on the event stream (called by --json) ---------------
seren_json_on() {
  exec 3>&1      # fd 3 = the real stdout; events go here and nowhere else
  exec 1>&2      # everything else printed to "stdout" now joins the human log
  SEREN_JSON=true
}

# -- _json_esc - escape a value for a JSON string context ---------------------
# Pure bash substitution, no jq/python dependency: --describe has to work on a
# box that doesn't yet have a usable python, which is the entire point of it.
_json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"      # backslash first, or it double-escapes the others
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# -- emit - write one JSON Lines event ----------------------------------------
#    emit <event> [key value]...
# Values that look like a number/bool/null are emitted bare; everything else is
# a quoted string. No-op unless --json was passed, so every call site is free to
# call it unconditionally.
emit() {
  $SEREN_JSON || return 0
  local ev="$1"; shift
  local out="{\"event\":\"$(_json_esc "$ev")\""
  while [[ $# -gt 1 ]]; do
    local k="$1" v="$2"; shift 2
    if [[ "$v" =~ ^-?[0-9]+$ || "$v" == "true" || "$v" == "false" || "$v" == "null" ]]; then
      out+=",\"$(_json_esc "$k")\":${v}"
    else
      out+=",\"$(_json_esc "$k")\":\"$(_json_esc "$v")\""
    fi
  done
  printf '%s}\n' "$out" >&3
}

# -- seren_flags_from_self - read the caller's OWN accepted flags --------------
# Greps the case branches out of the running installer ($0 is still the parent
# script inside a sourced library) and returns them space-separated.
#
# WHY DERIVE INSTEAD OF DECLARE: a hand-maintained flag list is a second source
# of truth, and second sources of truth drift. That is precisely how the old
# mcp-manifest.yaml ended up advertising a `mark_note_done` tool against a route
# that had been deleted, and how the TUI's SERVICE_DEFS ended up claiming
# seren-margin had no extras the day after --mcp landed. The parser is the only
# thing that actually decides which flags exist, so ask the parser.
#
# Degrades to empty (-> "flags":[]) if $0 isn't readable. Never fails the call.
seren_flags_from_self() {
  [[ -r "${0:-}" ]] || return 0
  grep -oE '^[[:space:]]+--[a-z-]+\)' "$0" 2>/dev/null \
    | tr -d ' )' | sed 's/^--//' | sort -u | tr '\n' ' '
}

# -- seren_describe - the --describe payload ----------------------------------
# Reads the SVC_* identity vars each installer sets alongside its defaults, plus
# PORT/HOST. Must be callable before ANY work happens - see the --describe scan
# each installer runs ahead of its arg loop.
#
# `flags` and `extras` are DERIVED unless explicitly overridden: flags from the
# script's own case branches, extras as the subset of those flags that are
# package extras. Add --whatever to an installer and --describe reports it with
# no second edit.
# SVC_REQUIRES: space-separated service names this one needs ALREADY INSTALLED.
# Declared, not guessed - the only honest source is the config the installer
# writes. seren-corpus-callosum writes a config pre-wired to memory:7420 and
# loci:7422, so it genuinely requires both; nothing else currently does.
#
# A front-end uses this two ways: warn/auto-select when a dependency is missing,
# and topologically sort the install queue so dependencies come up first.
# Sequential installs make the ordering free - you just have to know it.
seren_describe() {
  local extras_json="" flags_json="" requires_json="" f
  local flags="${SVC_FLAGS:-$(seren_flags_from_self)}"
  for f in ${SVC_REQUIRES:-}; do
    requires_json+="${requires_json:+,}\"$(_json_esc "$f")\""
  done
  local extras="${SVC_EXTRAS:-}"
  if [[ -z "$extras" ]]; then
    # The known package-extra flags. Anything else (--port, --service, --pypi)
    # is an installer option, not a pip extra.
    #
    # This is a family-wide allowlist, so it cannot know that a given package
    # declares mcp as a CORE dep rather than an extra (lodestar, workbench).
    # Those installers set SVC_EXTRAS explicitly to override this derivation.
    for f in $flags; do
      case "$f" in mcp|corp|vector|updates) extras+="${extras:+ }$f" ;; esac
    done
  fi
  for f in $extras; do extras_json+="${extras_json:+,}\"$(_json_esc "$f")\""; done
  for f in $flags;  do flags_json+="${flags_json:+,}\"$(_json_esc "$f")\""; done
  printf '{"schema_version":1'
  printf ',"name":"%s"'         "$(_json_esc "${SVC_NAME:-unknown}")"
  printf ',"display":"%s"'      "$(_json_esc "${SVC_DISPLAY:-${SVC_NAME:-unknown}}")"
  printf ',"description":"%s"'  "$(_json_esc "${SVC_DESC:-}")"
  printf ',"group":"%s"'        "$(_json_esc "${SVC_GROUP:-core}")"
  printf ',"package":"%s"'      "$(_json_esc "${SVC_PACKAGE:-}")"
  printf ',"default_host":"%s"' "$(_json_esc "${HOST:-127.0.0.1}")"
  printf ',"default_port":%s'   "${PORT:-0}"
  printf ',"accent":"%s"'       "$(_json_esc "${SVC_ACCENT:-}")"
  printf ',"extras":[%s]'       "$extras_json"
  printf ',"flags":[%s]'        "$flags_json"
  printf ',"requires":[%s]'     "$requires_json"
  printf '}\n'
}

# -- pretty output ----------------------------------------------------------
# Human text on stderr (unchanged), plus a structured twin on fd 3 when --json
# is on. One edit here gives every installer the event stream for free.
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1" >&2; emit step  msg "$1"; }
ok()   { echo -e "${G}  ✓${NC} $1" >&2;   emit ok    msg "$1"; }
warn() { echo -e "${Y}  !${NC} $1" >&2;   emit warn  msg "$1"; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; emit error msg "$1"; exit 1; }

# -- find_upward - locate a file by walking up the tree -----------------------
find_upward() {
  local rel="$1" dir="${2:-$SCRIPT_DIR}"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

# -- find_python - locate Python 3.10-3.12 ------------------------------------
find_python() {
  local PYBIN=""
  for cand in python3.12 python3.11 python3.10 python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
      ver="$("$cand" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
      case "$ver" in 3.10|3.11|3.12) PYBIN="$cand"; break ;; esac
    fi
  done
  if [[ -z "$PYBIN" ]]; then
    die "No Python 3.10-3.12 found.
  Install one, e.g.:
    macOS:          brew install python@3.12
    Debian/Ubuntu:  sudo apt install python3.12 python3.12-venv
    Fedora:         sudo dnf install python3.12
    Arch:           sudo pacman -S python
  (Avoid 3.13+ for now - some dependencies can't build there yet.)"
  fi
  PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
  ok "Using $PYBIN (Python $PYVER)"
  echo "$PYBIN"
}

# -- resolve_wheel - determine install source (local wheel / GitHub / PyPI) ----
# Sets: WHEEL_SRC, CLEANUP_WHEEL
# Reads: WHEEL, REF, REPO, PACKAGE, PYBIN
resolve_wheel() {
  WHEEL_SRC=""
  CLEANUP_WHEEL=false
  if [[ -n "${WHEEL:-}" ]]; then
    [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
    WHEEL_SRC="$WHEEL"
    ok "Installing from local wheel: $(basename "$WHEEL")"
  elif [[ -n "${REPO:-}" ]]; then
    step "Resolving the $PACKAGE release from GitHub ($REPO)"
    command -v curl >/dev/null 2>&1 || die "curl is required (sudo apt install curl)"
    local api
    api="https://api.github.com/repos/${REPO}/releases/${REF:+tags/$REF}"
    [[ -z "${REF:-}" ]] && api="https://api.github.com/repos/${REPO}/releases/latest"
    local json
    json="$(curl -fsSL "$api" 2>/dev/null)" || die "GitHub API request failed ($api)"
    local TAG WHL_URL
    read -r TAG WHL_URL < <(echo "$json" | "$PYBIN" -c '
import json,sys; d=json.load(sys.stdin)
tag=d.get("tag_name","?")
whl=next((a["browser_download_url"] for a in d.get("assets",[]) if a.get("name","").endswith(".whl")),"")
print(tag,whl)
')
    [[ -n "$WHL_URL" && "$WHL_URL" != "None" ]] || die "No .whl asset in release '$TAG'"
    ok "Release $TAG  ($(basename "$WHL_URL"))"
    WHEEL_SRC="$(mktemp /tmp/seren_XXXXXX.whl)"
    CLEANUP_WHEEL=true
    trap '[[ "$CLEANUP_WHEEL" == true ]] && rm -f "$WHEEL_SRC"' EXIT
    curl -fsSL "$WHL_URL" -o "$WHEEL_SRC" || die "download failed"
    ok "Downloaded"
  else
    WHEEL_SRC="$PACKAGE"
    ok "Installing $PACKAGE from PyPI"
  fi
}

# -- create_venv - make or reuse a venv ----------------------------------------
create_venv() {
  local venv_dir="$1"
  step "Creating venv at $venv_dir"
  if [[ -x "$venv_dir/bin/python" ]]; then
    warn "venv already exists - reusing it (will upgrade the package)"
  else
    "$PYBIN" -m venv "$venv_dir" || die "venv creation failed (need python3-venv?)"
    ok "venv created"
  fi
}

# -- pip_install - install the package with optional extras --------------------
pip_install() {
  local vpy="$1" src="$2" extras="$3"
  local corp_flag="$4" desc="$5"
  step "Installing ${src}${extras}${desc}"
  "$vpy" -m pip install -q --upgrade pip
  # shellcheck disable=SC2086
  "$vpy" -m pip install -q --upgrade $corp_flag "${src}${extras}" || die "pip install failed"
  ok "Installed"
}

# -- pip_corp_args - get pip truststore flag if supported ----------------------
pip_corp_args() {
  $CORP || { echo ""; return 0; }
  local pipver major minor
  pipver="$("$VPY" -m pip --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  major="${pipver%%.*}"; minor="${pipver#*.}"
  if (( major > 24 || (major == 24 && minor >= 2) )); then
    echo "--use-feature=truststore"
  fi
}

# -- sanity_check - verify package imports and viewer asset --------------------
sanity_check() {
  local vpy="$1" module="$2" viewer="$3"
  step "Sanity-checking the install"
  local check
  check="$("$vpy" -c "
import pathlib
try:
    import ${module}
except Exception as e:
    print(f'IMPORT_FAILED: {e}'); raise SystemExit
v = pathlib.Path(${module}.__file__).parent / 'viewer' / '${viewer}'
print('OK' if v.exists() else 'VIEWER_MISSING')
" 2>/dev/null)" || check="FAILED"
  case "$check" in
    OK) ok "Package imports and the viewer asset is present" ;;
    VIEWER_MISSING) warn "Package installed but $viewer is missing - /viewer will 404" ;;
    *) die "Install looks broken: $check" ;;
  esac
}

# -- write_launcher - drop the run script --------------------------------------
write_launcher() {
  local app_dir="$1" service="$2" vpy="$3" module="$4" config_path="$5"
  local launcher="$app_dir/run-${service}.sh"
  cat > "$launcher" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$vpy" -m ${module} --config "$config_path"
LAUNCHEOF
  chmod +x "$launcher"
  ok "Launcher written: $launcher"
}

# -- setup_autostart - delegate to pointed service wrapper ---------------------
setup_autostart() {
  local script_dir="$1" service="$2" app_dir="$3" token="$4" instance="$5"
  local venv_override="${6:-}"
  step "Installing the autostart service"
  local wrapper
  wrapper="$script_dir/setup-${service#seren-}-service.sh"
  local core
  core="$(find_upward "services/lib/setup-seren-service.sh")"
  if [[ -f "$wrapper" && -f "$core" ]]; then
    if [[ -n "$token" ]]; then
      local env_var="${service^^}_BEARER_TOKEN"
      env_var="${env_var//-/_}"
      printf '%s=%s\n' "$env_var" "$token" > "$app_dir/${service}.env"
      chmod 600 "$app_dir/${service}.env"
    fi
    local venv_flag=""
    [[ -n "$venv_override" ]] && venv_flag="--venv $venv_override"
    bash "$wrapper" $venv_flag --instance "$instance" || die "service install failed"
  else
    warn "setup-${service#seren-}-service.sh not found. Run it manually:"
    warn "  bash setup-${service#seren-}-service.sh --instance '${instance}'"
  fi
}

# -- print_done - the final banner --------------------------------------------
#
# CURRENTLY UNUSED: every seren-*-setup.sh prints its own tailored banner
# instead. Kept because it's the obvious thing to reach for when adding an
# eighth service - which is exactly why the guards below matter.
#
# LANDMINE THAT WAS HERE: this read $MCP, $CORP and $VECTOR bare, while every
# installer runs `set -euo pipefail`. Six of the seven don't define all three
# (observatory has no MCP at all; only loci defines VECTOR), so the first
# script to actually call this would have died on `VECTOR: unbound variable`
# after a successful install - the worst possible moment. ${VAR:-false}
# throughout, so it's safe for any caller.
print_done() {
  local service="$1" host="$2" port="$3" install_service="$4" token="$5"
  local connect_host="$host"
  [[ "$host" == "0.0.0.0" ]] && connect_host="127.0.0.1"
  echo
  echo -e "${G}==========================================${NC}"
  echo -e "${G}  ${service^} is set up ✓${NC}"
  echo -e "${G}==========================================${NC}"
  echo -e "  Viewer:          ${B}http://${connect_host}:${port}/viewer${NC}"
  [[ -n "$token" ]] && echo -e "  Bearer token:    ${Y}${token}${NC}"
  echo
  ${MCP:-false}    && echo -e "  MCP endpoint:    ${B}http://${connect_host}:${port}/mcp/${NC}"
  ${CORP:-false}   && echo -e "  TLS:             ${B}OS trust store${NC}"
  ${VECTOR:-false} && echo -e "  Finder:          ${B}vector (sqlite-vec + all-MiniLM-L6-v2)${NC}"
  echo -e "${G}Rip it and win. 🌭🔧${NC}"
  seren_emit_done "$service" "$connect_host" "$port" "$install_service" "$token"
}

# -- seren_emit_done - the structured completion event -------------------------
# The one event a front-end actually needs: did it work, and where is the thing
# now. Called at the end of each installer next to its own banner (and by
# print_done, for any future caller). No-op without --json.
seren_emit_done() {
  local service="$1" connect_host="$2" port="$3" install_service="$4" token="$5"
  emit done \
    ok        true \
    service   "$service" \
    host      "$connect_host" \
    port      "$port" \
    url       "http://${connect_host}:${port}" \
    autostart "${install_service:-false}" \
    mcp       "${MCP:-false}" \
    corp      "${CORP:-false}" \
    vector    "${VECTOR:-false}" \
    venv      "${VENV_DIR:-}" \
    config    "${CFG_PATH:-}" \
    has_token "$([[ -n "$token" ]] && echo true || echo false)"
}
