#!/bin/sh
# Claude Notify installer — macOS / Linux / WSL / Git Bash.
#
# Copies notify-pi.sh and idle-pi.sh into ~/.claude/hooks/ and merges the
# four hook entries (Notification, Stop, UserPromptSubmit, SessionEnd)
# into ~/.claude/settings.json. Safe to re-run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
URL=""

usage() {
  cat <<EOF
Usage: $0 [--url URL] [--settings PATH]

  --url URL        Persist CLAUDE_NOTIFY_URL in your shell rc file
                   (default: http://claude-notify.local:8080)
  --settings PATH  Path to settings.json
                   (default: \$HOME/.claude/settings.json)
  -h, --help       Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --url)      URL="$2"; shift 2 ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# 1. Copy hook scripts.
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/notify-pi.sh" "$HOOKS_DIR/notify-pi.sh"
cp "$SCRIPT_DIR/idle-pi.sh"   "$HOOKS_DIR/idle-pi.sh"
chmod +x "$HOOKS_DIR/notify-pi.sh" "$HOOKS_DIR/idle-pi.sh"
echo "Installed hook scripts to $HOOKS_DIR"

# 2. Persist CLAUDE_NOTIFY_URL if requested.
if [ -n "$URL" ]; then
  RC=""
  case "${SHELL:-}" in
    *zsh*)  RC="$HOME/.zshrc"  ;;
    *bash*) RC="$HOME/.bashrc" ;;
  esac
  if [ -n "$RC" ]; then
    if grep -q "CLAUDE_NOTIFY_URL" "$RC" 2>/dev/null; then
      echo "CLAUDE_NOTIFY_URL already present in $RC — leaving as is"
    else
      printf '\nexport CLAUDE_NOTIFY_URL=%s\n' "$URL" >> "$RC"
      echo "Appended CLAUDE_NOTIFY_URL=$URL to $RC (open a new shell to pick it up)"
    fi
  else
    echo "Could not detect shell rc file; set CLAUDE_NOTIFY_URL=$URL manually" >&2
  fi
fi

# 3. Merge hook entries into settings.json.
NOTIFY_CMD='$HOME/.claude/hooks/notify-pi.sh'
IDLE_CMD='$HOME/.claude/hooks/idle-pi.sh'

if ! command -v jq >/dev/null 2>&1; then
  cat <<EOF >&2

jq not found — refusing to edit $SETTINGS automatically.

Install jq:
  macOS:  brew install jq
  Debian: sudo apt install jq

Or merge this block into $SETTINGS by hand (keep any existing "hooks"):

{
  "hooks": {
    "Notification":     [{ "hooks": [{ "type": "command", "command": "$NOTIFY_CMD" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "$NOTIFY_CMD" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$IDLE_CMD"   }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "$IDLE_CMD"   }] }]
  }
}
EOF
  exit 1
fi

mkdir -p "$(dirname "$SETTINGS")"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "ERROR: $SETTINGS is not valid JSON. Fix it before re-running." >&2
  exit 1
fi

BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"

TMP="$(mktemp)"
jq \
  --arg notify "$NOTIFY_CMD" \
  --arg idle   "$IDLE_CMD" \
  '
  def add_hook($event; $cmd):
    .hooks //= {} |
    .hooks[$event] = (
      (.hooks[$event] // [])
      | if any(.[]?; (.hooks // [])[]? | .command == $cmd) then .
        else . + [{ hooks: [{ type: "command", command: $cmd }] }]
        end
    );
  add_hook("Notification"; $notify)
  | add_hook("Stop"; $notify)
  | add_hook("UserPromptSubmit"; $idle)
  | add_hook("SessionEnd"; $idle)
  ' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"
echo "Merged hook entries into $SETTINGS (backup: $BACKUP)"

echo ""
echo "Done. Restart Claude Code (or open /hooks) to pick up the new hooks."
