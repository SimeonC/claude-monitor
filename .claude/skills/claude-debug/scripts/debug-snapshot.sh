#!/bin/bash
# Debug Snapshot Utility
# Creates a frozen snapshot of ~/.claude for analysis without live updates
# Usage: ./debug-snapshot.sh [snapshot-name]

set -e

SNAPSHOT_NAME="${1:-debug-snapshot-$(date +%Y%m%d-%H%M%S)}"
SNAPSHOT_DIR="./tmp/debug-snapshots"
TARGET_PATH="$SNAPSHOT_DIR/$SNAPSHOT_NAME"

mkdir -p "$SNAPSHOT_DIR"

echo "📸 Creating debug snapshot of ~/.claude..."
echo "   Target: $TARGET_PATH"
echo ""

# Copy ~/.claude to snapshot directory
# Exclude large directories that don't help with debugging
rsync -av \
  --exclude='.DS_Store' \
  --exclude='telemetry' \
  --exclude='cache' \
  --exclude='paste-cache' \
  --exclude='backups' \
  --exclude='debug' \
  --exclude='downloads' \
  --exclude='shell-snapshots' \
  --exclude='*.log' \
  ~/.claude/ "$TARGET_PATH/"

echo ""
echo "✅ Snapshot created at: $TARGET_PATH"
echo ""
echo "📊 Snapshot contents:"
du -sh "$TARGET_PATH"/*/ 2>/dev/null | sort -rh

echo ""
echo "🔍 Key directories for team debugging:"
echo "   - Teams config:        $TARGET_PATH/teams/"
echo "   - Session metadata:    $TARGET_PATH/monitor/sessions/"
echo "   - JSONL files:         $TARGET_PATH/projects/"
echo "   - Task lists:          $TARGET_PATH/tasks/"
echo ""
echo "💡 To analyze the snapshot without live updates:"
echo "   cd $TARGET_PATH"
echo "   # Now examine files without them changing during analysis"
echo ""
echo "📝 To use in debugging:"
echo "   1. Run this script to freeze the current state"
echo "   2. Share the snapshot directory with debugging tools"
echo "   3. Analysis won't be affected by live session updates"
