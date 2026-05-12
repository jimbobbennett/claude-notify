#!/bin/sh
# Claude Notify installer — macOS / Linux / WSL / Git Bash.
#
# Copies hook-pi.sh to ~/.claude/hooks/ and merges the seven hook
# entries (Notification, Stop, UserPromptSubmit, SessionEnd,
# SessionStart, PreToolUse, PostToolUse) into ~/.claude/settings.json.
# Safe to re-run; also scrubs any entries pointing at the old
# notify-pi.sh / idle-pi.sh scripts from previous versions.
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

# 1. Copy hook script.
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hook-pi.sh" "$HOOKS_DIR/hook-pi.sh"
chmod +x "$HOOKS_DIR/hook-pi.sh"
echo "Installed hook-pi.sh to $HOOKS_DIR"

# Clean up obsolete dedicated scripts from older installs.
for old in notify-pi.sh idle-pi.sh; do
  if [ -f "$HOOKS_DIR/$old" ]; then
    rm -f "$HOOKS_DIR/$old"
    echo "Removed obsolete $HOOKS_DIR/$old"
  fi
done

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
# shellcheck disable=SC2016
# Single quotes are intentional: we want the literal "$HOME" string
# embedded in settings.json so Claude Code's shell expands it at run time.
HOOK_BASE='$HOME/.claude/hooks/hook-pi.sh'

if ! command -v jq >/dev/null 2>&1; then
  cat <<EOF >&2

jq not found — refusing to edit $SETTINGS automatically.

Install jq:
  macOS:  brew install jq
  Debian: sudo apt install jq

Or merge this block into $SETTINGS by hand (keep any existing "hooks"):

{
  "hooks": {
    "Notification":     [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE notify" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE notify" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE idle" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE end" }] }],
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE heartbeat" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE heartbeat" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "$HOOK_BASE heartbeat" }] }]
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
  --arg base "$HOOK_BASE" \
  '
  # Remove any matcher group whose hooks contain a command matching one of
  # the obsolete script paths, or a command that we are about to install
  # (so re-running is idempotent).
  def is_stale($base; $sub):
    .command == ($base + " " + $sub)
    or (.command | test("/notify-pi\\.sh($|[^a-z])"))
    or (.command | test("/idle-pi\\.sh($|[^a-z])"));

  def scrub($base; $sub):
    map(
      .hooks |= ((. // []) | map(select(is_stale($base; $sub) | not)))
    )
    | map(select((.hooks // []) | length > 0));

  def install_hook($event; $sub):
    .hooks //= {} |
    .hooks[$event] = (
      ((.hooks[$event] // []) | scrub($base; $sub))
      + [{ hooks: [{ type: "command", command: ($base + " " + $sub) }] }]
    );

  install_hook("Notification";     "notify")
  | install_hook("Stop";           "notify")
  | install_hook("UserPromptSubmit"; "idle")
  | install_hook("SessionEnd";     "end")
  | install_hook("SessionStart";   "heartbeat")
  | install_hook("PreToolUse";     "heartbeat")
  | install_hook("PostToolUse";    "heartbeat")
  ' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"
echo "Merged hook entries into $SETTINGS (backup: $BACKUP)"

echo ""
echo "Done. Restart Claude Code (or open /hooks) to pick up the new hooks."
