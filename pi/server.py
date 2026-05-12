#!/usr/bin/env python3
"""Claude Notify — Pi-side server.

Holds a dict of sessions keyed by Claude Code's session_id and pushes
snapshots to connected browsers via Server-Sent Events. Each session
has its own state ("idle" / "dancing"), label, and optional activity
word (the whimsy "Frobnicating..." string).

Endpoints:

  POST /notify     -> session.state = dancing; activity cleared
  POST /idle       -> session.state = idle;    activity cleared
  POST /heartbeat  -> session created-if-missing in idle; activity set
  POST /end        -> session removed
  GET  /state      -> {seq, now, sessions}
  GET  /events     -> SSE stream of snapshots
  GET  /           -> static index.html

Old clients that don't send a session_id collapse into a single
"default" bucket so the Pi keeps working mid-upgrade.
"""
from __future__ import annotations

import json
import queue
import threading
import time
from pathlib import Path

from flask import Flask, Response, jsonify, request, send_from_directory

STATIC_DIR = Path(__file__).parent / "static"
HOST = "0.0.0.0"
PORT = 8080
# Drop a session this many seconds after its last heartbeat or state change.
IDLE_EVICT_SECONDS = 600
# Clear a session's activity word this many seconds after its last heartbeat.
ACTIVITY_TIMEOUT = 10
# Watchdog poll interval.
WATCHDOG_INTERVAL = 5

app = Flask(__name__, static_folder=None)

_lock = threading.Lock()
_sessions: dict[str, dict] = {}
_seq = 0
_subscribers: list[queue.Queue] = []
_subscribers_lock = threading.Lock()


def _payload_field(name: str, max_len: int = 120) -> str:
    if request.is_json:
        body = request.get_json(silent=True) or {}
        val = body.get(name)
        if isinstance(val, str):
            return val.strip()[:max_len]
    val = request.values.get(name, "")
    return val.strip()[:max_len] if isinstance(val, str) else ""


def _session_id() -> str:
    sid = _payload_field("session_id", max_len=80)
    return sid or "default"


def _snapshot() -> dict:
    """Caller must NOT hold _lock — we acquire it here to iterate safely."""
    with _lock:
        return {
            "seq": _seq,
            "now": time.time(),
            "sessions": {sid: dict(s) for sid, s in _sessions.items()},
        }


def _broadcast() -> None:
    payload = json.dumps(_snapshot())
    with _subscribers_lock:
        dead = []
        for q in _subscribers:
            try:
                q.put_nowait(payload)
            except queue.Full:
                dead.append(q)
        for q in dead:
            _subscribers.remove(q)


def _touch(sid: str) -> dict:
    """Get or create a session and refresh last_seen. Caller holds _lock."""
    s = _sessions.get(sid)
    if s is None:
        s = {
            "state": "idle",
            "label": "",
            "message": "",
            "activity": "",
            "last_seen": 0.0,
            "last_notify_at": 0.0,
        }
        _sessions[sid] = s
    s["last_seen"] = time.time()
    return s


@app.post("/notify")
def notify():
    global _seq
    sid = _session_id()
    label = _payload_field("session") or _payload_field("label")
    msg = _payload_field("message")
    with _lock:
        s = _touch(sid)
        s["state"] = "dancing"
        s["last_notify_at"] = time.time()
        if label:
            s["label"] = label
        s["message"] = msg
        s["activity"] = ""
        _seq += 1
    _broadcast()
    return jsonify(_snapshot())


@app.post("/idle")
def idle():
    global _seq
    sid = _session_id()
    label = _payload_field("session") or _payload_field("label")
    with _lock:
        s = _touch(sid)
        s["state"] = "idle"
        if label:
            s["label"] = label
        s["message"] = ""
        s["activity"] = ""
        _seq += 1
    _broadcast()
    return jsonify(_snapshot())


@app.post("/heartbeat")
def heartbeat():
    global _seq
    sid = _session_id()
    label = _payload_field("session") or _payload_field("label")
    activity = _payload_field("activity", max_len=40)
    with _lock:
        s = _touch(sid)
        # If Claude is actively working (firing tool hooks), it's no longer
        # waiting for the user, so a heartbeat downgrades dancing back to idle.
        s["state"] = "idle"
        s["message"] = ""
        if label:
            s["label"] = label
        if activity:
            s["activity"] = activity
        _seq += 1
    _broadcast()
    return jsonify(_snapshot())


@app.post("/end")
def end():
    global _seq
    sid = _session_id()
    with _lock:
        if sid in _sessions:
            del _sessions[sid]
            _seq += 1
            changed = True
        else:
            changed = False
    if changed:
        _broadcast()
    return jsonify(_snapshot())


@app.get("/state")
def state():
    return jsonify(_snapshot())


@app.get("/events")
def events():
    q: queue.Queue = queue.Queue(maxsize=8)
    with _subscribers_lock:
        _subscribers.append(q)
    initial = json.dumps(_snapshot())

    def stream():
        yield f"data: {initial}\n\n"
        try:
            while True:
                try:
                    payload = q.get(timeout=20)
                    yield f"data: {payload}\n\n"
                except queue.Empty:
                    yield ": keepalive\n\n"
        finally:
            with _subscribers_lock:
                if q in _subscribers:
                    _subscribers.remove(q)

    return Response(
        stream(),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


def _watchdog() -> None:
    global _seq
    while True:
        time.sleep(WATCHDOG_INTERVAL)
        now = time.time()
        changed = False
        with _lock:
            for sid in list(_sessions.keys()):
                s = _sessions[sid]
                age = now - s["last_seen"]
                if age > IDLE_EVICT_SECONDS:
                    del _sessions[sid]
                    changed = True
                elif s["activity"] and age > ACTIVITY_TIMEOUT:
                    s["activity"] = ""
                    changed = True
            if changed:
                _seq += 1
        if changed:
            _broadcast()


@app.get("/")
def root():
    return send_from_directory(STATIC_DIR, "index.html")


@app.get("/<path:path>")
def static_files(path: str):
    return send_from_directory(STATIC_DIR, path)


if __name__ == "__main__":
    threading.Thread(target=_watchdog, daemon=True).start()
    app.run(host=HOST, port=PORT, threaded=True, debug=False)
