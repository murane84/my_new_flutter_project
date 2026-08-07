"""
Live "listen together" session routes.

- POST /live/sessions            -> host creates a session, invites a receiver (DM)
- POST /live/sessions/{id}/end   -> host ends the session
- WS   /ws/live/{session_id}     -> host + listener(s) exchange signaling + control

Audio does NOT pass through the server: peers stream it directly over a WebRTC
data channel. This socket carries only WebRTC signaling (SDP/ICE) and the sync
clock (play/pause/seek/position/meta/queue/eq + session lifecycle). Signaling is
peer-addressed (a `to` user id) so it routes to a single participant — the same
socket therefore extends from 1:1 to a room; the sync clock broadcasts to all.
Nothing is ever written to disk or the database. Ending the session (or the host
disconnecting) tears everything down.
"""
import json
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
from jose import JWTError, jwt

from config import SECRET_KEY, ALGORITHM
from database import SessionLocal, get_db
from models import User
from sqlalchemy.orm import Session

from auth import get_current_user
from websocket_manager import safe_notify_user
from live_session import MANAGER

router = APIRouter(prefix="/live", tags=["Live Session"])


# ------------------------------ Schemas ------------------------------
class TrackMeta(BaseModel):
    title: Optional[str] = None
    artist: Optional[str] = None
    duration_ms: Optional[int] = None
    mime: Optional[str] = "audio/mpeg"


class CreateSessionRequest(BaseModel):
    receiver_id: int
    track: TrackMeta = TrackMeta()


