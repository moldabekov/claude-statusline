#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed."
  exit 1
fi

# Ensure ~/.claude exists
mkdir -p "$HOME/.claude"

# Copy statusline script
cp "$SCRIPT_DIR/statusline.sh" "$DEST"
chmod +x "$DEST"
echo "Installed statusline.sh to $DEST"

# Update settings.json
if [ -f "$SETTINGS" ]; then
  if jq -e '.statusLine' "$SETTINGS" &>/dev/null; then
    echo "statusLine already configured in $SETTINGS — skipping."
  else
    tmp=$(mktemp)
    jq '. + {"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
    echo "Added statusLine config to $SETTINGS"
  fi
else
  cat > "$SETTINGS" <<'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
EOF
  echo "Created $SETTINGS with statusLine config"
fi

echo "Done. Restart Claude Code to see the statusbar."
