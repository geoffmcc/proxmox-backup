#!/bin/bash

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=true
    fi
done

SESSION_NAME="backup-transfer"
if [ "$DRY_RUN" = false ] && [ -z "${TMUX:-}" ]; then
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

if [ "$DRY_RUN" = true ]; then
    SRC_DIR="/tmp/backup-test-src"
    DST_DIR="/tmp/backup-test-dst"
    LOG_FILE="/tmp/backup-transfer-test.log"
    WEB_DIR="/tmp/backup-test-web"
    WEB_PORT=8080

    rm -rf "$SRC_DIR" "$DST_DIR" "$WEB_DIR"
    mkdir -p "$SRC_DIR" "$DST_DIR" "$WEB_DIR"

    echo "Creating 10 fake backup files..."
    create_fake_file() {
        local name="$1"
        local has_log="${2:-true}"
        local has_notes="${3:-false}"
        dd if=/dev/urandom of="$SRC_DIR/$name" bs=1M count=1 2>/dev/null
        local base="${name%.*}"
        if [ "$has_log" = true ]; then
            echo "Fake log for $name" > "$SRC_DIR/${base}.log"
        fi
        if [ "$has_notes" = true ]; then
            echo "Fake notes for $name" > "$SRC_DIR/${base}.notes"
        fi
    }

    create_fake_file "vzdump-lxc-100-2026_06_07-01_01_02.tar.zst" true false
    create_fake_file "vzdump-lxc-100-2026_06_08-03_34_57.tar.zst" true true
    create_fake_file "vzdump-lxc-101-2026_06_08-03_35_58.tar.zst" true false
    create_fake_file "vzdump-lxc-102-2026_06_07-01_01_02.tar.zst" false false
    create_fake_file "vzdump-lxc-102-2026_06_08-03_36_09.tar.zst" true false
    create_fake_file "vzdump-lxc-103-2026_06_07-01_01_08.tar.zst" false false
    create_fake_file "vzdump-qemu-200-2026_06_09-02_00_00.vma.zst" true false
    create_fake_file "vzdump-qemu-201-2026_06_09-02_15_00.vma.zst" true true
    create_fake_file "vzdump-lxc-104-2026_06_09-04_00_00.tar.zst" true false
    create_fake_file "vzdump-lxc-100-2026_06_09-05_00_00.tar.zst" false false
    echo "Created $(ls -1 "$SRC_DIR"/*.tar.zst "$SRC_DIR"/*.vma.zst 2>/dev/null | wc -l) backup files"
else
    SRC_DIR="/var/lib/vz/dump"
    DST_DIR="/mnt/WD-Gold/proxmox-backups"
    LOG_FILE="/var/log/backup-transfer-$(date +%Y%m%d-%H%M%S).log"
    WEB_DIR="/var/www/backup-status"
    WEB_PORT=8080
fi

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
    if [ "$DRY_RUN" = true ]; then
        log "Dry-run complete. Failed: $failed"
        if [ "$failed" -eq 0 ]; then
            log "All checksums passed. Cleaning up temp dirs..."
            rm -rf "$SRC_DIR" "$DST_DIR" "$WEB_DIR"
            log "Cleaned up: $SRC_DIR, $DST_DIR, $WEB_DIR"
        else
            log "Some transfers failed. Leaving temp dirs for inspection:"
            log "  Source: $SRC_DIR"
            log "  Destination: $DST_DIR"
            log "  Web: $WEB_DIR"
        fi
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

if [ "$DRY_RUN" = true ]; then
    cp ~/move-backups/index.html "$WEB_DIR/index.html" 2>/dev/null || true
else
    cp ~/move-backups/index.html "$WEB_DIR/index.html" 2>/dev/null || true
fi

cd "$WEB_DIR"
python3 -m http.server "$WEB_PORT" &>/dev/null &
SERVER_PID=$!
cd - > /dev/null
log "Started web dashboard on port $WEB_PORT (PID $SERVER_PID)"

if [ "$DRY_RUN" = true ]; then
    log "=== DRY RUN MODE ==="
fi
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

if [ "$DRY_RUN" = true ]; then
    log "Dry-run dashboard will remain available for 30 seconds..."
    sleep 30
else
    log "Dashboard will remain available for 5 minutes..."
    sleep 300
fi
