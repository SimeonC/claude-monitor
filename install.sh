#!/bin/bash
# Claude Monitor — idempotent install/update. Run from repo: ./install.sh
# Ensures dirs, config (if missing), hooks (merge), build+deploy, LaunchAgent (if needed), restart.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MONITOR_DIR="$CLAUDE_HOME/monitor"
HOOKS_DIR="$CLAUDE_HOME/hooks"
LABEL="com.claude.monitor"
APP_BUNDLE="$MONITOR_DIR/Claude Code Monitor.app"
BINARY="$APP_BUNDLE/Contents/MacOS/ClaudeCodeMonitor"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SETTINGS_FILE="$CLAUDE_HOME/settings.json"

# --- 1. Dirs ---
mkdir -p "$MONITOR_DIR/sessions" "$HOOKS_DIR"

# --- 2. Config (only if missing) ---
if [ ! -f "$MONITOR_DIR/config.json" ]; then
    cp "$REPO_DIR/config.json" "$MONITOR_DIR/config.json"
    echo "Created default config.json"
fi

# --- 3. Hooks (merge into settings.json if needed) ---
DESIRED_HOOKS="$REPO_DIR/hooks.json"
if [ ! -f "$SETTINGS_FILE" ]; then
    jq -n --slurpfile hooks "$DESIRED_HOOKS" '{hooks: $hooks[0]}' > "$SETTINGS_FILE"
    echo "Created $SETTINGS_FILE with monitor hooks."
else
    # Safe merge: for each event in desired hooks, remove existing monitor.sh groups
    # then append desired groups. User hooks on the same event are preserved.
    jq --slurpfile desired "$DESIRED_HOOKS" '
        .hooks = (
            (.hooks // {}) as $existing |
            ($desired[0] | keys) as $events |
            reduce $events[] as $ev (
                $existing;
                # Remove groups whose hooks contain monitor.sh, then append desired groups
                .[$ev] = (
                    ((.[$ev] // []) | map(select(.hooks | all(.command | test("monitor\\.sh$") | not))))
                    + $desired[0][$ev]
                )
            )
        )
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo "Merged monitor hooks into settings.json (user hooks preserved)."
fi

# --- 3b. statusLine hook ---
cp "$REPO_DIR/statusline.sh" "$HOOKS_DIR/statusline.sh"
chmod +x "$HOOKS_DIR/statusline.sh"

# Single-quotes: $HOME must stay literal so it resolves at runtime (works in devcontainers)
STATUSLINE_CMD='bash $HOME/.claude/hooks/statusline.sh'
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' \
    "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
echo "Configured statusLine hook in settings.json."

# --- 4. Build: compile in repo, deploy as .app bundle + monitor.sh ---
echo "Compiling Claude Code Monitor..."
(cd "$REPO_DIR" && swift build -c release --product ClaudeCodeMonitor 2>&1)

echo "Build successful."

# Remove old bare binary if present
rm -f "$MONITOR_DIR/claude_monitor"

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$REPO_DIR/.build/release/ClaudeCodeMonitor" "$BINARY"
cat > "$APP_BUNDLE/Contents/Info.plist" << 'INFOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.simeonc.claude_code_monitor</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeCodeMonitor</string>
    <key>CFBundleName</key>
    <string>Claude Code Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Code Monitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
INFOPLIST

# Sign the app bundle (not just the binary)
codesign -s - --force --identifier com.simeonc.claude_code_monitor "$APP_BUNDLE"

cp "$REPO_DIR/monitor.sh" "$HOOKS_DIR/monitor.sh"
chmod +x "$HOOKS_DIR/monitor.sh"

# --- 5. LaunchAgent ---
# Always write the plist (binary path may have changed)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
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
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed LaunchAgent: $PLIST"
echo "Claude Code Monitor will start on login and restart if it crashes."
echo ""
echo "Useful commands:"
echo '  Restart:  launchctl kickstart -k gui/$(id -u)/'"$LABEL"
echo '  Stop:     launchctl kill SIGTERM gui/$(id -u)/'"$LABEL"
echo '  Unload:   launchctl bootout gui/$(id -u)/'"$LABEL"

echo "Claude Code Monitor is running."
