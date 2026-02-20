#!/bin/bash
# ~/.claude/monitor/setup.sh
# Install claude_monitor as a LaunchAgent so it starts on login
# and has a stable identity for Accessibility permissions.

set -euo pipefail

MONITOR_DIR="$HOME/.claude/monitor"
BINARY="$MONITOR_DIR/claude_monitor"
LABEL="com.claude.monitor"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# Build first
"$MONITOR_DIR/build.sh"

# Unload existing agent if present
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Write plist
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>${MONITOR_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${MONITOR_DIR}/stderr.log</string>
</dict>
</plist>
EOF

# Load agent
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "Installed LaunchAgent: $PLIST"
echo "claude_monitor will now start on login and restart if it crashes."
echo ""
echo "IMPORTANT: Grant Accessibility permissions to claude_monitor:"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  Add: $BINARY"
echo ""
echo "Useful commands:"
echo "  Restart:  launchctl kickstart -k gui/\$(id -u)/$LABEL"
echo "  Stop:     launchctl kill SIGTERM gui/\$(id -u)/$LABEL"
echo "  Unload:   launchctl bootout gui/\$(id -u)/$LABEL"
