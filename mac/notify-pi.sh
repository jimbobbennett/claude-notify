#!/bin/sh
# Claude Code hook -> tells the Pi to dance. Forwards the basename of the
# current Claude Code working directory as the "session" name so the Pi can
# show which Claude is asking.
URL="${CLAUDE_NOTIFY_URL:-http://claude-notify.local:8080}"

INPUT=$(cat 2>/dev/null || true)
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  PAYLOAD=$(printf '%s' "$INPUT" | jq -c '{
    session: ((.cwd // "") | split("/") | last),
    message: (.message // "")
  }' 2>/dev/null)
fi
PAYLOAD="${PAYLOAD:-{\}}"

curl -sS -m 2 -X POST \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "$URL/notify" >/dev/null 2>&1 &
exit 0
