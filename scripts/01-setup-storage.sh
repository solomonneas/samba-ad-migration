#!/bin/bash
# ===========================================
# 01-setup-storage.sh - Format and mount data disk
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

echo "=== Storage Setup Script ==="
echo ""

# Verify data disk exists
if [[ ! -b "$DATA_DISK" ]]; then
    echo "ERROR: Data disk $DATA_DISK not found!"
    echo ""
    echo "Available block devices:"
    lsblk
    exit 1
fi

# Get disk info
DISK_SIZE=$(lsblk -b -d -n -o SIZE "$DATA_DISK" | numfmt --to=iec)
echo "Found data disk: $DATA_DISK ($DISK_SIZE)"
echo ""

# Check if disk already has a filesystem
if blkid "$DATA_DISK" &>/dev/null; then
    echo "WARNING: Disk $DATA_DISK already has a filesystem!"
    blkid "$DATA_DISK"
    echo ""
    read -p "This will DESTROY all data. Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
else
    # Check if disk has any partitions
    if [[ $(lsblk -n "$DATA_DISK" | wc -l) -gt 1 ]]; then
        echo "WARNING: Disk has partitions!"
        lsblk "$DATA_DISK"
        echo ""
        read -p "This will DESTROY all data. Continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    else
        read -p "Format $DATA_DISK with XFS? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

echo ""
echo "Creating XFS filesystem on $DATA_DISK..."
wipefs -a "$DATA_DISK"
mkfs.xfs -f "$DATA_DISK"

# Get UUID for fstab
DISK_UUID=$(blkid -s UUID -o value "$DATA_DISK")
echo "Disk UUID: $DISK_UUID"

echo ""
echo "Creating mount point: $SHARE_PATH"
mkdir -p "$SHARE_PATH"

# Check if already in fstab
if grep -q "$DISK_UUID" /etc/fstab; then
    echo "Entry already exists in /etc/fstab, skipping..."
else
    echo "Adding fstab entry..."
    echo "UUID=$DISK_UUID $SHARE_PATH xfs defaults,noatime 0 2" >> /etc/fstab
fi

echo ""
echo "Mounting filesystem..."
mount "$SHARE_PATH"

echo ""
echo "Verifying mount..."
df -h "$SHARE_PATH"

echo ""
echo "=== Storage Setup Complete ==="
echo ""
echo "Data disk mounted at: $SHARE_PATH"
