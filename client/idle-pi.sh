#!/bin/sh
# Claude Code hook -> tells the Pi to go back to idle/bored.
# Wired to the UserPromptSubmit event (user has responded).
URL="${CLAUDE_NOTIFY_URL:-http://claude-notify.local:8080}"
curl -sS -m 2 -X POST "$URL/idle" >/dev/null 2>&1 &
exit 0
