#!/bin/sh
# Claude Notify autostart. Launches the Flask server, then Chromium in kiosk
# mode pointing at it. Runs from the LXDE autostart on login.
#
# Hardening:
#   - Pre-checks the X display before launching Chromium (avoids a crash loop
#     when DPMS/blanking/early-boot leaves the server unreachable).
#   - Exponential backoff on Chromium crashes (3s → 60s, then 5min after 10
#     fast failures), so a broken environment can't pin the Pi's CPU.
#   - Trims the Chromium log when it grows past 256 KB.
#   - Restarts the Flask server too if it ever exits.

set -u

LOG_DIR="$HOME/claude-notify/logs"
mkdir -p "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
CHROMIUM_LOG="$LOG_DIR/chromium.log"
KIOSK_LOG="$LOG_DIR/kiosk.log"

# Settings.
MIN_HEALTHY_SECONDS=15      # chromium must stay up this long to be "healthy"
INITIAL_BACKOFF=3           # seconds, doubles each fast failure
MAX_BACKOFF=60
LONG_COOLDOWN=300           # 5 min sleep after MAX_FAST_FAILURES in a row
MAX_FAST_FAILURES=10
LOG_MAX_BYTES=262144        # 256 KB cap on chromium.log

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$KIOSK_LOG"; }
trim_log() {
  f="$1"
  if [ -f "$f" ] && [ "$(wc -c < "$f")" -gt "$LOG_MAX_BYTES" ]; then
    tail -c "$((LOG_MAX_BYTES / 2))" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    log "trimmed $f"
  fi
}

# When invoked from an autostart (LXDE), DISPLAY is already set. When invoked
# manually over ssh, it isn't — default to :0 and pick up the X authority file.
export DISPLAY="${DISPLAY:-:0}"
if [ -z "${XAUTHORITY:-}" ]; then
  XAUTH_FILE="$(ls -t /tmp/serverauth.* 2>/dev/null | head -1)"
  if [ -n "$XAUTH_FILE" ]; then
    export XAUTHORITY="$XAUTH_FILE"
  fi
fi

log "starting (DISPLAY=$DISPLAY)"

# Disable screen blanking / DPMS / screensaver for the X session (best-effort,
# X may not be up yet — we'll keep trying inside the loop too).
xset s off       >/dev/null 2>&1 || true
xset -dpms       >/dev/null 2>&1 || true
xset s noblank   >/dev/null 2>&1 || true

# Hide the mouse cursor when idle (optional).
if command -v unclutter >/dev/null 2>&1; then
  unclutter -idle 0 -root >/dev/null 2>&1 &
fi

server_pid=""
ensure_server() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    return
  fi
  if curl -sS -m 1 http://localhost:8080/state >/dev/null 2>&1; then
    return  # already running, just not from us
  fi
  log "starting flask server"
  setsid nohup /usr/bin/python3 "$HOME/claude-notify/server.py" \
    >> "$SERVER_LOG" 2>&1 < /dev/null &
  server_pid=$!
}

wait_for_server() {
  for _ in $(seq 1 30); do
    if curl -sS -m 1 http://localhost:8080/state >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Wait for the X server to actually be up before we attempt anything graphical.
# `xset q` succeeds only when DISPLAY is reachable.
wait_for_display() {
  for _ in $(seq 1 60); do
    if xset q >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! wait_for_display; then
  log "no X display after 60s, exiting"
  exit 1
fi

ensure_server
if ! wait_for_server; then
  log "flask server didn't come up after 30s, exiting"
  exit 1
fi

# Dedicated Chromium profile so we don't fight the user's normal one.
PROFILE_DIR="$HOME/.config/claude-notify-chromium"
mkdir -p "$PROFILE_DIR/Default"

# Suppress the "Chrome didn't shut down correctly" restore bubble.
PREFS="$PROFILE_DIR/Default/Preferences"
if [ -f "$PREFS" ]; then
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PREFS" || true
fi

backoff="$INITIAL_BACKOFF"
fast_failures=0

while true; do
  ensure_server
  wait_for_server >/dev/null 2>&1 || true

  if ! xset q >/dev/null 2>&1; then
    log "X display went away, waiting for it"
    wait_for_display || { log "display still gone, exiting"; exit 1; }
  fi

  trim_log "$CHROMIUM_LOG"
  started_at=$(date +%s)
  log "launching chromium (backoff=$backoff, fast_failures=$fast_failures)"

  chromium \
    --kiosk \
    --start-fullscreen \
    --noerrdialogs \
    --disable-infobars \
    --disable-translate \
    --disable-features=TranslateUI \
    --no-first-run \
    --fast \
    --fast-start \
    --check-for-update-interval=31536000 \
    --overscroll-history-navigation=0 \
    --disable-pinch \
    --disable-session-crashed-bubble \
    --disable-restore-session-state \
    --user-data-dir="$PROFILE_DIR" \
    --remote-debugging-port=9222 \
    --app=http://localhost:8080 \
    >> "$CHROMIUM_LOG" 2>&1 || true

  ended_at=$(date +%s)
  ran_for=$((ended_at - started_at))
  log "chromium exited after ${ran_for}s"

  if [ "$ran_for" -ge "$MIN_HEALTHY_SECONDS" ]; then
    # Healthy run — reset backoff so a one-off crash doesn't punish us.
    backoff="$INITIAL_BACKOFF"
    fast_failures=0
    sleep "$INITIAL_BACKOFF"
    continue
  fi

  fast_failures=$((fast_failures + 1))
  if [ "$fast_failures" -ge "$MAX_FAST_FAILURES" ]; then
    log "$MAX_FAST_FAILURES fast failures in a row, cooling down for ${LONG_COOLDOWN}s"
    sleep "$LONG_COOLDOWN"
    fast_failures=0
    backoff="$INITIAL_BACKOFF"
    continue
  fi

  log "fast failure #$fast_failures, sleeping ${backoff}s"
  sleep "$backoff"
  backoff=$((backoff * 2))
  if [ "$backoff" -gt "$MAX_BACKOFF" ]; then
    backoff="$MAX_BACKOFF"
  fi
done
