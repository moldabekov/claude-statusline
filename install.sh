#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_DEST="$CLAUDE_DIR/statusline.sh"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_DEST="$PI_AGENT_DIR/extensions/statusline.ts"

HAS_CLAUDE=false
HAS_PI=false
if command -v claude &>/dev/null; then HAS_CLAUDE=true; fi
if command -v pi &>/dev/null; then HAS_PI=true; fi

if ! $HAS_CLAUDE && ! $HAS_PI; then
  echo "Error: neither Claude Code ('claude') nor Pi ('pi') was found in PATH." >&2
  exit 1
fi

if $HAS_CLAUDE && $HAS_PI; then
  echo "Detected: Claude Code, Pi"
elif $HAS_CLAUDE; then
  echo "Detected: Claude Code"
else
  echo "Detected: Pi"
fi

install_claude_statusline() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required to install and run the Claude Code statusline." >&2
    return 1
  fi

  mkdir -p "$CLAUDE_DIR"
  cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DEST"
  chmod +x "$CLAUDE_DEST"
  echo "Installed Claude Code statusline to $CLAUDE_DEST"

  if [ -f "$CLAUDE_SETTINGS" ]; then
    if ! jq -e 'type == "object"' "$CLAUDE_SETTINGS" &>/dev/null; then
      echo "Error: $CLAUDE_SETTINGS must contain a valid JSON object." >&2
      return 1
    fi

    if jq -e '.statusLine' "$CLAUDE_SETTINGS" &>/dev/null; then
      echo "statusLine already configured in $CLAUDE_SETTINGS — leaving it unchanged."
    else
      local tmp
      tmp=$(mktemp)
      if jq '. + {"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}' \
        "$CLAUDE_SETTINGS" > "$tmp"; then
        mv "$tmp" "$CLAUDE_SETTINGS"
      else
        rm -f "$tmp"
        return 1
      fi
      echo "Added statusLine config to $CLAUDE_SETTINGS"
    fi
  else
    cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
EOF
    echo "Created $CLAUDE_SETTINGS with statusLine config"
  fi
}

install_pi_statusline() {
  mkdir -p "$(dirname "$PI_DEST")"
  cp "$SCRIPT_DIR/statusline.ts" "$PI_DEST"
  echo "Installed Pi statusline extension to $PI_DEST"
}

# Pi has no extra installer dependencies, so install it even if Claude's jq/config
# validation later fails.
if $HAS_PI; then install_pi_statusline; fi
if $HAS_CLAUDE; then install_claude_statusline; fi

echo "Done. Restart detected agents to load their statuslines (or run /reload in Pi)."
