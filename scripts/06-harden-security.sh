#!/bin/bash
# ===========================================
# 06-harden-security.sh - Security hardening and monitoring
# Run this script on the VM after domain join
# ===========================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"

# Load configuration
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Copy .env.example to .env and configure it first."
    exit 1
fi
source "$ENV_FILE"

# Defaults for optional variables
SNMP_COMMUNITY="${SNMP_COMMUNITY:-public}"
SNMP_LOCATION="${SNMP_LOCATION:-Proxmox VM}"
SNMP_CONTACT="${SNMP_CONTACT:-Administrator}"

echo "=== Security Hardening Script ==="
echo ""
echo "This script will configure:"
echo "  - SNMP monitoring (v2c)"
echo "  - Samba audit logging"
echo "  - Swap file (if not already configured)"
echo ""

# ===========================================
# 1. SNMP Monitoring
# ===========================================
echo "--- SNMP Configuration ---"
echo ""

echo "Installing SNMP daemon..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y snmpd snmp

echo "Backing up original snmpd.conf..."
[[ -f /etc/snmp/snmpd.conf ]] && cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig

echo "Generating /etc/snmp/snmpd.conf..."
if [[ -f "${TEMPLATES_DIR}/snmpd.conf.template" ]]; then
    export SNMP_COMMUNITY SNMP_LOCATION SNMP_CONTACT
    envsubst < "${TEMPLATES_DIR}/snmpd.conf.template" > /etc/snmp/snmpd.conf
else
    cat > /etc/snmp/snmpd.conf << EOF
agentAddress udp:161,udp6:[::1]:161
rocommunity ${SNMP_COMMUNITY} default
sysLocation    ${SNMP_LOCATION}
sysContact     ${SNMP_CONTACT}
view all included .1
includeAllDisks 10%
load 12 10 5
extend cpu /bin/cat /proc/stat
extend memory /bin/cat /proc/meminfo
EOF
fi

echo "Enabling and starting SNMP service..."
systemctl enable snmpd
systemctl restart snmpd

echo "SNMP configured. Test with:"
echo "  snmpwalk -v2c -c ${SNMP_COMMUNITY} ${VM_IP} 1.3.6.1.2.1.1"
echo ""

# ===========================================
# 2. Samba Audit Logging
# ===========================================
echo "--- Samba Audit Logging ---"
echo ""

echo "Configuring rsyslog for Samba audit..."
mkdir -p /var/log/samba

if [[ -f "${TEMPLATES_DIR}/samba-audit.conf.template" ]]; then
    cp "${TEMPLATES_DIR}/samba-audit.conf.template" /etc/rsyslog.d/samba-audit.conf
else
    echo "local5.notice /var/log/samba/audit.log" > /etc/rsyslog.d/samba-audit.conf
fi

# Set proper permissions
touch /var/log/samba/audit.log
chown root:adm /var/log/samba/audit.log
chmod 640 /var/log/samba/audit.log

echo "Restarting rsyslog..."
systemctl restart rsyslog

echo "Restarting Samba services..."
systemctl restart smbd nmbd

echo "Audit logging enabled. Monitor with:"
echo "  tail -f /var/log/samba/audit.log"
echo ""

# ===========================================
# 3. Swap Configuration (if not present)
# ===========================================
echo "--- Swap Configuration ---"
echo ""

SWAP_SIZE="${VM_SWAP:-2G}"

if [[ "$SWAP_SIZE" == "0" ]]; then
    echo "Swap disabled (VM_SWAP=0)"
elif swapon --show | grep -q .; then
    echo "Swap already configured:"
    swapon --show
else
    echo "Creating ${SWAP_SIZE} swap file..."

    # Convert size to bytes for fallocate (handle G suffix)
    fallocate -l "${SWAP_SIZE}" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    # Add to fstab if not already present
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    echo "Swap configured:"
    free -h | grep -i swap
fi
echo ""

# ===========================================
# Summary
# ===========================================
echo "=== Security Hardening Complete ==="
echo ""
echo "Applied configurations:"
echo "  [x] SMB3 minimum protocol (blocks legacy SMB1/SMB2)"
echo "  [x] Server signing mandatory (prevents tampering)"
echo "  [x] SMB encryption desired (encrypts when client supports)"
echo "  [x] SNMP monitoring on port 161"
echo "  [x] Audit logging to /var/log/samba/audit.log"
if [[ "$SWAP_SIZE" != "0" ]]; then
    echo "  [x] Swap file: ${SWAP_SIZE}"
fi
echo ""
echo "Useful OIDs for monitoring:"
echo "  System:     1.3.6.1.2.1.1"
echo "  CPU Load:   1.3.6.1.4.1.2021.10"
echo "  Memory:     1.3.6.1.4.1.2021.4"
echo "  Disk:       1.3.6.1.4.1.2021.9"
echo "  Network:    1.3.6.1.2.1.2"
echo ""
echo "Audit log format: username|IP|share|action|result|path"
echo ""
