#!/usr/bin/env bash

# ===========================================
# Samba AD File Server - Proxmox Helper Script
# Run on Proxmox host:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/solomonneas/samba-ad-migration/main/samba-ad.sh)"
# ===========================================

set -euo pipefail

# Colors
RD='\033[0;31m'
GN='\033[0;32m'
YW='\033[0;33m'
BL='\033[0;34m'
CY='\033[0;36m'
WH='\033[0;37m'
BLD='\033[1m'
NC='\033[0m'

# Header
clear
echo -e "${BL}"
cat << "EOF"
   _____ ___    __  _______  ___       ___    ____
  / ___//   |  /  |/  / __ )/   |     /   |  / __ \
  \__ \/ /| | / /|_/ / __  / /| |    / /| | / / / /
 ___/ / ___ |/ /  / / /_/ / ___ |   / ___ |/ /_/ /
/____/_/  |_/_/  /_/_____/_/  |_|  /_/  |_/_____/

EOF
echo -e "${NC}"
echo -e "${CY}        ┌──────────────────────────────────────────┐${NC}"
echo -e "${CY}        │${NC}  ${BLD}Proxmox VM Installer${NC} - AD File Server  ${CY}│${NC}"
echo -e "${CY}        │${NC}    Samba + Winbind + Domain Integration   ${CY}│${NC}"
echo -e "${CY}        └──────────────────────────────────────────┘${NC}"
echo ""

# Check if running on Proxmox
if ! command -v pvesh &>/dev/null; then
    echo -e "${RD}ERROR: This script must be run on a Proxmox VE host${NC}"
    exit 1
fi

# Helper functions
msg_info() { echo -e "${BL}[INFO]${NC} $1"; }
msg_ok() { echo -e "${GN}[OK]${NC} $1"; }
msg_warn() { echo -e "${YW}[WARN]${NC} $1"; }
msg_error() { echo -e "${RD}[ERROR]${NC} $1"; exit 1; }

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${CY}$prompt_text${NC} [${WH}$default${NC}]: ")" value
        value="${value:-$default}"
    else
        read -rp "$(echo -e "${CY}$prompt_text${NC}: ")" value
    fi
    eval "$var_name=\"$value\""
}

prompt_password() {
    local var_name="$1"
    local prompt_text="$2"
    local value
    local value_confirm

    while true; do
        read -srp "$(echo -e "${CY}$prompt_text${NC}: ")" value
        echo ""
        read -srp "$(echo -e "${CY}Confirm password${NC}: ")" value_confirm
        echo ""
        if [[ "$value" == "$value_confirm" ]]; then
            break
        else
            echo -e "${RD}Passwords do not match. Try again.${NC}"
        fi
    done
    printf -v "$var_name" '%s' "$value"
}

# ===========================================
# Gather Configuration
# ===========================================
echo -e "${BLD}${WH}── Domain Configuration ──${NC}"
prompt DOMAIN_SHORT "NetBIOS domain name (e.g., CONTOSO)"
prompt DOMAIN_REALM "Domain FQDN in UPPERCASE (e.g., CONTOSO.LOCAL)"
prompt DC_PRIMARY "Primary Domain Controller IP"
prompt DC_SECONDARY "Secondary Domain Controller IP (or leave empty)" ""

echo ""
echo -e "${BLD}${WH}── VM Configuration ──${NC}"
prompt VM_NAME "VM hostname" "prox-fileserv"
prompt VM_IP "VM IP address"
prompt VM_NETMASK "Netmask (CIDR)" "24"
prompt VM_GATEWAY "Gateway IP"
prompt VM_CORES "CPU cores" "4"
prompt VM_RAM "RAM in MB" "8192"

echo ""
echo -e "${BLD}${WH}── Storage Configuration ──${NC}"

# Get available storage pools
echo -e "${CY}Available storage pools:${NC}"
pvesm status | awk 'NR>1 {print "  " $1 " (" $2 ")"}'
echo ""
prompt STORAGE_POOL "Storage pool for VM disks" "local-lvm"
prompt OS_DISK_SIZE "OS disk size" "32G"
prompt DATA_DISK_SIZE "Data disk size in GB" "4000"

