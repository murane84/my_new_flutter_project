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
from models import User, Friend, ConversationMember, SpaceMember
from sqlalchemy.orm import Session

from auth import get_current_user
from websocket_manager import safe_notify_user
from live_session import MANAGER
from push import send_push_to_user

router = APIRouter(prefix="/live", tags=["Live Session"])


def _friend_ids(db: Session, uid: int) -> list:
    """The user's MUTUAL friends (both saved each other) — a circle room is
    announced only to them."""
    import crud
    return list(crud._get_friend_ids(db, int(uid)))


def _in_group(uid: int, cid: int) -> bool:
    """Live membership check for a GROUP jam room — re-read on every join so
    someone removed from the group can't keep dropping in."""
    db = SessionLocal()
    try:
        return db.query(ConversationMember).filter(
            ConversationMember.conversation_id == cid,
            ConversationMember.user_id == uid).first() is not None
    except Exception:
        return False
    finally:
        db.close()


def _related(db: Session, a: int, b: int) -> bool:
    """May [a] invite [b] to a private 1:1 Listen Together? Friends, or people
    who already share a chat / group / Our Space — never a stranger."""
    import crud
    if crud.are_mutual(db, a, b):
        return True
    if crud.share_a_group(db, a, b):
        return True
    spaces = {r[0] for r in db.query(SpaceMember.space_id)
              .filter(SpaceMember.user_id == a).all()}
    if spaces and db.query(SpaceMember).filter(
            SpaceMember.user_id == b,
            SpaceMember.space_id.in_(spaces)).first():
        return True
    return False


def _blocked(a: int, b: int) -> bool:
    """A block either way (own session — safe from the WebSocket handler)."""
    db = SessionLocal()
    try:
        import crud
        return crud.blocked_either(db, a, b)
    except Exception:
        return False
    finally:
        db.close()


def _are_friends(a: int, b: int) -> bool:
    """True if a and b are friends (either direction). Opens its own session so
    it's safe to call from the WebSocket handler."""
    if a == b:
        return True
    db = SessionLocal()
    try:
        import crud
        return crud.are_mutual(db, a, b)
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
    # GROUP Listen Together: open the room inside this group conversation —
    # announced to (and joinable by) its members instead of the host's friends.
    conversation_id: Optional[int] = None


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
    # Private 1:1 (DM / tune-in / Our Space): only someone you already know.
    import crud as _crud
    if _crud.blocked_either(db, current_user.id, body.receiver_id):
        raise HTTPException(status_code=404, detail="Not available")
    if not _related(db, current_user.id, body.receiver_id):
        raise HTTPException(status_code=403,
                            detail="You can only listen together with people you know")

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
            "host_id": str(current_user.id),
            "session_id": session_id,
            # So the banner can say WHICH song, not just "music".
            "track_title": str((track or {}).get("title") or "")[:120],
        })
    except Exception:
        pass

    return {"session_id": session_id, "host_id": current_user.id, "track": track}


class RestoreRequest(BaseModel):
    # The host brings its session back after a server restart (a deploy wipes
    # the in-memory sessions): same id, same people, the song that's playing.
    receiver_id: Optional[int] = None  # 1:1
    open: bool = False  # a room
    conversation_id: Optional[int] = None  # a group room
    track: TrackMeta = TrackMeta()


