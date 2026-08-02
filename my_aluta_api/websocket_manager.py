# websocket_manager.py
import asyncio
from typing import Dict, List
from fastapi import WebSocket
from collections import defaultdict
import json

connected_users: Dict[int, List[WebSocket]] = defaultdict(list)

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