# ------------------------------ HTTP ------------------------------
@router.post("/sessions")
def create_session(
    body: CreateSessionRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Host creates a 1:1 live session and invites `receiver_id`."""
    if body.receiver_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot start a session with yourself")

    receiver = db.query(User).filter(User.id == body.receiver_id).first()
    if not receiver:
        raise HTTPException(status_code=404, detail="Receiver not found")

    session_id = uuid.uuid4().hex
    track = body.track.model_dump()
    MANAGER.create(session_id, host_id=current_user.id, invited_ids=[body.receiver_id], track=track)

    # Notify the receiver over their normal notification WebSocket so their app
    # can pop an "X wants to listen together" prompt.
    safe_notify_user(body.receiver_id, {
        "type": "live_invite",
        "data": {
            "session_id": session_id,
            "host_id": current_user.id,
            "host_username": current_user.username,
            "track": track,
        },
    })

    return {"session_id": session_id, "host_id": current_user.id, "track": track}


@router.post("/sessions/{session_id}/end")
async def end_session(
    session_id: str,
    current_user: User = Depends(get_current_user),
):
    """Host ends the session. Broadcasts an 'end' event and drops all state."""
    session = MANAGER.get(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    if session.host_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the host can end the session")

    await MANAGER.broadcast_text(session_id, json.dumps({"type": "end", "reason": "host_ended"}))
    MANAGER.remove(session_id)
    return {"detail": "Session ended"}


# ------------------------------ WebSocket ------------------------------
def _authenticate_ws(token: Optional[str], user_id: int) -> Optional[User]:
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


@router.websocket("/ws/{session_id}")
async def live_session_ws(websocket: WebSocket, session_id: str, token: str = "", user_id: int = 0):
    """
    Both the host and the listener connect here with:
        /live/ws/{session_id}?token=<jwt>&user_id=<id>

    Text frames = JSON control messages (meta/play/pause/seek/eos) — relayed to
    the other participant(s). Binary frames = raw audio chunks — relayed likewise.
    """
    await websocket.accept()

    user = _authenticate_ws(token, user_id)
    if user is None:
        await websocket.close(code=4401)  # unauthorized
        return

    session = MANAGER.get(session_id)
    if session is None or user.id not in session.allowed_ids:
        await websocket.close(code=4404)  # no such session / not invited
        return

    is_host = (user.id == session.host_id)

    MANAGER.attach(session_id, user.id, websocket)

    # If the HOST just (re)connected, cancel any pending "host never came back"
    # timer so a transient glitch doesn't end the session after the fact.
    if is_host:
        MANAGER.cancel_host_timeout(session_id)

    # Tell the newcomer the current playback state, and let others know someone
    # joined. We ALSO tell the newcomer about every peer already connected: this
    # is what makes a reconnecting HOST re-stream to the listener who is still
    # there (the host re-streams the current track on each `peer_joined`).
    # Without it, a reconnected host would sit idle and playback would never
    # resume on the listener.
    try:
        await websocket.send_text(json.dumps({
            "type": "session_state",
            "data": {
                "host_id": session.host_id,
                "is_playing": session.is_playing,
                "position_ms": session.position_ms,
                "track": session.track,
            },
        }))
        # Existing peers hear that this user (re)joined.
        await MANAGER.relay_text(session_id, user.id, json.dumps({
            "type": "peer_joined", "data": {"user_id": user.id},
        }))
        # Newcomer hears about each already-present peer.
        for uid in list(session.connections.keys()):
            if uid != user.id:
                await websocket.send_text(json.dumps({
                    "type": "peer_joined", "data": {"user_id": uid},
                }))
    except Exception:
        pass

    try:
        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                break

            text = message.get("text")
            data = message.get("bytes")

            if text is not None:
                # Track last known playback state for late joiners.
                _update_state_from_control(session, text)
                to_id = _extract_to(text)
                if to_id is not None:
                    # Peer-addressed (WebRTC signaling: rtc_offer/answer/ice) →
                    # deliver to just that participant. Room-ready.
                    await MANAGER.relay_to(session_id, to_id, text)
                else:
                    # Broadcast the sync clock (play/pause/seek/meta/queue/eq)
                    # to the other participant(s).
                    await MANAGER.relay_text(session_id, user.id, text)
            elif data is not None:
                # Audio no longer flows over the socket (it's peer-to-peer via a
                # WebRTC data channel now). Relay any stray binary defensively.
                await MANAGER.relay_bytes(session_id, user.id, data)

    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        MANAGER.detach(session_id, user.id)
        current = MANAGER.get(session_id)
        if current is not None:
            if user.id == current.host_id:
                # The host's socket dropped. This is often just a network glitch
                # (WiFi blip / cell handover), so DON'T tear the session down
                # right away. Tell the listener(s) the host is reconnecting (so
                # they can pause and wait rather than see "ended"), and arm a
                # grace timer. If the host reconnects within HOST_GRACE_SECONDS
                # the timer is cancelled and playback resumes; otherwise the
                # session ends then.
                await MANAGER.relay_text(
                    session_id, user.id,
                    json.dumps({"type": "host_reconnecting", "data": {}}),
                )
                MANAGER.schedule_host_timeout(session_id)
            else:
                await MANAGER.relay_text(
                    session_id, user.id,
                    json.dumps({"type": "peer_left", "data": {"user_id": user.id}}),
                )


def _update_state_from_control(session, text: str) -> None:
    try:
        msg = json.loads(text)
    except Exception:
        return
    mtype = msg.get("type")
    if mtype in ("play", "pause", "seek"):
        pos = msg.get("position_ms")
        if isinstance(pos, int):
            session.position_ms = pos
        session.is_playing = (mtype == "play")
    elif mtype == "meta":
        track = msg.get("track")
        if isinstance(track, dict):
            session.track = track


def _extract_to(text: str) -> Optional[int]:
    """Return a control message's `to` user id, or None if it's a broadcast.

    Peer-addressed messages (WebRTC signaling — rtc_offer/rtc_answer/rtc_ice)
    carry `to`; the sync-clock/control messages don't. Kept tiny and defensive
    so a malformed frame just falls back to a broadcast rather than erroring.
    """
    try:
        to = json.loads(text).get("to")
    except Exception:
        return None
    if to is None:
        return None
    try:
        return int(to)
    except (TypeError, ValueError):
        return None
