#!/bin/bash
# scripts/fix-ssh-delay.sh — Fix ~20s SSH connection delay caused by UseDNS
#
# macOS OpenSSH defaults UseDNS to "yes". When Tailscale SSH connects from
# a peer (phone/laptop), sshd performs a reverse-DNS (PTR) lookup on the
# client's 100.x.x.x Tailscale IP. Since DNS is hijacked to the nullexit
# gateway → AdGuard → Cloudflare WARP, and 100.64.0.0/10 is CGNAT private
# space, the PTR query times out (~15-20s) before SSH proceeds.
#
# This script uncomments "UseDNS no" in /etc/ssh/sshd_config and reloads
# sshd. Existing SSH sessions are NOT dropped.
#
# Usage:
#   sudo bash scripts/fix-ssh-delay.sh

set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"

# ─── Check we're root ──────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo (it edits $SSHD_CONFIG)"
    echo "Usage: sudo bash scripts/fix-ssh-delay.sh"
    exit 1
fi

# ─── Apply config (idempotent) ──────────────────────────────────────────
if grep -qE '^UseDNS no' "$SSHD_CONFIG" 2>/dev/null; then
    echo "✓ UseDNS is already set to 'no' in $SSHD_CONFIG"
elif grep -qE '^#UseDNS' "$SSHD_CONFIG" 2>/dev/null; then
    echo "→ Uncommenting 'UseDNS no' in $SSHD_CONFIG"
    sed -i '' 's/^#UseDNS no/UseDNS no/' "$SSHD_CONFIG"
elif grep -qEi '^UseDNS' "$SSHD_CONFIG" 2>/dev/null; then
    echo "→ Changing existing UseDNS line to 'UseDNS no'"
    sed -i '' 's/^UseDNS.*/UseDNS no/' "$SSHD_CONFIG"
else
    echo "→ Appending 'UseDNS no' to $SSHD_CONFIG"
    echo "" >> "$SSHD_CONFIG"
    echo "UseDNS no" >> "$SSHD_CONFIG"
fi

# ─── Verify ────────────────────────────────────────────────────────────────
if ! grep -qE '^UseDNS no' "$SSHD_CONFIG"; then
    echo "✗ Failed to apply UseDNS no — check $SSHD_CONFIG manually"
    exit 1
fi

# ─── Reload sshd (does NOT drop existing connections) ──────────────────────
echo "→ Reloading sshd..."

SSHD_PID=$(pgrep -f /usr/sbin/sshd 2>/dev/null | head -1 || true)
if [ -n "$SSHD_PID" ]; then
    kill -HUP "$SSHD_PID"
    echo "✓ Sent SIGHUP to sshd (PID $SSHD_PID) — config reloaded"
else
    echo "  No running sshd found. macOS starts sshd on-demand per connection."
    echo "  The new 'UseDNS no' config will take effect on the next SSH connection."
fi

echo ""
echo "✓ Done. SSH connections should now connect instantly."
echo "  Existing sessions were not interrupted."