echo ""
echo -e "${BLD}${WH}── Network Configuration ──${NC}"
# Get available bridges
echo -e "${CY}Available bridges:${NC}"
ip -o link show type bridge | awk -F': ' '{print "  " $2}'
echo ""
prompt BRIDGE "Network bridge" "vmbr0"
prompt VLAN_TAG "VLAN tag (leave empty for none)" ""
prompt ENABLE_FIREWALL "Enable Proxmox firewall? (y/n)" "n"

echo ""
echo -e "${BLD}${WH}── Share Configuration ──${NC}"
prompt SHARE_PATH "Share mount path" "/srv/fileshare"
prompt SHARE_NAME "SMB share name" "Shared"

echo ""
echo -e "${BLD}${WH}── VM Credentials ──${NC}"
prompt VM_USER "VM username" "samba"
prompt_password VM_PASSWORD "VM password"

# ===========================================
# Confirmation
# ===========================================
echo ""
echo -e "${BLD}${WH}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLD}Configuration Summary:${NC}"
echo -e "  Domain:      ${WH}$DOMAIN_SHORT${NC} (${DOMAIN_REALM})"
echo -e "  DCs:         ${WH}$DC_PRIMARY${NC}${DC_SECONDARY:+, $DC_SECONDARY}"
echo -e "  VM:          ${WH}$VM_NAME${NC} @ ${VM_IP}/${VM_NETMASK}"
echo -e "  Resources:   ${WH}${VM_CORES}${NC} cores, ${WH}${VM_RAM}${NC} MB RAM"
echo -e "  Storage:     ${WH}${OS_DISK_SIZE}${NC} OS + ${WH}${DATA_DISK_SIZE}G${NC} data on ${STORAGE_POOL}"
echo -e "  Network:     ${WH}${BRIDGE}${NC}${VLAN_TAG:+ (VLAN $VLAN_TAG)}${ENABLE_FIREWALL:+ [Firewall: $ENABLE_FIREWALL]}"
echo -e "  Share:       ${WH}\\\\${VM_NAME}\\${SHARE_NAME}${NC} → ${SHARE_PATH}"
echo -e "${BLD}${WH}═══════════════════════════════════════════════════════════════${NC}"
echo ""

read -rp "$(echo -e "${YW}Proceed with installation? [y/N]:${NC} ")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ===========================================
# Auto-detect VMID
# ===========================================
msg_info "Detecting next available VMID..."
# Get all VMIDs using qm and pct list (no jq required)
EXISTING_IDS=$({ qm list 2>/dev/null | awk 'NR>1 {print $1}'; pct list 2>/dev/null | awk 'NR>1 {print $1}'; } | sort -n)
VMID=100
for id in $EXISTING_IDS; do
    if [[ "$id" -eq "$VMID" ]]; then
        VMID=$((VMID + 1))
    fi
done
msg_ok "Using VMID: $VMID"

# ===========================================
# Download Ubuntu Cloud Image
# ===========================================
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMAGE="/var/lib/vz/template/iso/ubuntu-24.04-cloudimg.img"

if [[ ! -f "$UBUNTU_IMAGE" ]]; then
    msg_info "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$UBUNTU_IMAGE" "$UBUNTU_IMAGE_URL"
    msg_ok "Download complete"
else
    msg_ok "Ubuntu cloud image already exists"
fi

# ===========================================
# Create VM
# ===========================================
msg_info "Creating VM $VMID ($VM_NAME)..."

qm create "$VMID" \
    --name "$VM_NAME" \
    --cores "$VM_CORES" \
    --memory "$VM_RAM" \
    --ostype l26 \
    --agent enabled=1 \
    --scsihw virtio-scsi-single

# Network
NET_CONFIG="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NET_CONFIG+=",tag=${VLAN_TAG}"
[[ "$ENABLE_FIREWALL" =~ ^[Yy]$ ]] && NET_CONFIG+=",firewall=1"
qm set "$VMID" --net0 "$NET_CONFIG"

msg_ok "VM created"

