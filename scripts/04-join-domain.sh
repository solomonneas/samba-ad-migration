#!/bin/bash
# ===========================================
# 04-join-domain.sh - Join AD domain and configure share
# Run this script on the new VM
# ===========================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Load configuration
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Copy .env.example to .env and configure it first."
    exit 1
fi
source "$ENV_FILE"

echo "=== AD Domain Join Script ==="
echo ""
echo "Domain: $DOMAIN_REALM"
echo ""

# Check if already joined
if net ads testjoin &>/dev/null; then
    echo "This machine is already joined to the domain."
    read -p "Re-join anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping domain join."
    else
        echo "Leaving current domain..."
        net ads leave -k || true
    fi
fi

# Prompt for admin credentials
echo ""
read -p "Enter domain admin username (e.g., Administrator): " ADMIN_USER
if [[ -z "$ADMIN_USER" ]]; then
    echo "ERROR: Username required"
    exit 1
fi

# Kerberos authentication
echo ""
echo "Obtaining Kerberos ticket for ${ADMIN_USER}@${DOMAIN_REALM}..."
kinit "${ADMIN_USER}@${DOMAIN_REALM}"

echo ""
echo "Joining domain..."
net ads join -k

echo ""
echo "Restarting Samba services..."
systemctl restart smbd nmbd winbind
systemctl enable smbd nmbd winbind

echo ""
echo "Waiting for winbind to initialize..."
sleep 5

echo ""
echo "=== Verification ==="
echo ""

echo "1. Trust relationship check (wbinfo -t):"
if wbinfo -t; then
    echo "   [OK] Trust relationship valid"
else
    echo "   [FAILED] Trust check failed"
fi

echo ""
echo "2. Domain users check (wbinfo -u | head -5):"
wbinfo -u | head -5
echo "   ..."

echo ""
echo "3. Testing user resolution (getent passwd ${ADMIN_USER}):"
if getent passwd "${ADMIN_USER}" &>/dev/null; then
    getent passwd "${ADMIN_USER}"
    echo "   [OK] User resolution working"
else
    echo "   [FAILED] Cannot resolve domain users"
    echo "   You may need to wait a moment and retry, or check winbind status"
fi

echo ""
echo "Setting up share permissions on $SHARE_PATH..."
# Ensure share directory exists
mkdir -p "$SHARE_PATH"

# Set ownership - using wbinfo to get the SID-based names
chown "${DOMAIN_SHORT}\Administrator":"${DOMAIN_SHORT}\Domain Users" "$SHARE_PATH" || \
chown "Administrator":"Domain Users" "$SHARE_PATH" || \
echo "WARNING: Could not set ownership. Set manually after winbind fully initializes."

# Set SGID bit for group inheritance
chmod 2770 "$SHARE_PATH"

echo ""
echo "Share permissions:"
ls -la "$SHARE_PATH"

echo ""
echo "=== Domain Join Complete ==="
echo ""
echo "The share should now be accessible at:"
echo "  \\\\${VM_NAME}\\${SHARE_NAME}"
echo "  \\\\${VM_IP}\\${SHARE_NAME}"
echo ""
echo "Test from Windows:"
echo "  net use Z: \\\\${VM_NAME}\\${SHARE_NAME}"
