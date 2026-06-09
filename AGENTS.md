# Project Context for AI Assistants

## Overview

This is a backup transfer system for Proxmox VE that moves backup files from the local dump directory to a mounted SMB share with live progress tracking via a web dashboard.

## Key Paths

- **Source Directory**: `/var/lib/vz/dump` (Proxmox default backup location)
- **Destination Directory**: `/mnt/<SMB_SHARE>/proxmox-backups` (SMB share mount point)
- **Web Dashboard Directory**: `/var/www/backup-status` (served by Python HTTP server)
- **Script Location on Proxmox**: `~/move-backups/` (where files are deployed)
- **Logs**: `/var/log/backup-transfer-YYYYMMDD-HHMMSS.log`

## Infrastructure

- **Proxmox Server**: <PROXMOX_IP> (where the script runs)
- **Caddy Server**: <CADDY_IP> (reverse proxy)
- **Dashboard URL**: `https://backups.<YOUR_DOMAIN>` (via Caddy)
- **Direct Dashboard URL**: `http://<PROXMOX_IP>:8080`
- **tmux Session Name**: `backup-transfer`

## Important Notes

1. **Script Execution**: The script runs on the Proxmox server (<PROXMOX_IP>), not on the Caddy server
2. **tmux Behavior**: Normal mode uses tmux for SSH resilience; dry-run mode skips tmux
3. **Dashboard Server**: Python HTTP server on port 8080, started by the script, killed by cleanup trap
4. **Dashboard Availability**: 5 minutes after completion in normal mode, 30 seconds in dry-run mode
5. **File Organization**: Backups are organized into date-based subdirectories (e.g., `2026-06-09/`)
6. **Checksum Verification**: SHA-256 is used to verify transfers before deleting source files
7. **Checksum Storage**: `.sha256` files are created alongside each backup; session manifests are generated after each run
8. **Verify Mode**: `--verify` flag checks all stored backups against their checksums
9. **Sidecar Files**: `.log` and `.notes` files are moved alongside their corresponding backup files

## Testing

### Dry-Run Mode

Use `--dry-run` flag to test the script safely:

```bash
~/move-backups/move-backups.sh --dry-run
```

**What it does:**
- Creates 10 fake backup files (1MB each) in `/tmp/backup-test-src/`
- Uses temporary directories: `/tmp/backup-test-src/`, `/tmp/backup-test-dst/`, `/tmp/backup-test-web/`
- Runs full transfer logic including dashboard, checksums, date directories
- Auto-cleans temp directories if all checksums pass
- Leaves temp directories if any failures occur (for inspection)

**Fake files include:**
- 8 `.tar.zst` files (container backups)
- 2 `.vma.zst` files (VM backups)
- Spanning 3 dates: 2026-06-07, 2026-06-08, 2026-06-09
- Mix of `.log` and `.notes` sidecar files

### Verify Mode

Use `--verify` flag to check all stored backups against their checksums:

```bash
~/move-backups/move-backups.sh --verify
```

**What it does:**
- Scans destination directory for all `.sha256` files
- Runs `sha256sum -c` on each to verify integrity
- Reports: X passed, Y failed, Z missing
- Exits with code 1 if any failures detected

Useful for periodic integrity checks of the backup archive.

## Git Notes

- **Remote**: `origin` → `https://github.com/geoffmcc/proxmox-backup.git`
- **Line Endings**: LF enforced via `.gitattributes`
- **Commit Style**: Descriptive messages explaining what changed
- **Push**: Use stored GitHub token (see global AGENTS.md) to push via API

## File Responsibilities

- **move-backups.sh**: Main script with all logic (tmux, transfer, dashboard, dry-run, verify, checksum storage)
- **index.html**: Dashboard UI, copied to web directory at runtime
- **Caddyfile**: Complete Caddy configuration including the backup dashboard route
- **.gitattributes**: Enforces LF line endings for all files

## Common Tasks

### Deploying Updates

```bash
scp move-backups.sh index.html root@<PROXMOX_IP>:~/move-backups/
ssh root@<PROXMOX_IP> "chmod +x ~/move-backups/move-backups.sh"
```

### Checking Script Status

```bash
# Check if script is running
ps aux | grep move-backups

# Check tmux session
tmux ls

# View logs
tail -f /var/log/backup-transfer-*.log
```

### Manual Cleanup (if needed)

```bash
# Kill stuck tmux session
tmux kill-session -t backup-transfer

# Remove temp directories from failed dry-run
rm -rf /tmp/backup-test-src /tmp/backup-test-dst /tmp/backup-test-web

# Kill stuck HTTP server
pkill -f "python3 -m http.server 8080"
```

## Configuration Details

### Caddy Route

The Caddyfile includes this route for the dashboard:

```caddyfile
backups.<YOUR_DOMAIN> {
    reverse_proxy http://<PROXMOX_IP>:8080
}
```

This proxies requests from the subdomain to the Python HTTP server running on Proxmox.

### Dashy Integration

Add to Dashy `conf.yml` under Infrastructure section:

```yaml
- title: Backup Transfer
  description: Proxmox Backup Dashboard
  icon: fas fa-archive
  url: https://backups.<YOUR_DOMAIN>
  target: newwindow
  statusCheckAllowInsecure: true
  id: 3_1505_backuptransfer
```

Note: `statusCheckAllowInsecure: true` is needed because Caddy uses self-signed certificates (`local_certs`).
