#!/usr/bin/env bash
# ==============================================================================
#  seren-register-services.sh — make this node's Observatory aware of the
#  Seren services already installed on it.
#
#  WHY THIS EXISTS
#  Observatory reports exactly what it finds in ~/.seren/services/*.json and
#  nothing else. For a long time no installer wrote those files, so a node
#  could be running six healthy services and its own management plane — and
#  Lodestar above it — would report an empty box. setup-seren-service.sh now
#  writes a manifest as part of installing a unit; this script is the backfill
#  for everything installed before that, so nobody has to reinstall a working
#  service just to be seen.
#
#  EVERYTHING IS DERIVED FROM THE RUNNING SYSTEM. The unit list comes from
#  systemd, the config path comes out of the unit's own ExecStart, and the port
#  comes out of that config file. No table of service names, no assumed ports —
#  those are the things that drift, and a manifest that lies about a port is
#  worse than no manifest, because the health check then fails convincingly.
#
#  USAGE
#    ./seren-register-services.sh              # show what it would write
#    ./seren-register-services.sh --apply      # write the manifests
#    ./seren-register-services.sh --apply --force   # overwrite existing ones
# ==============================================================================
set -euo pipefail

G=$'\033[0;32m'; Y=$'\033[1;33m'; R=$'\033[0;31m'; B=$'\033[0;34m'; NC=$'\033[0m'
ok()   { echo -e "${G}  ✓${NC} $*"; }
warn() { echo -e "${Y}  !${NC} $*" >&2; }
info() { echo -e "${B}$*${NC}"; }
die()  { echo -e "${R}ERROR:${NC} $*" >&2; exit 1; }

APPLY=false
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag: $1  (try --help)" ;;
  esac
done

command -v systemctl >/dev/null 2>&1 || die "no systemctl — this is for systemd nodes"

SERVICES_DIR="$HOME/.seren/services"
HEALTH_PATH="/health"

# Units, whether running or not: a stopped service is still installed, and an
# Observatory that only lists what happens to be up is a liar by omission.
mapfile -t UNITS < <(
  systemctl list-unit-files --type=service --no-legend --no-pager 'seren-*.service' 2>/dev/null \
    | awk '{print $1}' | sort -u
)

[[ ${#UNITS[@]} -gt 0 ]] && info "Found ${#UNITS[@]} seren unit(s)" \
  || die "no seren-*.service units found on this node"

$APPLY && mkdir -p "$SERVICES_DIR"
WROTE=0; SKIPPED=0

for unit in "${UNITS[@]}"; do
  name="${unit%.service}"

  # The unit's own ExecStart is the authority on where its config lives.
  execstart="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
  cfg="$(sed -n 's/.*--config[= ]\+\([^ "]*\).*/\1/p' <<<"$execstart" | head -1)"

  # Fall back to the layout the installers use, then give up rather than guess.
  [[ -z "$cfg" && -f "$HOME/$name/$name.yaml" ]] && cfg="$HOME/$name/$name.yaml"

  port=0
  if [[ -n "$cfg" && -f "$cfg" ]]; then
    port="$(python3 - "$cfg" <<'PY' 2>/dev/null || echo 0
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
    print(int(cfg.get("server", {}).get("port", 0)))
except Exception:
    print(0)
PY
)"
  fi

  desc="$(systemctl show -p Description --value "$unit" 2>/dev/null || echo "$name")"
  target="$SERVICES_DIR/${name}.json"

  status="write"
  if [[ -f "$target" ]] && ! $FORCE; then status="exists (use --force)"; fi
  if [[ "$port" == "0" ]]; then
    warn "$name: couldn't resolve a port${cfg:+ from $cfg} — writing port 0, health check will be skipped"
  fi

  printf "  %-26s port=%-6s unit=%-28s %s\n" "$name" "$port" "$unit" "$status"

  if $APPLY && [[ "$status" == "write" ]]; then
    cat > "$target" <<JSON
{
  "schema_version": 2,
  "service": "${name}",
  "service_type": "systemd",
  "systemd_unit": "${unit}",
  "port": ${port},
  "description": "${desc}",
  "config_path": "${cfg}",
  "health_url": "http://127.0.0.1:${port}${HEALTH_PATH}",
  "installed_by": "seren-register-services.sh"
}
JSON
    WROTE=$((WROTE+1))
  else
    SKIPPED=$((SKIPPED+1))
  fi
done

echo
if $APPLY; then
  ok "wrote $WROTE manifest(s), skipped $SKIPPED  ->  $SERVICES_DIR"
  echo -e "  Observatory picks these up on the NEXT REQUEST — no restart needed."
  echo -e "  Check it:  ${B}curl -s http://127.0.0.1:7777/api/v1/system/services${NC}"
else
  warn "dry run — nothing written. Re-run with --apply."
fi
