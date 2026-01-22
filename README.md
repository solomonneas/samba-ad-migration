<p align="center">
  <img src="assets/logo.svg" alt="SAMBA AD" width="400">
  <br><br>
  <img src="assets/migration-icon.svg" alt="Windows to Linux Migration" width="280">
</p>

<p align="center">Automation scripts for migrating a Windows AD file share to a Samba-based Linux VM on Proxmox, with AD domain integration.</p>

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

The installer uses Ubuntu 24.04 cloud images and automatically handles cloud-init password authentication quirks.

## Quick Start

### One-Liner Install (Recommended)

Run this on your Proxmox host for an interactive guided setup:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/solomonneas/samba-ad-migration/main/samba-ad.sh)"
```

This will:
- Prompt for all configuration (domain, IPs, VM specs)
- Create and start the VM automatically
- Configure storage, hostname, DNS, and Samba
- Leave you with one final step: domain join (requires AD admin credentials)

---

### Manual Installation

<details>
<summary>Click to expand manual steps</summary>

#### 1. Clone and Configure

```bash
git clone https://github.com/solomonneas/samba-ad-migration.git
cd samba-ad-migration
cp .env.example .env
# Edit .env with your environment values
nano .env
```

#### 2. Create VM (on Proxmox host)

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

#### 3. Configure VM (SSH to new VM)

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

#### 4. Migrate Data (from Windows)

Run the PowerShell script from a Windows machine with access to both the old and new shares:

```powershell
# Preview what will be copied
.\scripts\05-migrate-data.ps1 -WhatIf

# Run the actual migration
.\scripts\05-migrate-data.ps1 -Source "E:\OldFileShare" -ServerName "prox-fileserv"
```

</details>

## Script Overview

| Script | Run On | Purpose |
|--------|--------|---------|
| `samba-ad.sh` | Proxmox host | **One-liner installer** - interactive guided setup |
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

### APT lock during setup
If running scripts manually and cloud-init is still installing packages:
```bash
# Wait for cloud-init to finish
cloud-init status --wait

# Then run your scripts
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
2. Update DFS namespace if applicable (see below)
3. Configure backup solution for new server
4. Monitor for access issues during transition period
5. Decommission old file server after validation

### Updating DFS Namespace

If your drive mappings point to a DFS path, update the target instead of changing GPOs:

```powershell
# View current DFS targets
Get-DfsnFolderTarget -Path "\\domain.local\dfs\*"

# Add new server as target
New-DfsnFolderTarget -Path "\\domain.local\dfs\Shared" -TargetPath "\\newserver\Shared"

# Disable old target (keeps it for rollback)
Set-DfsnFolderTarget -Path "\\domain.local\dfs\Shared" -TargetPath "\\oldserver\share" -State Offline

# Or remove old target completely
Remove-DfsnFolderTarget -Path "\\domain.local\dfs\Shared" -TargetPath "\\oldserver\share"
```

Clients may cache the old target for up to 30 minutes (default TTL). Force refresh:
```cmd
dfsutil /pktflush
```

## License

MIT
