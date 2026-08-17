"""
Live "listen together" session routes.

- POST /live/sessions            -> host creates a session, invites a receiver (DM)
- POST /live/sessions/{id}/end   -> host ends the session
- WS   /ws/live/{session_id}     -> host + listener(s) exchange control + audio

Audio bytes flow host -> server -> listener entirely in memory. Nothing is ever
written to disk or the database. Ending the session (or the host disconnecting)
tears everything down.
"""
import json
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
from jose import JWTError, jwt

from config import SECRET_KEY, ALGORITHM
from database import SessionLocal, get_db
from models import User, Friend
from sqlalchemy.orm import Session

from auth import get_current_user
from websocket_manager import safe_notify_user
from live_session import MANAGER
from push import send_push_to_user

router = APIRouter(prefix="/live", tags=["Live Session"])


def _friend_ids(db: Session, uid: int) -> list:
    """The user's circle (symmetric Friend rows)."""
    rows = db.query(Friend).filter(
        (Friend.user_id == uid) | (Friend.friend_id == uid)).all()
    ids = set()
    for r in rows:
        other = r.friend_id if r.user_id == uid else r.user_id
        if other != uid:
            ids.add(int(other))
    return list(ids)


def _are_friends(a: int, b: int) -> bool:
    """True if a and b are friends (either direction). Opens its own session so
    it's safe to call from the WebSocket handler."""
    if a == b:
        return True
    db = SessionLocal()
    try:
        row = db.query(Friend).filter(
            ((Friend.user_id == a) & (Friend.friend_id == b))
            | ((Friend.user_id == b) & (Friend.friend_id == a))
        ).first()
        return row is not None
    except Exception:
        return False
    finally:
        db.close()


# ------------------------------ Schemas ------------------------------
class TrackMeta(BaseModel):
    title: Optional[str] = None
    artist: Optional[str] = None
    duration_ms: Optional[int] = None
    mime: Optional[str] = "audio/mpeg"


class CreateSessionRequest(BaseModel):
    receiver_id: int
    track: TrackMeta = TrackMeta()


class CreateRoomRequest(BaseModel):
    # An open "Listening Room" — no single receiver; the host's whole circle can
    # drop in. Only the track metadata is needed to seed it.
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
    MANAGER.create(session_id, host_id=current_user.id,
                   invited_ids=[body.receiver_id], track=track,
                   host_username=current_user.username or "")

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

    # Also PUSH it — if the receiver's app is closed/backgrounded, the WS event
    # above never reaches them (and the invite would sit pending forever). The
    # push wakes their phone; on open, the reconnect re-delivery (see the
    # notification WS handler) re-sends the live_invite so the prompt appears.
    try:
        send_push_to_user(body.receiver_id, {
            "type": "live_invite",
            "host_username": current_user.username or "Someone",
            "session_id": session_id,
        })
    except Exception:
        pass

    return {"session_id": session_id, "host_id": current_user.id, "track": track}


@router.post("/rooms")
def create_room(
    body: CreateRoomRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Open a live "Listening Room": a drop-in space the host's whole circle can
    join (vs a 1:1 invite). We announce it to the host's friends over their home
    socket so their friend list can surface a "room is live" card; friends who
    come online later discover it via GET /live/rooms (or the home-socket
    reconnect re-delivery)."""
    session_id = uuid.uuid4().hex
    track = body.track.model_dump()
    friend_ids = _friend_ids(db, current_user.id)
    session = MANAGER.create(
        session_id, host_id=current_user.id, invited_ids=[], track=track,
        host_username=current_user.username or "", open=True)
    # Remember the circle we told, so we can also announce when the room ends
    # (including from the host-timeout path, which has no request context).
    session.notify_ids = set(friend_ids)

    payload = {
        "type": "live_room_available",
        "data": {
            "session_id": session_id,
            "host_id": current_user.id,
            "host_username": current_user.username,
            "track": track,
        },
    }
    for fid in friend_ids:
        safe_notify_user(fid, payload)

    return {"session_id": session_id, "host_id": current_user.id,
            "track": track, "open": True}


@router.get("/rooms")
def list_rooms(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Live open rooms this user can drop into right now (hosted by a friend,
    host connected). Used to populate the "Live Room" slot when the friend list
    loads — covers friends who were already online before the room started."""
    friend_ids = _friend_ids(db, current_user.id)
    rooms = MANAGER.open_rooms_for(current_user.id, friend_ids)
    return {"rooms": [s.snapshot() for s in rooms]}


@router.post("/sessions/{session_id}/decline")
def decline_session(
    session_id: str,
    current_user: User = Depends(get_current_user),
):
    """An invited listener declines. We stop re-delivering the invite to them
    and tell the host, who can then choose to end the session or keep waiting."""
    session = MANAGER.get(session_id)
    if not session:
        # Already gone (host ended / expired) — nothing to do.
        return {"detail": "ok"}
    if current_user.id not in session.allowed_ids or current_user.id == session.host_id:
        raise HTTPException(status_code=403, detail="Not an invited listener")
    session.declined_ids.add(current_user.id)
    # Notify the host over their notification socket so they can decide.
    safe_notify_user(session.host_id, {
        "type": "live_declined",
        "data": {
            "session_id": session_id,
            "listener_id": current_user.id,
            "listener_username": current_user.username,
        },
    })
    return {"detail": "ok"}


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
    # If this was an open Listening Room, tell the host's circle it's closed so
    # the "room is live" card disappears from their friend list.
    MANAGER.announce_room_ended(session)
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
    if session is None:
        await websocket.close(code=4404)  # no such session
        return
    # Membership: an explicitly-allowed user (host or invited listener), OR — for
    # an OPEN "Listening Room" — any friend of the host (drop-in). The friendship
    # check opens its own DB session so it's safe here.
    allowed = user.id in session.allowed_ids or (
        session.open and _are_friends(user.id, session.host_id))
    if not allowed:
        await websocket.close(code=4403)  # not allowed in this room
        return
    # Remember an open-room drop-in so re-delivery / bookkeeping treats them as
    # a member for the rest of the session.
    if session.open:
        session.allowed_ids.add(user.id)

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
                # Per-peer routing: WebRTC signaling (rtc_offer/answer/ice) is
                # addressed to ONE peer via a `to` field — with N listeners it
                # must reach only that peer, or everyone's peer connections would
                # cross-wire. Everything else (play/pause/queue/meta/…) has no
                # `to` and fans out to all others exactly as before.
                target = _relay_target(text)
                if target is not None:
                    await MANAGER.send_to_user(session_id, target, text)
                else:
                    await MANAGER.relay_text(session_id, user.id, text)
            elif data is not None:
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


def _relay_target(text: str):
    """If this message is addressed to a single peer (a `to` user id — used by
    the WebRTC signaling rtc_offer/rtc_answer/rtc_ice), return that id so it can
    be delivered only to them. Otherwise None → normal broadcast to all others."""
    try:
        msg = json.loads(text)
    except Exception:
        return None
    to = msg.get("to")
    if isinstance(to, bool):  # guard: bools are ints in Python
        return None
    if isinstance(to, int):
        return to
    if isinstance(to, str) and to.isdigit():
        return int(to)
    return None


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
