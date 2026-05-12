#!/bin/sh
# Claude Notify universal hook.
#
# Usage: hook-pi.sh {notify|idle|heartbeat|end}
#
# Reads Claude Code's hook payload on stdin, forwards session_id +
# label + (for heartbeats) a random whimsy word to the Pi.
URL="${CLAUDE_NOTIFY_URL:-http://claude-notify.local:8080}"
CMD="${1:-notify}"

case "$CMD" in
  notify)    ENDPOINT="/notify" ;;
  idle)      ENDPOINT="/idle" ;;
  heartbeat) ENDPOINT="/heartbeat" ;;
  end)       ENDPOINT="/end" ;;
  *)         exit 0 ;;
esac

INPUT=$(cat 2>/dev/null || true)

SESSION_ID=""
LABEL=""
MESSAGE=""
if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  LABEL=$(printf '%s' "$INPUT" | jq -r '(.cwd // "") | split("/") | last' 2>/dev/null)
  MESSAGE=$(printf '%s' "$INPUT" | jq -r '.message // empty' 2>/dev/null)
fi

ACTIVITY=""
if [ "$CMD" = "heartbeat" ]; then
  # Whimsy. Same vibe as the Claude Code CLI's status line.
  ACTIVITY=$(awk -v seed="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null)$$" '
    BEGIN {
      srand(seed)
      n = split("Pondering Frobnicating Discombobulating Cogitating Ruminating " \
                "Contemplating Wrangling Tinkering Concocting Untangling " \
                "Brewing Hatching Marinating Mulling Plotting " \
                "Scheming Synthesizing Reticulating Befuddling Conjuring " \
                "Crafting Stewing Percolating Cerebrating Hornswoggling " \
                "Whittling Noodling Tessellating Bamboozling Confabulating " \
                "Massaging Calibrating Wrastling Galumphing Snurgling", w, " ")
      print w[int(rand() * n) + 1]
    }')
fi

# Build JSON. Prefer jq for proper escaping; fall back to a simple form.
if command -v jq >/dev/null 2>&1; then
  PAYLOAD=$(jq -nc \
    --arg session_id "$SESSION_ID" \
    --arg label "$LABEL" \
    --arg message "$MESSAGE" \
    --arg activity "$ACTIVITY" \
    '{session_id: $session_id, label: $label, message: $message, activity: $activity}')
else
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  PAYLOAD="{\"session_id\":\"$(esc "$SESSION_ID")\",\"label\":\"$(esc "$LABEL")\",\"message\":\"$(esc "$MESSAGE")\",\"activity\":\"$(esc "$ACTIVITY")\"}"
fi

curl -sS -m 2 -X POST \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "$URL$ENDPOINT" >/dev/null 2>&1 &
exit 0
