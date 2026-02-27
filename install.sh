#!/bin/bash
# Claude Monitor — idempotent install/update. Run from repo: ./install.sh
# Ensures dirs, config (if missing), hooks (merge), build+deploy, LaunchAgent (if needed), restart.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MONITOR_DIR="$CLAUDE_HOME/monitor"
HOOKS_DIR="$CLAUDE_HOME/hooks"
LABEL="com.claude.monitor"
BINARY="$MONITOR_DIR/claude_monitor"
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

STATUSLINE_CMD="bash $HOME/.claude/hooks/statusline.sh"
jq --arg cmd "$STATUSLINE_CMD" '.statusLine = {"type": "command", "command": $cmd}' \
    "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
echo "Configured statusLine hook in settings.json."

# --- 4. Build: compile in repo, deploy binary + monitor.sh ---
SWIFT_FILE="$REPO_DIR/claude_monitor.swift"
BUILD_BINARY="$REPO_DIR/claude_monitor"

echo "Compiling Claude Monitor..."
swiftc "$SWIFT_FILE" \
    -o "$BUILD_BINARY" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -parse-as-library \
    -suppress-warnings \
    2>&1

echo "Build successful."
cp "$BUILD_BINARY" "$BINARY"
cp "$REPO_DIR/monitor.sh" "$HOOKS_DIR/monitor.sh"
chmod +x "$HOOKS_DIR/monitor.sh"

# --- Deploy fish function ---
FISH_FUNCTIONS_DIR="$HOME/.config/fish/functions"
if [ -d "$(dirname "$FISH_FUNCTIONS_DIR")" ]; then
    mkdir -p "$FISH_FUNCTIONS_DIR"
    cp "$REPO_DIR/claude.fish" "$FISH_FUNCTIONS_DIR/claude.fish"
    echo "Installed claude.fish to $FISH_FUNCTIONS_DIR"
fi

# --- 5. LaunchAgent (only if not installed) ---
AGENT_LOADED=false
if launchctl print "gui/$(id -u)/$LABEL" &>/dev/null; then
    AGENT_LOADED=true
fi

if [ "$AGENT_LOADED" = false ]; then
    # Unload if plist exists but agent is stale
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
    AGENT_LOADED=true
    echo ""
    echo "Installed LaunchAgent: $PLIST"
    echo "claude_monitor will start on login and restart if it crashes."
    echo ""
    echo "IMPORTANT: Grant Accessibility permissions to claude_monitor:"
    echo "  System Settings > Privacy & Security > Accessibility"
    echo "  Add: $BINARY"
    echo ""
    echo "Useful commands:"
    echo '  Restart:  launchctl kickstart -k gui/$(id -u)/'"$LABEL"
    echo '  Stop:     launchctl kill SIGTERM gui/$(id -u)/'"$LABEL"
    echo '  Unload:   launchctl bootout gui/$(id -u)/'"$LABEL"
    echo ""
fi

# --- 6. Restart ---
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