@router.post("/sessions/{session_id}/restore")
def restore_session(
    session_id: str,
    body: RestoreRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Re-create a session the server forgot (restart / deploy) so the host
    and everyone in it reconnect to the SAME id and carry on. Only the host
    can do it, with the same checks as creating it; nobody is re-notified —
    their apps are already reconnecting."""
    import re
    if not re.fullmatch(r"[0-9a-f]{32}", session_id or ""):
        raise HTTPException(status_code=400, detail="Bad session id")
    existing = MANAGER.get(session_id)
    if existing is not None:
        if existing.host_id != current_user.id:
            raise HTTPException(status_code=409, detail="Taken")
        return {"session_id": session_id, "restored": False}
    track = body.track.model_dump()
    if body.open or body.conversation_id is not None:
        cid = body.conversation_id
        group_ids: list = []
        if cid is not None:
            rows = (db.query(ConversationMember.user_id)
                    .filter(ConversationMember.conversation_id == cid).all())
            group_ids = [int(r[0]) for r in rows]
            if current_user.id not in group_ids:
                raise HTTPException(status_code=403,
                                    detail="Not a member of this group")
            audience = [u for u in group_ids if u != current_user.id]
        else:
            audience = _friend_ids(db, current_user.id)
        session = MANAGER.create(
            session_id, host_id=current_user.id, invited_ids=[], track=track,
            host_username=current_user.username or "", open=True)
        session.conversation_id = cid
        session.group_ids = set(group_ids)
        session.notify_ids = set(audience)
    else:
        rid = body.receiver_id
        if rid is None or rid == current_user.id:
            raise HTTPException(status_code=400, detail="Who with?")
        import crud as _crud
        if _crud.blocked_either(db, current_user.id, rid) or \
                not _related(db, current_user.id, rid):
            raise HTTPException(status_code=403, detail="Not available")
        session = MANAGER.create(
            session_id, host_id=current_user.id, invited_ids=[rid],
            track=track, host_username=current_user.username or "")
        # They were in it: no fresh invite pop-up when they come back.
        session.joined_ids.add(rid)
    session.joined_ids.add(current_user.id)
    return {"session_id": session_id, "restored": True}


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
    cid = body.conversation_id
    group_ids: list = []
    if cid is not None:
        rows = (db.query(ConversationMember.user_id)
                .filter(ConversationMember.conversation_id == cid).all())
        group_ids = [int(r[0]) for r in rows]
        if current_user.id not in group_ids:
            raise HTTPException(status_code=403,
                                detail="Not a member of this group")
        audience = [u for u in group_ids if u != current_user.id]
    else:
        audience = _friend_ids(db, current_user.id)
    session = MANAGER.create(
        session_id, host_id=current_user.id, invited_ids=[], track=track,
        host_username=current_user.username or "", open=True)
    session.conversation_id = cid
    session.group_ids = set(group_ids)
    # Remember the circle we told, so we can also announce when the room ends
    # (including from the host-timeout path, which has no request context).
    session.notify_ids = set(audience)

    payload = {
        "type": "live_room_available",
        "data": {
            "session_id": session_id,
            "host_id": current_user.id,
            "host_username": current_user.username,
            "track": track,
            "conversation_id": cid,
        },
    }
    for fid in audience:
        safe_notify_user(fid, payload)

    # GROUP jam room: every member also gets the push a 1:1 Listen Together
    # invite uses (tapping it joins). Not only the "offline" ones — a phone
    # with Aluta in the background often still holds a socket, so the in-group
    # Join bar was all it got and nobody saw it. An app in front ignores the
    # push (the Join bar shows); a member who muted the group stays quiet.
    if cid is not None:
        try:
            from models import Conversation
            conv = db.query(Conversation).filter(Conversation.id == cid).first()
            gtitle = (conv.title or "") if conv else ""
        except Exception:
            gtitle = ""
        for fid in audience:
            try:
                send_push_to_user(fid, {
                    "type": "live_invite",
                    "host_username": current_user.username or "Someone",
                    "host_id": str(current_user.id),
                    "session_id": session_id,
                    "track_title": str((track or {}).get("title") or "")[:120],
                    "conversation_id": str(cid),
                    "group_title": gtitle[:80],
                })
            except Exception:
                pass

    return {"session_id": session_id, "host_id": current_user.id,
            "track": track, "open": True, "conversation_id": cid}


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
    # A group jam is listed to CURRENT members only (the snapshot taken when
    # it opened may include someone removed since).
    rooms = [s for s in rooms if s.conversation_id is None
             or _in_group(current_user.id, s.conversation_id)]
    return {"rooms": [s.snapshot() for s in rooms]}


@router.post("/sessions/{session_id}/decline")
def decline_session(
    session_id: str,
    reason: Optional[str] = None,
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
            # "weak_net": they wanted to, but their connection was too weak.
            "reason": (reason or "")[:20] or None,
        },
    })
    return {"detail": "ok"}


async def cut_pair(a: int, b: int) -> None:
    """A block was just made between [a] and [b]: their 1:1 Listen Together
    ends, the other one is taken out of a circle room hosted by either of
    them (and can't rejoin — see the ws re-check). A GROUP jam follows the
    group's rules, so it's left alone."""
    pair = {int(a), int(b)}
    for sid, s in list(MANAGER.sessions.items()):
        if s.conversation_id is not None:
            continue
        try:
            if not s.open:
                if pair <= set(s.allowed_ids):
                    await MANAGER.broadcast_text(
                        sid, json.dumps({"type": "end", "reason": "host_ended"}))
                    MANAGER.announce_room_ended(s)
                    MANAGER.remove(sid)
            elif s.host_id in pair:
                other = next(iter(pair - {s.host_id}))
                s.allowed_ids.discard(other)
                await MANAGER.send_to_user(
                    sid, other,
                    json.dumps({"type": "end", "reason": "host_ended"}))
        except Exception:
            pass


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


def _roster_payload(session) -> dict:
    """Who is currently connected to this session — id, name, avatar, host flag —
    so every client can render the 'people dropped in' panel. Looks names up in
    its own short-lived DB session."""
    ids = list(session.connections.keys())
    # GROUP room: the members who haven't dropped in yet ("not here yet").
    group_ids = getattr(session, "group_ids", set()) or set()
    waiting_ids = [u for u in group_ids if u not in session.connections]
    people = []
    waiting = []
    if ids or waiting_ids:
        db = SessionLocal()
        try:
            rows = db.query(User).filter(
                User.id.in_(list(ids) + list(waiting_ids))).all()
            umap = {u.id: u for u in rows}
            for uid in ids:
                u = umap.get(uid)
                people.append({
                    "id": uid,
                    "username": (u.username if u else None) or "Someone",
                    "avatar_url": (u.avatar_url if u else None),
                    "is_host": uid == session.host_id,
                })
            for uid in waiting_ids:
                u = umap.get(uid)
                waiting.append({
                    "id": uid,
                    "username": (u.username if u else None) or "Someone",
                    "avatar_url": (u.avatar_url if u else None),
                })
        finally:
            db.close()
    return {
        "type": "session_roster",
        "data": {"people": people, "host_id": session.host_id,
                 "count": len(people), "waiting": waiting,
                 "open": bool(session.open),
                 "conversation_id": getattr(session, "conversation_id", None)},
    }


async def _broadcast_roster(session_id: str) -> None:
    """Send the current roster to everyone in the session. Best-effort."""
    session = MANAGER.get(session_id)
    if session is None:
        return
    try:
        await MANAGER.broadcast_text(session_id, json.dumps(_roster_payload(session)))
    except Exception:
        pass
    # An OPEN room (circle / group jam): also tell its audience the new
    # head-count, so "🎧 jam · 3" on the group row stays live for people who
    # haven't joined (same audience it was announced to — nobody else).
    if session.open and session.notify_ids:
        try:
            upd = {"type": "live_room_available", "data": session.snapshot()}
            for uid in session.notify_ids:
                safe_notify_user(uid, upd)
        except Exception:
            pass


@router.websocket("/ws/{session_id}")
async def live_session_ws(websocket: WebSocket, session_id: str, token: str = "", user_id: int = 0):
    """
    Both the host and the listener connect here with:
        /live/ws/{session_id}?token=<jwt>&user_id=<id>

    Text frames = JSON control messages (meta/play/pause/seek/eos) — relayed to
    the other participant(s). Binary frames = raw audio chunks — relayed likewise.
    """
    await websocket.accept()

    # The token arrives as the first message (not in the URL — URLs land in
    # access logs); ?token= still works for apps not yet updated.
    from ws_auth import ws_token
    user = _authenticate_ws(await ws_token(websocket, token), user_id)
    if user is None:
        await websocket.close(code=4401)  # unauthorized
        return

    session = MANAGER.get(session_id)
    if session is None:
        await websocket.close(code=4404)  # no such session
        return
    # Membership — strictly by kind (privacy):
    #  • GROUP jam room → the host + CURRENT members of that group only
    #    (re-checked live; the host's other friends are NOT let in).
    #  • circle room (open) → the host + the host's friends.
    #  • 1:1 (DM / tune-in / Our Space) → exactly the host + the invited one.
    if session.conversation_id is not None:
        allowed = (user.id == session.host_id
                   or _in_group(user.id, session.conversation_id))
    elif session.open:
        # Re-checked on every (re)join: a friend who unfriended or blocked
        # the host since dropping in can't come back.
        allowed = (user.id == session.host_id
                   or _are_friends(user.id, session.host_id))
    else:
        allowed = user.id in session.allowed_ids and (
            user.id == session.host_id
            or not _blocked(user.id, session.host_id))
    if not allowed:
        await websocket.close(code=4403)  # not allowed in this room
        return
    # Remember a circle-room drop-in so re-delivery / bookkeeping treats them
    # as a member for the rest of the session (group rooms re-check live).
    if session.open and session.conversation_id is None:
        session.allowed_ids.add(user.id)

    is_host = (user.id == session.host_id)

    MANAGER.attach(session_id, user.id, websocket)

    # If the HOST just (re)connected, cancel any pending "host never came back"
    # timer so a transient glitch doesn't end the session after the fact.
    if is_host:
        MANAGER.cancel_host_timeout(session_id)
    else:
        # A listener joined the host's session → the two listened together today.
        # Record it for the bond's streak / "days in a song" (best-effort, its
        # own short-lived DB session, idempotent per calendar day).
        try:
            from bonding import record_shared_listen
            _sldb = SessionLocal()
            try:
                record_shared_listen(
                    _sldb, session.host_id, user.id,
                    (session.track or {}).get("title"))
                # The shared song also flows into the bond's soundtrack
                # (de-duped, source=listen_together).
                try:
                    from bonding import pair_key, record_soundtrack_track
                    _tr = session.track or {}
                    if _tr.get("title"):
                        record_soundtrack_track(
                            _sldb, pair_key(session.host_id, user.id),
                            user.id, _tr.get("title"), _tr.get("artist"),
                            source="listen_together")
                except Exception:
                    pass
            finally:
                _sldb.close()
        except Exception:
            pass

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

    # Everyone gets the refreshed roster (who's now in the room).
    await _broadcast_roster(session_id)

    try:
        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                break

            text = message.get("text")
            data = message.get("bytes")

            if text is not None:
                # A screen (re)opening asks who's here — answer just them.
                if '"roster_request"' in text:
                    try:
                        await websocket.send_text(
                            json.dumps(_roster_payload(session)))
                    except Exception:
                        pass
                    continue
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
        # Pass THIS socket so a stale cleanup after a quick rejoin can't drop the
        # new connection. Only react (peer_left / host grace) when we actually
        # removed the current socket — otherwise a rejoin already replaced it.
        removed = MANAGER.detach(session_id, user.id, websocket)
        current = MANAGER.get(session_id)
        if current is not None and removed:
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
            # Refresh the roster so the remaining people see who's left.
            await _broadcast_roster(session_id)


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
    elif mtype == "position":
        pos = msg.get("position_ms")
        if isinstance(pos, int):
            session.position_ms = pos
    elif mtype in ("meta", "track_change"):
        # Keep the CURRENT song for late joiners / rejoiners (their first
        # session_state) — not the one the session started with.
        track = msg.get("track")
        if isinstance(track, dict):
            session.track = track
