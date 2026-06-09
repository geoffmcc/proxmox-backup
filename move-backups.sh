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
WEB_DIR="/var/www/backup-status"
WEB_PORT=8080
STATUS_FILE="$WEB_DIR/status.json"
START_TIME=$(date +%s)
SERVER_PID=""

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        log "Stopped web server (PID $SERVER_PID)"
    fi
}
trap cleanup EXIT

write_status() {
    local running="$1"
    local total="$2"
    local current_file="${3:-}"
    local files_json="${4:-[]}"
    local elapsed=$(( $(date +%s) - START_TIME ))
    cat > "$STATUS_FILE" <<EOF
{
  "running": $running,
  "total_files": $total,
  "transferred": $transferred,
  "skipped": $skipped,
  "failed": $failed,
  "current_file": "$current_file",
  "elapsed_seconds": $elapsed,
  "files": $files_json
}
EOF
}

mkdir -p "$DST_DIR"
mkdir -p "$WEB_DIR"
cp /root/index.html "$WEB_DIR/index.html" 2>/dev/null || true

cd "$WEB_DIR"
python3 -m http.server "$WEB_PORT" &>/dev/null &
SERVER_PID=$!
cd - > /dev/null
log "Started web dashboard on port $WEB_PORT (PID $SERVER_PID)"

log "Starting backup transfer from $SRC_DIR to $DST_DIR"

transferred=0
skipped=0
failed=0
files_json=""
total_files=0

for ext in tar.zst vma.zst; do
    for src_file in "$SRC_DIR"/*."$ext"; do
        [ -f "$src_file" ] || continue
        total_files=$((total_files + 1))
    done
done

log "Found $total_files backup files to process"
write_status "true" "$total_files" "" "[]"

for ext in tar.zst vma.zst; do
    for src_file in "$SRC_DIR"/*."$ext"; do
        [ -f "$src_file" ] || continue

        filename=$(basename "$src_file")
        backup_date=$(echo "$filename" | grep -oP '\d{4}_\d{2}_\d{2}' | head -1 | tr '_' '-')
        if [ -n "$backup_date" ]; then
            date_dir="$DST_DIR/$backup_date"
            mkdir -p "$date_dir"
            dst_file="$date_dir/$filename"
        else
            dst_file="$DST_DIR/$filename"
        fi

        file_size=$(du -h "$src_file" | cut -f1)
        write_status "true" "$total_files" "$filename ($file_size)" "$files_json"

        src_hash=$(sha256sum "$src_file" | awk '{print $1}')
        log "Processing: $filename (SHA-256: ${src_hash:0:16}...)"

        if [ -f "$dst_file" ]; then
            dst_hash=$(sha256sum "$dst_file" | awk '{print $1}')
            if [ "$src_hash" = "$dst_hash" ]; then
                log "  SKIPPED: Already exists with matching checksum"
                skipped=$((skipped + 1))
                files_json="${files_json:+$files_json,}{\"name\":\"$filename\",\"status\":\"skipped\"}"
                write_status "true" "$total_files" "" "$files_json"
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
                        cp "$sidecar" "$date_dir/$sidecar_name"
                        rm "$sidecar"
                        log "  Moved sidecar: $sidecar_name"
                    fi
                done

                log "  TRANSFERRED: $filename"
                transferred=$((transferred + 1))
                files_json="${files_json:+$files_json,}{\"name\":\"$filename\",\"status\":\"transferred\"}"
                write_status "true" "$total_files" "" "$files_json"
            else
                log "  FAILED: Checksum mismatch after copy! Source file kept."
                rm -f "$dst_file"
                failed=$((failed + 1))
                files_json="${files_json:+$files_json,}{\"name\":\"$filename\",\"status\":\"failed\"}"
                write_status "true" "$total_files" "" "$files_json"
            fi
        else
            log "  FAILED: Copy failed for $filename"
            failed=$((failed + 1))
            files_json="${files_json:+$files_json,}{\"name\":\"$filename\",\"status\":\"failed\"}"
            write_status "true" "$total_files" "" "$files_json"
        fi
    done
done

write_status "false" "$total_files" "" "$files_json"
log "Done. Transferred: $transferred, Skipped: $skipped, Failed: $failed"
log "Dashboard will remain available for 60 seconds..."
sleep 60
