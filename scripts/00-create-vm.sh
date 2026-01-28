#!/bin/bash
# ===========================================
# 00-create-vm.sh - Create VM on Proxmox
# Run this script on the Proxmox host
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

# Ubuntu 24.04 cloud image
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
UBUNTU_IMAGE="/var/lib/vz/template/iso/ubuntu-24.04-cloudimg.img"

echo "=== Proxmox VM Creation Script ==="
echo ""

# Auto-detect VMID if not specified
if [[ -z "${VMID:-}" ]]; then
    echo "Auto-detecting next available VMID..."
    # Get all VMIDs using qm and pct list (no jq required)
    EXISTING_IDS=$({ qm list 2>/dev/null | awk 'NR>1 {print $1}'; pct list 2>/dev/null | awk 'NR>1 {print $1}'; } | sort -n)
    VMID=100
    for id in $EXISTING_IDS; do
        if [[ "$id" -eq "$VMID" ]]; then
            VMID=$((VMID + 1))
        fi
    done
    echo "Auto-selected VMID: $VMID"
else
    # Check if manually specified VMID already exists
    if qm status "$VMID" &>/dev/null; then
        echo "ERROR: VMID $VMID already exists!"
        exit 1
    fi
    echo "Using specified VMID: $VMID"
fi

echo ""
echo "Configuration:"
echo "  VMID:        $VMID"
echo "  VM Name:     $VM_NAME"
echo "  Cores:       $VM_CORES"
echo "  RAM:         $VM_RAM MB"
echo "  Swap:        ${VM_SWAP:-2G}"
echo "  OS Disk:     $OS_DISK_SIZE"
echo "  Data Disk:   ${DATA_DISK_SIZE}G"
echo "  IP:          $VM_IP/$VM_NETMASK"
echo "  Gateway:     $VM_GATEWAY"
echo "  Bridge:      $BRIDGE"
[[ -n "${VLAN_TAG:-}" ]] && echo "  VLAN:        $VLAN_TAG"
echo ""

read -p "Proceed with VM creation? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Download Ubuntu cloud image if not present
if [[ ! -f "$UBUNTU_IMAGE" ]]; then
    echo ""
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -O "$UBUNTU_IMAGE" "$UBUNTU_IMAGE_URL"
fi

echo ""
echo "Creating VM $VMID..."

# Create the VM
qm create "$VMID" \
    --name "$VM_NAME" \
    --cores "$VM_CORES" \
    --memory "$VM_RAM" \
    --ostype l26 \
    --agent enabled=1 \
    --scsihw virtio-scsi-single

# Configure network interface
NET_CONFIG="virtio,bridge=${BRIDGE}"
[[ -n "${VLAN_TAG:-}" ]] && NET_CONFIG+=",tag=${VLAN_TAG}"
[[ "${FIREWALL_ENABLED:-0}" == "1" ]] && NET_CONFIG+=",firewall=1"
qm set "$VMID" --net0 "$NET_CONFIG"

echo "Importing OS disk from cloud image..."
qm importdisk "$VMID" "$UBUNTU_IMAGE" "$STORAGE_POOL" --format raw
qm set "$VMID" --scsi0 "${STORAGE_POOL}:vm-${VMID}-disk-0,discard=on,iothread=1,ssd=1"
qm disk resize "$VMID" scsi0 "$OS_DISK_SIZE"

echo "Creating ${DATA_DISK_SIZE}G data disk (thin provisioned)..."
qm set "$VMID" --scsi1 "${STORAGE_POOL}:${DATA_DISK_SIZE},discard=on,iothread=1,ssd=1"

echo "Configuring cloud-init..."
qm set "$VMID" --ide2 "${STORAGE_POOL}:cloudinit"
qm set "$VMID" --ipconfig0 "ip=${VM_IP}/${VM_NETMASK},gw=${VM_GATEWAY}"
qm set "$VMID" --nameserver "${DC_PRIMARY}"
qm set "$VMID" --searchdomain "${DOMAIN_REALM,,}"

# Configure swap via cloud-init snippet if enabled
VM_SWAP="${VM_SWAP:-2G}"
if [[ "$VM_SWAP" != "0" ]]; then
    echo "Configuring swap (${VM_SWAP})..."
    SNIPPET_DIR="/var/lib/vz/snippets"
    mkdir -p "$SNIPPET_DIR"

    # Ensure snippets content type is enabled
    CURRENT_CONTENT=$(pvesm status --storage local 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ ! "$CURRENT_CONTENT" =~ snippets ]]; then
        pvesm set local --content "${CURRENT_CONTENT},snippets"
    fi

    cat > "${SNIPPET_DIR}/samba-ad-${VMID}-user.yaml" << EOF
#cloud-config
swap:
  filename: /swap.img
  size: ${VM_SWAP}
  maxsize: ${VM_SWAP}
EOF
    qm set "$VMID" --cicustom "user=local:snippets/samba-ad-${VMID}-user.yaml"
fi

# Set boot order and enable serial console
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0

echo ""
echo "=== VM Creation Complete ==="
echo ""
echo "Next steps:"
if [[ "${VM_SWAP:-2G}" != "0" ]]; then
    echo "  1. Add credentials to cloud-init snippet:"
    echo "     Edit /var/lib/vz/snippets/samba-ad-${VMID}-user.yaml"
    echo "     Add under #cloud-config:"
    echo "       user: <username>"
    echo "       password: <password>"
    echo "       chpasswd: { expire: false }"
    echo "       ssh_pwauth: true"
else
    echo "  1. Set cloud-init user/password or SSH key:"
    echo "     qm set $VMID --ciuser <username>"
    echo "     qm set $VMID --cipassword <password>"
    echo "     # OR"
    echo "     qm set $VMID --sshkeys /path/to/authorized_keys"
fi
echo ""
echo "  2. Start the VM:"
echo "     qm start $VMID"
echo ""
echo "  3. SSH to ${VM_IP} and run the remaining scripts"
