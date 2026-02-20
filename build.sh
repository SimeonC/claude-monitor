#!/bin/bash
# ~/.claude/monitor/build.sh
# Compile and launch Claude Monitor floating panel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_FILE="$SCRIPT_DIR/claude_monitor.swift"
BINARY="$SCRIPT_DIR/claude_monitor"

echo "Compiling Claude Monitor..."
swiftc "$SWIFT_FILE" \
    -o "$BINARY" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -parse-as-library \
    -suppress-warnings \
    2>&1

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Build successful."

LABEL="com.claude.monitor"

# Restart via launchctl if agent is loaded, otherwise launch directly
if launchctl print "gui/$(id -u)/$LABEL" &>/dev/null; then
    echo "Restarting via launchctl..."
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
    pkill -f "claude_monitor$" 2>/dev/null || true
    sleep 0.5
    echo "Launching Claude Monitor..."
    "$BINARY" &
    disown 2>/dev/null
fi

echo "Claude Monitor is running."
