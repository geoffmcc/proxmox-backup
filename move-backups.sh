#!/bin/bash

set -euo pipefail

SESSION_NAME="backup-transfer"
if [ -z "${TMUX:-}" ]; then
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Session '$SESSION_NAME' already exists. Attaching..."
        tmux attach -t "$SESSION_NAME"
        exit 0
    fi
    echo "Starting tmux session '$SESSION_NAME'..."
    tmux new-session -d -s "$SESSION_NAME" "$0 $*"
    tmux attach -t "$SESSION_NAME"
    exit 0
fi

SRC_DIR="/var/lib/vz/dump"
DST_DIR="/mnt/WD-Gold/proxmox-backups"
LOG_FILE="/var/log/backup-transfer-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

mkdir -p "$DST_DIR"

log "Starting backup transfer from $SRC_DIR to $DST_DIR"

transferred=0
skipped=0
failed=0

for ext in tar.zst vma.zst; do
    for src_file in "$SRC_DIR"/*."$ext"; do
        [ -f "$src_file" ] || continue

        filename=$(basename "$src_file")
        dst_file="$DST_DIR/$filename"

        src_hash=$(sha256sum "$src_file" | awk '{print $1}')
        log "Processing: $filename (SHA-256: ${src_hash:0:16}...)"

        if [ -f "$dst_file" ]; then
            dst_hash=$(sha256sum "$dst_file" | awk '{print $1}')
            if [ "$src_hash" = "$dst_hash" ]; then
                log "  SKIPPED: Already exists with matching checksum"
                skipped=$((skipped + 1))
                continue
            else
                log "  WARNING: Destination exists but checksum differs, re-transferring"
            fi
        fi

        log "  Copying to destination..."
        if cp "$src_file" "$dst_file"; then
            log "  Verifying transfer..."
            dst_hash=$(sha256sum "$dst_file" | awk '{print $1}')
            if [ "$src_hash" = "$dst_hash" ]; then
                log "  Checksum verified. Removing source file."
                rm "$src_file"

                for sidecar in "${src_file%.${ext}}"*".log" "${src_file%.${ext}}"*".notes"; do
                    if [ -f "$sidecar" ]; then
                        sidecar_name=$(basename "$sidecar")
                        cp "$sidecar" "$DST_DIR/$sidecar_name"
                        rm "$sidecar"
                        log "  Moved sidecar: $sidecar_name"
                    fi
                done

                log "  TRANSFERRED: $filename"
                transferred=$((transferred + 1))
            else
                log "  FAILED: Checksum mismatch after copy! Source file kept."
                rm -f "$dst_file"
                failed=$((failed + 1))
            fi
        else
            log "  FAILED: Copy failed for $filename"
            failed=$((failed + 1))
        fi
    done
done

log "Done. Transferred: $transferred, Skipped: $skipped, Failed: $failed"
