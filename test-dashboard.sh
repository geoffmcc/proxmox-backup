#!/bin/bash

set -euo pipefail

TEST_DIR="/tmp/dashboard-test"
PORT=9999

echo "Creating test directory..."
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

echo "Copying index.html..."
cp ~/move-backups/index.html "$TEST_DIR/index.html"

echo "Creating sample status.json..."
cat > "$TEST_DIR/status.json" <<'EOF'
{
  "running": true,
  "total_files": 10,
  "transferred": 6,
  "skipped": 1,
  "failed": 0,
  "current_file": "vzdump-qemu-201-2026_06_09-02_15_00.vma.zst (1.0M)",
  "elapsed_seconds": 145,
  "files": [
    {"name": "vzdump-lxc-100-2026_06_07-01_01_02.tar.zst", "status": "transferred"},
    {"name": "vzdump-lxc-100-2026_06_08-03_34_57.tar.zst", "status": "transferred"},
    {"name": "vzdump-lxc-101-2026_06_08-03_35_58.tar.zst", "status": "transferred"},
    {"name": "vzdump-lxc-102-2026_06_07-01_01_02.tar.zst", "status": "transferred"},
    {"name": "vzdump-lxc-102-2026_06_08-03_36_09.tar.zst", "status": "skipped"},
    {"name": "vzdump-lxc-103-2026_06_07-01_01_08.tar.zst", "status": "transferred"}
  ]
}
EOF

echo "Starting web server on port $PORT..."
cd "$TEST_DIR"
python3 -m http.server "$PORT" &
SERVER_PID=$!
cd - > /dev/null

echo ""
echo "=========================================="
echo "Dashboard UI Test Running"
echo "=========================================="
echo "Open in browser: http://192.168.1.4:$PORT"
echo ""
echo "Press Ctrl+C to stop and cleanup..."
echo ""

cleanup() {
    echo ""
    echo "Stopping server..."
    kill "$SERVER_PID" 2>/dev/null || true
    echo "Removing test directory..."
    rm -rf "$TEST_DIR"
    echo "Done!"
}
trap cleanup EXIT

wait "$SERVER_PID"
