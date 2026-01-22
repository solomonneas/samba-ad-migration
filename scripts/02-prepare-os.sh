#!/bin/bash
# ===========================================
# 02-prepare-os.sh - Prepare OS for AD integration
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

# Lowercase domain for DNS
DOMAIN_LOWER="${DOMAIN_REALM,,}"

echo "=== OS Preparation Script ==="
echo ""
echo "Configuration:"
echo "  Hostname:   $VM_NAME"
echo "  Domain:     $DOMAIN_REALM"
echo "  Primary DC: $DC_PRIMARY"
[[ -n "${DC_SECONDARY:-}" ]] && echo "  Secondary:  $DC_SECONDARY"
echo ""

# Set hostname
echo "Setting hostname to $VM_NAME..."
hostnamectl set-hostname "$VM_NAME"

# Update /etc/hosts
echo "Updating /etc/hosts..."
# Remove any existing entries for our hostname or DCs
sed -i "/\s${VM_NAME}$/d" /etc/hosts
sed -i "/${DC_PRIMARY}/d" /etc/hosts
[[ -n "${DC_SECONDARY:-}" ]] && sed -i "/${DC_SECONDARY}/d" /etc/hosts

# Add entries
cat >> /etc/hosts << EOF

# AD Domain Controllers
${DC_PRIMARY}    dc1.${DOMAIN_LOWER} dc1
EOF

if [[ -n "${DC_SECONDARY:-}" ]]; then
    echo "${DC_SECONDARY}    dc2.${DOMAIN_LOWER} dc2" >> /etc/hosts
fi

# Add own hostname entry
echo "${VM_IP}    ${VM_NAME}.${DOMAIN_LOWER} ${VM_NAME}" >> /etc/hosts

echo ""
echo "Configuring DNS via systemd-resolved..."

# Create resolved.conf.d if it doesn't exist
mkdir -p /etc/systemd/resolved.conf.d

# Create DNS configuration
cat > /etc/systemd/resolved.conf.d/dns.conf << EOF
[Resolve]
DNS=${DC_PRIMARY}
EOF

if [[ -n "${DC_SECONDARY:-}" ]]; then
    sed -i "s/^DNS=.*/DNS=${DC_PRIMARY} ${DC_SECONDARY}/" /etc/systemd/resolved.conf.d/dns.conf
fi

cat >> /etc/systemd/resolved.conf.d/dns.conf << EOF
Domains=${DOMAIN_LOWER}
EOF

systemctl restart systemd-resolved

echo ""
echo "Installing and configuring chrony for NTP..."
apt-get update
apt-get install -y chrony

# Configure chrony to use DC for time
cat > /etc/chrony/chrony.conf << EOF
# AD Domain Controller as NTP source
server ${DC_PRIMARY} iburst prefer
EOF

if [[ -n "${DC_SECONDARY:-}" ]]; then
    echo "server ${DC_SECONDARY} iburst" >> /etc/chrony/chrony.conf
fi

cat >> /etc/chrony/chrony.conf << EOF

# Record the rate at which the system clock gains/losses time
driftfile /var/lib/chrony/drift

# Enable kernel synchronization of the real-time clock (RTC)
rtcsync

# Allow stepping the clock in first 3 updates if offset > 1 second
makestep 1.0 3

# Specify directory for log files
logdir /var/log/chrony
EOF

systemctl restart chrony

echo ""
echo "Testing DNS resolution..."
echo -n "  Resolving ${DOMAIN_LOWER}: "
if host "${DOMAIN_LOWER}" &>/dev/null; then
    echo "OK"
    host "${DOMAIN_LOWER}" | head -3
else
    echo "FAILED"
    echo "WARNING: DNS resolution failed. Check your DC IP addresses."
fi

echo ""
echo "Testing time synchronization..."
sleep 2  # Give chrony a moment to sync
chronyc tracking | grep -E "^(Reference ID|System time|Leap status)"

echo ""
echo "=== OS Preparation Complete ==="
echo ""
echo "Verify time is synced (< 5 min drift from DC) before joining domain."