# ===========================================
# Configure Storage
# ===========================================
msg_info "Importing OS disk..."
qm importdisk "$VMID" "$UBUNTU_IMAGE" "$STORAGE_POOL" --format raw >/dev/null
qm set "$VMID" --scsi0 "${STORAGE_POOL}:vm-${VMID}-disk-0,discard=on,iothread=1,ssd=1"
qm disk resize "$VMID" scsi0 "$OS_DISK_SIZE"
msg_ok "OS disk configured (${OS_DISK_SIZE})"

msg_info "Creating data disk (${DATA_DISK_SIZE}G thin-provisioned)..."
qm set "$VMID" --scsi1 "${STORAGE_POOL}:${DATA_DISK_SIZE},discard=on,iothread=1,ssd=1"
msg_ok "Data disk created"

# ===========================================
# Configure Cloud-Init
# ===========================================
msg_info "Configuring cloud-init..."

# Generate temporary SSH key for automated setup
SSH_KEY_DIR="/tmp/samba-ad-setup-$$"
mkdir -p "$SSH_KEY_DIR"
ssh-keygen -t ed25519 -f "${SSH_KEY_DIR}/id_ed25519" -N "" -q
SSH_PUBKEY="${SSH_KEY_DIR}/id_ed25519.pub"
SSH_PRIVKEY="${SSH_KEY_DIR}/id_ed25519"

# Create custom cloud-init user-data to enable password SSH and set password
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
USERDATA_FILE="${SNIPPET_DIR}/samba-ad-${VMID}-user.yaml"

# Hash the password for cloud-init
PASSWORD_HASH=$(openssl passwd -6 "$VM_PASSWORD")

# Read the SSH public key
SSH_PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")

# Create complete user-data (cicustom replaces Proxmox's user-data entirely)
cat > "$USERDATA_FILE" << CLOUDCFG
#cloud-config
users:
  - name: ${VM_USER}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSH_PUBKEY_CONTENT}
chpasswd:
  expire: false
  users:
    - name: ${VM_USER}
      password: ${PASSWORD_HASH}
      type: HASH
ssh_pwauth: true
runcmd:
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
CLOUDCFG

qm set "$VMID" --ide2 "${STORAGE_POOL}:cloudinit"
qm set "$VMID" --ipconfig0 "ip=${VM_IP}/${VM_NETMASK},gw=${VM_GATEWAY}"
qm set "$VMID" --nameserver "${DC_PRIMARY}"
qm set "$VMID" --searchdomain "${DOMAIN_REALM,,}"
# Note: ciuser/cipassword/sshkeys not used - handled by cicustom user-data above
qm set "$VMID" --cicustom "user=local:snippets/samba-ad-${VMID}-user.yaml"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --vga qxl
qm set "$VMID" --machine q35
msg_ok "Cloud-init configured (password SSH enabled, SPICE display)"

# ===========================================
# Start VM
# ===========================================
msg_info "Starting VM..."
qm start "$VMID"
msg_ok "VM started"

# ===========================================
# Wait for VM to be ready
# ===========================================
msg_info "Waiting for VM to boot and become accessible..."

# Remove old host key if exists (in case VM was recreated with same IP)
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" 2>/dev/null || true

SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes -i ${SSH_PRIVKEY}"
MAX_WAIT=120
WAITED=0
while ! ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "exit" 2>/dev/null; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        msg_warn "VM not accessible via SSH after ${MAX_WAIT}s"
        msg_warn "You may need to configure SSH manually"
        echo ""
        echo -e "${YW}To complete setup manually:${NC}"
        echo "  1. Access VM via Proxmox console or SPICE"
        echo "  2. Download and run setup scripts from:"
        echo "     https://github.com/solomonneas/samba-ad-migration"
        rm -rf "$SSH_KEY_DIR"
        rm -f "$USERDATA_FILE"
        exit 1
    fi
    echo -ne "\r${BL}[INFO]${NC} Waiting... ${WAITED}s / ${MAX_WAIT}s"
done
echo ""
msg_ok "VM is accessible"


# ===========================================
# Create .env file on VM
# ===========================================
msg_info "Creating configuration on VM..."

ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "mkdir -p ~/fileserver"

