# AD File Server Migration Automation

Automation scripts for migrating a Windows AD file share to a Samba-based Linux VM on Proxmox, with AD domain integration.

## Features

- Automated VM creation on Proxmox with cloud-init
- Thin-provisioned storage for data disk
- Full AD domain integration via Samba/Winbind
- Robocopy-based data migration preserving permissions
- Configurable via `.env` file (secrets kept out of git)

## Prerequisites

- Proxmox VE host with local-lvm storage
- Active Directory domain with accessible Domain Controllers
- Network connectivity between Proxmox host, new VM, and AD DCs
- Domain admin credentials for joining

## Quick Start

### 1. Clone and Configure

```bash
git clone <repository-url>
cd fileserver
cp .env.example .env
# Edit .env with your environment values
nano .env
```

### 2. Create VM (on Proxmox host)

```bash
# Copy scripts to Proxmox host
scp -r . root@proxmox:/root/fileserver/

# SSH to Proxmox and run
ssh root@proxmox
cd /root/fileserver
chmod +x scripts/*.sh
./scripts/00-create-vm.sh
```

Configure cloud-init credentials:
```bash
qm set <VMID> --ciuser ubuntu --cipassword 'your-password'
# OR use SSH key
qm set <VMID> --sshkeys ~/.ssh/authorized_keys
```

Start the VM:
```bash
qm start <VMID>
```

### 3. Configure VM (SSH to new VM)

Copy the scripts to the VM and run in order:

```bash
# From your workstation
scp -r . ubuntu@<VM_IP>:~/fileserver/

# SSH to VM
ssh ubuntu@<VM_IP>
cd ~/fileserver
chmod +x scripts/*.sh
sudo ./scripts/01-setup-storage.sh
sudo ./scripts/02-prepare-os.sh
sudo ./scripts/03-install-samba.sh
sudo ./scripts/04-join-domain.sh
```

### 4. Migrate Data (from Windows)

Run the PowerShell script from a Windows machine with access to both the old and new shares:

```powershell
# Preview what will be copied
.\scripts\05-migrate-data.ps1 -WhatIf

# Run the actual migration
.\scripts\05-migrate-data.ps1 -Source "E:\OldFileShare" -ServerName "prox-fileserv"
```

## Script Overview

| Script | Run On | Purpose |
|--------|--------|---------|
| `00-create-vm.sh` | Proxmox host | Creates VM with OS and data disks |
| `01-setup-storage.sh` | New VM | Formats and mounts data disk |
| `02-prepare-os.sh` | New VM | Sets hostname, DNS, NTP |
| `03-install-samba.sh` | New VM | Installs Samba, generates configs |
| `04-join-domain.sh` | New VM | Joins AD domain, sets permissions |
| `05-migrate-data.ps1` | Windows | Robocopy migration |

## Configuration Reference

Key settings in `.env`:

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN_SHORT` | NetBIOS domain name | `CONTOSO` |
| `DOMAIN_REALM` | Kerberos realm (FQDN, uppercase) | `CONTOSO.LOCAL` |
| `DC_PRIMARY` | Primary DC IP | `10.0.0.10` |
| `DC_SECONDARY` | Secondary DC IP (optional) | `10.0.0.11` |
| `VM_NAME` | Hostname for new server | `prox-fileserv` |
| `VM_IP` | Static IP for VM | `10.0.0.50` |
| `SHARE_PATH` | Mount point for data | `/srv/fileshare` |
| `SHARE_NAME` | SMB share name | `Shared` |

## Verification Checklist

After deployment, verify:

- [ ] VM boots and has network connectivity
- [ ] Data disk mounted at configured path (`df -h`)
- [ ] Time synced with DC (`chronyc tracking`)
- [ ] Domain join successful (`wbinfo -t`)
- [ ] Can resolve domain users (`getent passwd administrator`)
- [ ] Share accessible from Windows: `\\<VM_NAME>\<SHARE_NAME>`
- [ ] Domain Users can create/edit files
- [ ] Data migration completes without errors

## Troubleshooting

### Cannot resolve domain
Check DNS configuration:
```bash
resolvectl status
nslookup <domain>
```

### Time sync issues
Kerberos requires time within 5 minutes of DC:
```bash
chronyc tracking
chronyc sources
```

### Domain join fails
```bash
# Test Kerberos
kinit Administrator@YOURDOMAIN.LOCAL
klist

# Check connectivity to DC
nc -zv <DC_IP> 389
nc -zv <DC_IP> 88
```

### Users not resolving after join
```bash
# Restart winbind
systemctl restart winbind

# Check winbind status
wbinfo -t
wbinfo -u
```

### Share not accessible
```bash
# Test Samba config
testparm

# Check Samba status
systemctl status smbd
smbclient -L localhost -U%
```

## Post-Migration

After successful migration:

1. Update DNS/DHCP to point clients to new server
2. Update DFS namespace if applicable
3. Configure backup solution for new server
4. Monitor for access issues during transition period
5. Decommission old file server after validation

## License

MIT
