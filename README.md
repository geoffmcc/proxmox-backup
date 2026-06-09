# Proxmox Backup Transfer

Automated backup transfer script for Proxmox VE that moves backup files from the local dump directory to a mounted SMB share with live progress tracking.

## Overview

This project provides a robust backup transfer solution that:
- Moves Proxmox backup files (`.tar.zst` for containers, `.vma.zst` for VMs) from the source directory to an SMB share
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
- **Checksum Storage**: Creates `.sha256` files alongside each backup and generates session manifests
- **Verify Mode**: Run `--verify` to check all stored backups against their checksums
- **Sidecar File Handling**: Moves associated `.log` and `.notes` files alongside backups
- **Dry-Run Mode**: Safe testing with fake files in temporary directories
- **Smart Skipping**: Skips files that already exist at destination with matching checksums

## Requirements

- Proxmox VE server
- Python 3 (for HTTP dashboard server)
- tmux (for session management)
- Caddy (optional, for reverse proxy access)

## Configuration

Copy `.env.example` to `.env` in the script directory and configure:

```bash
cp .env.example .env
nano .env
```

**Required:**
- `SMB_SHARE` — name of the SMB share (mounted at `/mnt/<SMB_SHARE>`)

**Optional (defaults shown):**
- `SRC_DIR` — `/var/lib/vz/dump` — Proxmox backup source directory
- `BACKUP_SUBDIR` — `proxmox-backups` — subdirectory under SMB mount
- `WEB_PORT` — `8080` — dashboard HTTP server port
- `WEB_DIR` — `/var/www/backup-status` — dashboard files location
- `LOG_DIR` — `/var/log` — log file directory
- `SCRIPT_DIR` — `~/move-backups` — where script and index.html are deployed
- `DASHBOARD_TIMEOUT` — `60` — seconds to keep dashboard up after completion
- `DRY_RUN_TIMEOUT` — `30` — seconds for dry-run dashboard availability

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
3. Transfer all `.tar.zst` and `.vma.zst` files from the source directory to the SMB share destination
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

### Verify Mode

```bash
~/move-backups/move-backups.sh --verify
```

Verifies all backup files in the SMB share against their stored SHA-256 checksums. This mode:
- Scans the destination directory for all `.sha256` files
- Runs `sha256sum -c` on each to verify integrity
- Reports: X passed, Y failed, Z missing
- Exits with code 1 if any failures detected

Useful for periodic integrity checks of your backup archive.

### Integrity Test

```bash
~/move-backups/test-transfer.sh
```

Runs a full integration test that:
1. Creates 3 test files (500MB, 1GB, 200MB) in a temporary directory
2. Transfers them to a test destination using custom paths
3. Verifies all checksums pass
4. Corrupts the 200MB file in the destination
5. Runs verification again to confirm corruption is detected

This test demonstrates the checksum verification system working correctly. Test files are stored in `/tmp/backup-integrity-test/` and can be inspected or deleted after the test.

### Checksum Storage

The script creates two types of checksum records:

**Per-file checksums (`.sha256` files):**
- Created alongside each backup file (e.g., `backup.tar.zst.sha256`)
- Format: `<hash>  <filename>` (standard sha256sum format)
- Can be verified individually: `sha256sum -c backup.tar.zst.sha256`

**Session manifest files:**
- Created after each transfer run in the destination root
- Format: `checksums-YYYYMMDD-HHMMSS.txt`
- Contains all hashes from that transfer session
- Provides complete audit trail

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
├── index.html         # Dashboard UI (copied to WEB_DIR at runtime)
├── Caddyfile          # Complete Caddy config with backup dashboard route
└── .gitattributes     # Enforces LF line endings
```

## Logs

Transfer logs are written to:

**Normal mode:**
```
$LOG_DIR/backup-transfer-YYYYMMDD-HHMMSS.log
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
   - Creates `.sha256` checksum file alongside destination backup
   - Moves sidecar files (`.log`, `.notes`)
   - Deletes source file only after verification
   - Updates dashboard status.json
5. **Manifest Generation**: Creates `checksums-YYYYMMDD-HHMMSS.txt` with all transfer hashes
6. **Cleanup**: Stops HTTP server after 5 minutes (30 seconds for dry-run), removes temp dirs in dry-run mode

## Troubleshooting

**Dashboard not accessible:**
- Check if script is running: `ps aux | grep move-backups`
- Check if port 8080 is listening: `netstat -tlnp | grep 8080`
- Check logs in `$LOG_DIR/backup-transfer-*.log`

**tmux session issues:**
- List sessions: `tmux ls`
- Kill stuck session: `tmux kill-session -t backup-transfer`
- Reattach: `tmux attach -t backup-transfer`

**Dry-run cleanup failed:**
- Manual cleanup: `rm -rf /tmp/backup-test-src /tmp/backup-test-dst /tmp/backup-test-web`