cat <<EOF | ssh $SSH_OPTS "${VM_USER}@${VM_IP}" "cat > ~/fileserver/.env"
DOMAIN_SHORT="$DOMAIN_SHORT"
DOMAIN_REALM="$DOMAIN_REALM"
DC_PRIMARY="$DC_PRIMARY"
DC_SECONDARY="$DC_SECONDARY"
VMID="$VMID"
VM_NAME="$VM_NAME"
VM_IP="$VM_IP"
VM_NETMASK="$VM_NETMASK"
VM_GATEWAY="$VM_GATEWAY"
VM_CORES="$VM_CORES"
VM_RAM="$VM_RAM"
BRIDGE="$BRIDGE"
VLAN_TAG="$VLAN_TAG"
FIREWALL_ENABLED="$ENABLE_FIREWALL"
STORAGE_POOL="$STORAGE_POOL"
OS_DISK_SIZE="$OS_DISK_SIZE"
DATA_DISK_SIZE="$DATA_DISK_SIZE"
DATA_DISK="/dev/sdb"
SHARE_PATH="$SHARE_PATH"
SHARE_NAME="$SHARE_NAME"
EOF

msg_ok "Configuration created"

# ===========================================
# Download and run setup scripts
# ===========================================
msg_info "Downloading setup scripts..."
ssh $SSH_OPTS "${VM_USER}@${VM_IP}" bash <<'REMOTE_SCRIPT'
cd ~/fileserver
REPO_URL="https://raw.githubusercontent.com/solomonneas/samba-ad-migration/main"
mkdir -p scripts templates
wget -q "${REPO_URL}/scripts/01-setup-storage.sh" -O scripts/01-setup-storage.sh
wget -q "${REPO_URL}/scripts/02-prepare-os.sh" -O scripts/02-prepare-os.sh
wget -q "${REPO_URL}/scripts/03-install-samba.sh" -O scripts/03-install-samba.sh
wget -q "${REPO_URL}/scripts/04-join-domain.sh" -O scripts/04-join-domain.sh
wget -q "${REPO_URL}/templates/smb.conf.template" -O templates/smb.conf.template
wget -q "${REPO_URL}/templates/krb5.conf.template" -O templates/krb5.conf.template
chmod +x scripts/*.sh
REMOTE_SCRIPT
msg_ok "Scripts downloaded"

# ===========================================
# Run setup scripts (01-03)
# ===========================================
echo ""
echo -e "${BLD}${WH}── Running Setup Scripts ──${NC}"

msg_info "Setting up storage (01)..."
ssh -t $SSH_OPTS "${VM_USER}@${VM_IP}" "cd ~/fileserver && echo 'y' | sudo -E ./scripts/01-setup-storage.sh"
msg_ok "Storage configured"

msg_info "Preparing OS (02)..."
ssh -t $SSH_OPTS "${VM_USER}@${VM_IP}" "cd ~/fileserver && sudo -E ./scripts/02-prepare-os.sh"
msg_ok "OS prepared"

msg_info "Installing Samba (03)..."
ssh -t $SSH_OPTS "${VM_USER}@${VM_IP}" "cd ~/fileserver && sudo -E ./scripts/03-install-samba.sh"
msg_ok "Samba installed"

# ===========================================
# Complete
# ===========================================
echo ""
echo -e "${GN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GN}║${NC}${BLD}                    Installation Complete!                     ${NC}${GN}║${NC}"
echo -e "${GN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLD}VM Details:${NC}"
echo -e "  VMID:     ${WH}$VMID${NC}"
echo -e "  Hostname: ${WH}$VM_NAME${NC}"
echo -e "  IP:       ${WH}$VM_IP${NC}"
echo -e "  User:     ${WH}$VM_USER${NC}"
echo ""
echo -e "${BLD}${YW}Final Step - Join the domain:${NC}"
echo -e "  ssh ${VM_USER}@${VM_IP}"
echo -e "  cd ~/fileserver && sudo ./scripts/04-join-domain.sh"
echo ""
echo -e "${BLD}After domain join, share will be accessible at:${NC}"
echo -e "  ${WH}\\\\${VM_NAME}\\${SHARE_NAME}${NC}"
echo ""

# Cleanup temporary files
rm -rf "$SSH_KEY_DIR"
rm -f "$USERDATA_FILE"
