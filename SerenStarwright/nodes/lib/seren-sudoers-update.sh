#!/bin/bash
# ══════════════════════════════════════════════════════════════
# seren-sudoers-update.sh — add reboot grants to existing installs
#
# When the reboot endpoint shipped, the agent's sudoers grant grew
# to include /sbin/shutdown -r * and /sbin/shutdown -c. Existing
# installs were created BEFORE that change so their sudoers file
# is missing the new lines.
#
# This script appends the missing grants to /etc/sudoers.d/seren-agent
# WITHOUT re-running the entire install_agent_common flow. Idempotent —
# safe to run multiple times.
#
# Use this for fleet-wide rollout of the reboot feature on a cluster
# that's already up:
#   for h in node1 node2 node3; do   # your hostnames
#       scp seren-sudoers-update.sh youruser@$h:/tmp/
#       ssh youruser@$h 'bash /tmp/seren-sudoers-update.sh -u youruser'
#   done
#
# Usage:
#   bash seren-sudoers-update.sh [-u USER]
#
# Options:
#   -u, --user USER     Target user whose sudoers grants we update
#                       (default: $SUDO_USER, then $USER)
#   -h, --help          Show this help
# ══════════════════════════════════════════════════════════════

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SUDOERS-UPDATE]${NC} $1"; }
warn() { echo -e "${YELLOW}[SUDOERS-UPDATE]${NC} $1"; }
fail() { echo -e "${RED}[SUDOERS-UPDATE]${NC} $1" >&2; }

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

usage() {
    cat <<'EOF'
Usage: bash seren-sudoers-update.sh [OPTIONS]

Adds /sbin/shutdown -r * and /sbin/shutdown -c grants to the existing
/etc/sudoers.d/seren-agent file, enabling the agent's reboot endpoint
to work without re-running full host-setup.sh / seren-prepare-node.sh.

Options:
  -u, --user USER     Target user (default: invoking user)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)  TARGET_USER="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          fail "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────
if ! id "$TARGET_USER" &>/dev/null; then
    fail "User '$TARGET_USER' does not exist"
    exit 1
fi

SUDOERS_FILE="/etc/sudoers.d/seren-agent"

if [ ! -f "$SUDOERS_FILE" ]; then
    fail "$SUDOERS_FILE not found — agent isn't installed on this box yet."
    fail "Run host-setup.sh / seren-prepare-node.sh first; this migration only"
    fail "patches an existing install."
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# Idempotency check — if we've already added the grants, exit clean
# ─────────────────────────────────────────────────────────────
if sudo grep -q '/sbin/shutdown -r' "$SUDOERS_FILE" \
    && sudo grep -q '/sbin/shutdown -c' "$SUDOERS_FILE"; then
    log "Sudoers already has the reboot grants — nothing to do ✓"
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Append the new grants
# ─────────────────────────────────────────────────────────────
log "Adding /sbin/shutdown grants for user '$TARGET_USER'..."

# Make a backup so the rollback path is one mv command
BACKUP="$SUDOERS_FILE.bak.$(date +%s)"
sudo cp "$SUDOERS_FILE" "$BACKUP"
log "Backup: $BACKUP"

# Append. Use sudo tee -a to handle the >> redirection through sudo.
sudo tee -a "$SUDOERS_FILE" > /dev/null << EOF

# Reboot grants — added by seren-sudoers-update.sh on $(date -Iseconds)
# Used by the agent's POST /api/v1/system/reboot and /reboot/cancel endpoints.
$TARGET_USER ALL=(root) NOPASSWD: /sbin/shutdown -r *
$TARGET_USER ALL=(root) NOPASSWD: /sbin/shutdown -c
EOF

# ─────────────────────────────────────────────────────────────
# Validate. Sudoers files are touchy — visudo -c rejects malformed
# entries. If we corrupted the file, restore from backup immediately.
# (A bad sudoers file can lock you out of sudo entirely until reboot.)
# ─────────────────────────────────────────────────────────────
if ! sudo visudo -cf "$SUDOERS_FILE" >/dev/null; then
    fail "visudo rejected the modified file — restoring from backup"
    sudo mv "$BACKUP" "$SUDOERS_FILE"
    sudo chmod 440 "$SUDOERS_FILE"
    fail "Original restored. The grants were NOT added."
    exit 1
fi

# Reset perms (cp preserves them but be defensive)
sudo chmod 440 "$SUDOERS_FILE"

# ─────────────────────────────────────────────────────────────
# Verify the agent can actually use the new grant. We don't run
# `sudo shutdown -r +1` (we'd reboot the box!) but we do test the
# sudoers parsing with `sudo -n -l` which prints what the user is
# allowed to run. If our line is in there, sudoers worked.
# ─────────────────────────────────────────────────────────────
if sudo -u "$TARGET_USER" sudo -n -l 2>/dev/null | grep -q '/sbin/shutdown -r'; then
    log "Verified: $TARGET_USER can run /sbin/shutdown -r without password ✓"
else
    warn "Sudoers updated but verification didn't confirm the grant."
    warn "Try: sudo -u $TARGET_USER sudo -n -l | grep shutdown"
    warn "(Not necessarily a failure — some sudo versions don't expand wildcards in -l output.)"
fi

log ""
log "════════════════════════════════════════════════════════════"
log "  Sudoers updated ✓"
log "════════════════════════════════════════════════════════════"
log "  File:    $SUDOERS_FILE"
log "  Backup:  $BACKUP  (delete when you're sure things work)"
log ""
log "  The agent's /api/v1/system/reboot endpoint is now usable."
log "  You don't need to restart seren-agent.service — sudoers"
log "  changes take effect on the next sudo invocation."
log "════════════════════════════════════════════════════════════"
