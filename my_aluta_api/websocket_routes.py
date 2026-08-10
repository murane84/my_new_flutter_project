# websocket_routes.py
import asyncio
import json
from typing import Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from jose import JWTError, jwt

from config import SECRET_KEY, ALGORITHM
from database import SessionLocal
from models import User
from websocket_manager import connected_users, disconnect_user, notify_user
from push import send_push_to_user

router = APIRouter()

# Aluta in-app voice-call signaling message types, relayed peer-to-peer.
_CALL_SIGNALS = {
    "call_offer",     # caller → callee: SDP offer (starts ringing)
    "call_answer",    # callee → caller: SDP answer (accepted)
    "call_ice",       # both ways: an ICE candidate
    "call_decline",   # callee → caller: rejected
    "call_end",       # either: hang up an ongoing/answered call
    "call_cancel",    # caller → callee: cancelled before it was answered
    "call_busy",      # callee → caller: already in another call
}


def _authenticate_ws(token: Optional[str], user_id: int) -> Optional[User]:
    """Verify the JWT from the socket's query string and confirm it belongs to
    {user_id}.

    Mirrors the /live socket's auth exactly: decode the token with
    SECRET_KEY/ALGORITHM, load the user by the token's `sub` (email), and only
    accept the connection if that user's id matches the {user_id} in the path.
    Returns None on any failure (missing/invalid token, unknown user, or id
    mismatch) so the caller can close the socket with 4401.
    """
    if not token:
        return None
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
    email = payload.get("sub")
    if not isinstance(email, str):
        return None
    db = SessionLocal()
    try:
        user = db.query(User).filter(User.email == email).first()
    finally:
        db.close()
    if not user or user.id != user_id:
        return None
    return user


@router.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: int, token: str = ""):
    # Accept the handshake first so we can deliver a proper 4401 close frame to
    # the client when auth fails (closing *before* accept surfaces as a generic
    # handshake error, not a 4401). This mirrors the /live socket.
    await websocket.accept()

    # 🔒 This socket used to trust the {user_id} in the path blindly, so anyone
    # could subscribe as anyone. Require a valid JWT (passed as ?token=<jwt>)
    # whose user matches {user_id}, exactly like /live/ws.
    caller = _authenticate_ws(token, user_id)
    if caller is None:
        await websocket.close(code=4401)  # unauthorized
        return
    # Column attributes are already loaded, so this is safe after the auth
    # helper closed its session. Used to label the incoming-call push.
    caller_name = caller.username or "Someone"

    # Register the now-authenticated socket. (We register here rather than via
    # connect_user() because that helper also calls websocket.accept(), and we
    # already accepted above to run the auth check.)
    uid = int(user_id)
    connected_users[uid].append(websocket)
    print(f"✅ User {uid} connected. Total sockets: {len(connected_users[uid])}")

    try:
        while True:
            # Client may send lightweight realtime events (e.g. "typing").
            # Previously the payload was received and discarded, so the peer
            # never saw the typing indicator — relay it here.
            raw = await websocket.receive_text()
            try:
                data = json.loads(raw)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue

            etype = data.get("type")
            if etype == "typing":
                to = data.get("to")
                if to is not None:
                    try:
                        await notify_user(
                            int(to),
                            {"type": "typing", "user_id": int(user_id)},
                        )
                    except Exception:
                        pass
            elif etype in _CALL_SIGNALS:
                # Aluta voice-call signaling (WebRTC). Relay the whole payload
                # to the target user, stamping who it's `from`, so the two
                # peers can negotiate an internet call in real time. The server
                # is a pure relay here — no media ever passes through it.
                to = data.get("to")
                if to is not None:
                    payload = {k: v for k, v in data.items() if k != "to"}
                    payload["from"] = int(user_id)
                    try:
                        await notify_user(int(to), payload)
                    except Exception:
                        pass
                    # Wake the callee if their app is backgrounded/closed — only
                    # for the initial offer (that's what starts the ringing).
                    # Runs off the event loop so a slow FCM call never stalls
                    # signaling.
                    if etype == "call_offer":
                        try:
                            asyncio.create_task(asyncio.to_thread(
                                send_push_to_user,
                                int(to),
                                {
                                    "type": "call_offer",
                                    # NB: 'from' is a RESERVED FCM data key —
                                    # including it makes FCM reject the whole
                                    # message with HTTP 400, so the ringing push
                                    # never rings. Use 'caller_id' instead.
                                    "caller_id": str(user_id),
                                    "caller_name": caller_name,
                                },
                            ))
                        except Exception:
                            pass
            # (Other event types are still accepted and ignored, keeping the
            #  socket alive as a heartbeat.)

    except WebSocketDisconnect:
        disconnect_user(user_id, websocket)
