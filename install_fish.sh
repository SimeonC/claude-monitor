#!/bin/bash
# Claude Monitor — fish shell integration. Run after install.sh.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
FISH_FUNCTIONS_DIR="$HOME/.config/fish/functions"
if [ ! -d "$(dirname "$FISH_FUNCTIONS_DIR")" ]; then
    echo "Fish config directory not found (~/.config/fish). Is fish installed?"
    exit 1
fi
mkdir -p "$FISH_FUNCTIONS_DIR"
cp "$REPO_DIR/claude.fish" "$FISH_FUNCTIONS_DIR/claude.fish"
echo "Installed claude.fish to $FISH_FUNCTIONS_DIR"
