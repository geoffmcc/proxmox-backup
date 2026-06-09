# Proxmox Backup Transfer

Automated backup transfer script for Proxmox VE that moves backup files from the local dump directory to a mounted SMB share with live progress tracking.

## Overview

This project provides a robust backup transfer solution that:
- Moves Proxmox backup files (`.tar.zst` for containers, `.vma.zst` for VMs) from `/var/lib/vz/dump` to `/mnt/<SMB_SHARE>/proxmox-backups`
- Organizes backups into date-based subdirectories (e.g., `2026-06-09/`)
- Provides a live web dashboard showing transfer progress
- Uses tmux for SSH resilience
- Verifies file integrity with SHA-256 checksums
- Includes a dry-run mode for safe testing

## Features

- **tmux Resilience**: Automatically wraps execution in a tmux session. If SSH disconnects, reattach with `tmux attach -t backup-transfer`
- **Live Dashboard**: Real-time web interface showing progress, statistics, and file-by-file status
- **Date-Based Organization**: Extracts dates from filenames and creates subdirectories (e.g., `proxmox-backups/2026-06-09/`)
- **SHA-256 Verification**: Verifies checksums before and after transfer, only deletes source files after successful verification
- **Sidecar File Handling**: Moves associated `.log` and `.notes` files alongside backups
- **Dry-Run Mode**: Safe testing with fake files in temporary directories
- **Smart Skipping**: Skips files that already exist at destination with matching checksums

## Requirements

- Proxmox VE server
- Python 3 (for HTTP dashboard server)
- tmux (for session management)
- Caddy (optional, for reverse proxy access)

## Deployment

Deploy the script and dashboard to your Proxmox server:

```bash
scp move-backups.sh index.html root@<PROXMOX_IP>:~/move-backups/
ssh root@<PROXMOX_IP> "chmod +x ~/move-backups/move-backups.sh"
```

## Usage

### Normal Run

```bash
~/move-backups/move-backups.sh
```

The script will:
1. Create a tmux session named `backup-transfer`
2. Start a web dashboard on port 8080
3. Transfer all `.tar.zst` and `.vma.zst` files from `/var/lib/vz/dump` to `/mnt/<SMB_SHARE>/proxmox-backups`
4. Organize files into date-based subdirectories
5. Verify checksums and delete source files only after successful verification
6. Keep the dashboard available for 5 minutes after completion

### Dry-Run Mode

```bash
~/move-backups/move-backups.sh --dry-run
```

Creates 10 fake backup files in `/tmp/backup-test-src/` and runs the full transfer logic without touching real data. Useful for:
- Testing the script works correctly
- Verifying dashboard displays progress
- Confirming date-based folder organization
- Testing sidecar file handling

Auto-cleans temporary directories if all checksums pass. Dashboard available for 30 seconds after completion.

### Dashboard Access

**Direct access:**
```
http://<PROXMOX_IP>:8080
```

**Via Caddy reverse proxy:**
```
https://backups.<YOUR_DOMAIN>
```

The dashboard shows:
- Progress bar with percentage
- Statistics: transferred, skipped, failed counts
- Current file being processed
- Elapsed time
- List of completed files with status (transferred/skipped/failed)
- Auto-refreshes every 2 seconds
- Displays "Transfer Complete" banner when finished

### tmux Management

If SSH disconnects during transfer:

```bash
# Reattach to the running session
tmux attach -t backup-transfer
```

The tmux session persists until the script completes and the cleanup trap fires.

## Caddy Configuration

Add this route to your Caddyfile (typically on your reverse proxy server):

```caddyfile
backups.<YOUR_DOMAIN> {
    reverse_proxy http://<PROXMOX_IP>:8080
}
```

Reload Caddy after adding the route:

```bash
sudo systemctl reload caddy
```

## File Structure

```
proxmox-backup/
├── move-backups.sh    # Main transfer script with tmux, dashboard, and dry-run support
├── index.html         # Dashboard UI (copied to /var/www/backup-status/ at runtime)
├── Caddyfile          # Complete Caddy config with backup dashboard route
└── .gitattributes     # Enforces LF line endings
```

## Logs

Transfer logs are written to:

**Normal mode:**
```
/var/log/backup-transfer-YYYYMMDD-HHMMSS.log
```

**Dry-run mode:**
```
/tmp/backup-transfer-test.log
```

Logs include timestamps, file processing status, checksums, and any errors.

## How It Works

1. **Initialization**: Creates tmux session, sets up directories, starts Python HTTP server
2. **File Discovery**: Scans source directory for `.tar.zst` and `.vma.zst` files
3. **Date Extraction**: Parses dates from filenames (e.g., `2026_06_09` → `2026-06-09`)
4. **Transfer Loop**: For each file:
   - Computes SHA-256 checksum of source file
   - Checks if destination exists with matching checksum (skip if identical)
   - Copies file to date-based subdirectory
   - Verifies destination checksum matches source
   - Moves sidecar files (`.log`, `.notes`)
   - Deletes source file only after verification
   - Updates dashboard status.json
5. **Cleanup**: Stops HTTP server after 5 minutes (30 seconds for dry-run), removes temp dirs in dry-run mode

## Troubleshooting

**Dashboard not accessible:**
- Check if script is running: `ps aux | grep move-backups`
- Check if port 8080 is listening: `netstat -tlnp | grep 8080`
- Check logs in `/var/log/backup-transfer-*.log`

**tmux session issues:**
- List sessions: `tmux ls`
- Kill stuck session: `tmux kill-session -t backup-transfer`
- Reattach: `tmux attach -t backup-transfer`

**Dry-run cleanup failed:**
- Manual cleanup: `rm -rf /tmp/backup-test-src /tmp/backup-test-dst /tmp/backup-test-web`
