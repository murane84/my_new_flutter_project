# websocket_manager.py
import asyncio
import time
from typing import Dict, List, Optional
from fastapi import WebSocket
from collections import defaultdict
import json

connected_users: Dict[int, List[WebSocket]] = defaultdict(list)

# ── "Now playing" presence ───────────────────────────────────────────────────
# user_id -> {"track": {...}, "ts": epoch}. What each user is listening to right
# now, so friends can see it (the friend list's "Listening now" zone) and, later,
# tap to join. Ephemeral and single-replica by design, exactly like
# `connected_users` — a multi-replica deploy would move this to Redis. Entries
# auto-expire so a crashed/killed client never leaves a friend "stuck" playing.
now_playing: Dict[int, dict] = {}
NOW_PLAYING_TTL = 180  # seconds; the client refreshes well within this window


def set_now_playing(user_id: int, track: dict) -> None:
    now_playing[int(user_id)] = {"track": track, "ts": time.time()}


def clear_now_playing(user_id: int) -> None:
    now_playing.pop(int(user_id), None)


def get_now_playing(user_id: int) -> Optional[dict]:
    """The user's current track, or None if not playing / stale (expired)."""
    entry = now_playing.get(int(user_id))
    if not entry:
        return None
    if time.time() - entry["ts"] > NOW_PLAYING_TTL:
        now_playing.pop(int(user_id), None)
        return None
    return entry["track"]


# Will be set in main.py at startup
main_loop = None

async def connect_user(user_id: int, websocket: WebSocket):
    user_id = int(user_id)  # Ensure integer key
    await websocket.accept()
    connected_users[user_id].append(websocket)
    print(f"✅ User {user_id} connected. Total sockets: {len(connected_users[user_id])}")

def disconnect_user(user_id: int, websocket: WebSocket):
    user_id = int(user_id)
    if user_id in connected_users:
        if websocket in connected_users[user_id]:
            connected_users[user_id].remove(websocket)
        if not connected_users[user_id]:
            connected_users.pop(user_id)
    print(f"❌ User {user_id} disconnected.")

def _serialize_event(event: dict) -> dict:
    """Convert all datetime objects in event dict to ISO strings."""
    def default(o):
        if hasattr(o, "isoformat"):
            return o.isoformat()
        return str(o)

    # Safe deep serialization
    return json.loads(json.dumps(event, default=default))

async def notify_user(user_id: int, event: dict):
    user_id = int(user_id)
    if user_id in connected_users:
        for ws in connected_users[user_id]:
            try:
                event_copy = _serialize_event(event)
                await ws.send_json(event_copy)
            except Exception as e:
                print(f"⚠️ Failed sending to user {user_id}: {e}")

async def broadcast_event(user_ids: List[int], event: dict):
    """Send event to multiple users."""
    for uid in user_ids:
        await notify_user(uid, event)

def safe_notify_user(user_id: int, event: dict):
    """
    Safe wrapper to call notify_user from any thread using the main loop.
    """
    if main_loop and main_loop.is_running():
        asyncio.run_coroutine_threadsafe(notify_user(user_id, event), main_loop)


def safe_broadcast_users(user_ids, event: dict, exclude=None):
    """Thread-safe fan-out to many users (e.g. a conversation's members).
    Skips `exclude` (typically the sender)."""
    for uid in user_ids:
        try:
            uid = int(uid)
        except (TypeError, ValueError):
            continue
        if exclude is not None and uid == int(exclude):
            continue
        safe_notify_user(uid, event)