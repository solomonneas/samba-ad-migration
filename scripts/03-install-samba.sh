#!/bin/bash
# ===========================================
# 03-install-samba.sh - Install and configure Samba
# Run this script on the new VM
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

# Lowercase domain for templates
DOMAIN_REALM_LOWER="${DOMAIN_REALM,,}"

echo "=== Samba Installation Script ==="
echo ""
echo "Configuration:"
echo "  Domain:     $DOMAIN_SHORT ($DOMAIN_REALM)"
echo "  Share:      $SHARE_NAME at $SHARE_PATH"
echo ""

echo "Installing Samba and Kerberos packages..."
export DEBIAN_FRONTEND=noninteractive

# Pre-configure krb5-config to avoid interactive prompts
debconf-set-selections <<< "krb5-config krb5-config/default_realm string ${DOMAIN_REALM}"
debconf-set-selections <<< "krb5-config krb5-config/kerberos_servers string ${DC_PRIMARY}"
debconf-set-selections <<< "krb5-config krb5-config/admin_server string ${DC_PRIMARY}"

apt-get update
apt-get install -y \
    samba \
    samba-common-bin \
    winbind \
    libpam-winbind \
    libnss-winbind \
    krb5-user \
    krb5-config

echo ""
echo "Backing up original configuration files..."
[[ -f /etc/krb5.conf ]] && cp /etc/krb5.conf /etc/krb5.conf.orig
[[ -f /etc/samba/smb.conf ]] && cp /etc/samba/smb.conf /etc/samba/smb.conf.orig

echo ""
echo "Generating /etc/krb5.conf from template..."
if [[ -f "${TEMPLATES_DIR}/krb5.conf.template" ]]; then
    export DOMAIN_REALM DC_PRIMARY DC_SECONDARY DOMAIN_REALM_LOWER
    envsubst < "${TEMPLATES_DIR}/krb5.conf.template" > /etc/krb5.conf
else
    # Fallback: generate directly
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = ${DOMAIN_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    ${DOMAIN_REALM} = {
        kdc = ${DC_PRIMARY}
        kdc = ${DC_SECONDARY}
        admin_server = ${DC_PRIMARY}
        default_domain = ${DOMAIN_REALM}
    }

[domain_realm]
    .${DOMAIN_REALM_LOWER} = ${DOMAIN_REALM}
    ${DOMAIN_REALM_LOWER} = ${DOMAIN_REALM}
EOF
fi

echo ""
echo "Generating /etc/samba/smb.conf from template..."
if [[ -f "${TEMPLATES_DIR}/smb.conf.template" ]]; then
    export DOMAIN_SHORT DOMAIN_REALM SHARE_NAME SHARE_PATH
    envsubst < "${TEMPLATES_DIR}/smb.conf.template" > /etc/samba/smb.conf
else
    # Fallback: generate directly
    cat > /etc/samba/smb.conf << EOF
[global]
   workgroup = ${DOMAIN_SHORT}
   realm = ${DOMAIN_REALM}
   security = ads

   idmap config * : backend = tdb
   idmap config * : range = 3000-7999
   idmap config ${DOMAIN_SHORT} : backend = rid
   idmap config ${DOMAIN_SHORT} : range = 10000-999999

   winbind use default domain = yes
   winbind enum users = yes
   winbind enum groups = yes
   template shell = /bin/bash
   template homedir = /home/%U

   vfs objects = acl_xattr
   map acl inherit = yes
   store dos attributes = yes

[${SHARE_NAME}]
   path = ${SHARE_PATH}
   read only = no
   guest ok = no
   valid users = "@${DOMAIN_SHORT}\Domain Users"
   admin users = "@${DOMAIN_SHORT}\Domain Admins"
   create mask = 0770
   directory mask = 0770
   force group = "${DOMAIN_SHORT}\Domain Users"
EOF
fi

echo ""
echo "Updating /etc/nsswitch.conf..."
# Backup
cp /etc/nsswitch.conf /etc/nsswitch.conf.orig

# Update passwd and group lines to include winbind
sed -i 's/^passwd:.*/passwd:         files systemd winbind/' /etc/nsswitch.conf
sed -i 's/^group:.*/group:          files systemd winbind/' /etc/nsswitch.conf

echo ""
echo "Testing Samba configuration..."
testparm -s

echo ""
echo "=== Samba Installation Complete ==="
echo ""
echo "Next: Run 04-join-domain.sh to join the AD domain."
