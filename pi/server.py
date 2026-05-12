#!/usr/bin/env python3
"""Claude Notify — Pi-side server.

Holds a single global state ("idle" or "dancing") and pushes changes to
connected browsers via Server-Sent Events. Endpoints:

  POST /notify   -> state = dancing
  POST /idle     -> state = idle
  GET  /state    -> {"state": ...} (debug)
  GET  /events   -> SSE stream of state changes
  GET  /         -> static index.html
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
# Auto-return to idle this many seconds after a /notify, in case the
# Mac never sends /idle (Claude Code crashed, network blip, etc.).
AUTO_IDLE_SECONDS = 600

app = Flask(__name__, static_folder=None)

_state_lock = threading.Lock()
_state = "idle"
_state_seq = 0
_session = ""
_message = ""
_last_notify_at = 0.0
_subscribers: list[queue.Queue] = []
_subscribers_lock = threading.Lock()


def _snapshot() -> dict:
    return {
        "state": _state,
        "seq": _state_seq,
        "session": _session,
        "message": _message,
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


def _set_state(new_state: str, session: str = "", message: str = "") -> None:
    global _state, _state_seq, _session, _message, _last_notify_at
    with _state_lock:
        if new_state == "dancing":
            _last_notify_at = time.time()
        # Always update session/message even if state is unchanged, so a second
        # notify from a different project can overwrite the label.
        changed = (
            new_state != _state
            or session != _session
            or message != _message
        )
        if not changed:
            return
        _state = new_state
        _session = session
        _message = message
        _state_seq += 1
    _broadcast()


def _auto_idle_watchdog() -> None:
    while True:
        time.sleep(15)
        with _state_lock:
            should_idle = (
                _state == "dancing"
                and time.time() - _last_notify_at > AUTO_IDLE_SECONDS
            )
        if should_idle:
            _set_state("idle")


def _payload_field(name: str) -> str:
    if request.is_json:
        body = request.get_json(silent=True) or {}
        val = body.get(name)
        if isinstance(val, str):
            return val.strip()[:80]
    val = request.values.get(name, "")
    return val.strip()[:80] if isinstance(val, str) else ""


@app.post("/notify")
def notify():
    _set_state(
        "dancing",
        session=_payload_field("session"),
        message=_payload_field("message"),
    )
    return jsonify(_snapshot())


@app.post("/idle")
def idle():
    _set_state("idle")
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


@app.get("/")
def root():
    return send_from_directory(STATIC_DIR, "index.html")


@app.get("/<path:path>")
def static_files(path: str):
    return send_from_directory(STATIC_DIR, path)


if __name__ == "__main__":
    threading.Thread(target=_auto_idle_watchdog, daemon=True).start()
    app.run(host=HOST, port=PORT, threaded=True, debug=False)
