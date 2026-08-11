# websocket_routes.py
import asyncio
import json
from typing import Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from jose import JWTError, jwt

from config import SECRET_KEY, ALGORITHM
from database import SessionLocal
from models import User, Conversation, ConversationMember
from websocket_manager import connected_users, disconnect_user, notify_user
from push import send_push_to_user, _tokens_for

router = APIRouter()

# Aluta in-app voice-call signaling message types, relayed peer-to-peer.
_CALL_SIGNALS = {
    "call_offer",     # caller → callee: SDP offer (starts ringing)
    "call_ringing",   # callee → caller: my device received it and is ringing
    "call_rejoin",    # callee → caller: I accepted from a notification, re-offer
    "call_answer",    # callee → caller: SDP answer (accepted)
    "call_ice",       # both ways: an ICE candidate
    "call_decline",   # callee → caller: rejected
    "call_end",       # either: hang up an ongoing/answered call
    "call_cancel",    # caller → callee: cancelled before it was answered
    "call_busy",      # callee → caller: already in another call
}

# Group (mesh) call per-peer negotiation messages, relayed to the `to` peer.
_GROUP_RELAY = {"group_offer", "group_answer", "group_ice"}

# In-memory registry of active group-call rooms: conversation_id -> set of the
# user ids currently in that call. In-memory is consistent with the rest of the
# WS layer (connected_users) and fine for a single replica; a multi-replica
# deploy would move this to Redis. Media is peer-to-peer (mesh) — the server
# only relays signaling here, never audio.
_group_rooms: dict[int, set[int]] = {}


def _to_int(v):
    try:
        return int(v)
    except Exception:
        return None


def _room_members_and_title(room_id: int):
    """Return (member_user_ids, title) for a conversation, for ringing + auth."""
    db = SessionLocal()
    try:
        rows = db.query(ConversationMember.user_id).filter(
            ConversationMember.conversation_id == room_id).all()
        members = [int(r[0]) for r in rows]
        conv = db.query(Conversation).filter(
            Conversation.id == room_id).first()
        title = (conv.title if conv else None) or "Group call"
        return members, title
    except Exception:
        return [], "Group call"
    finally:
        db.close()


async def _group_start(room_id: int, uid: int, caller_name: str):
    """Caller starts a group call: mark them in the room and ring every other
    member over WS + push."""
    members, title = _room_members_and_title(room_id)
    if uid not in members:
        return  # only members may start a call in their group
    _group_rooms.setdefault(room_id, set()).add(uid)
    for m in members:
        if m == uid:
            continue
        try:
            await notify_user(m, {
                "type": "group_call_incoming", "room": room_id,
                "from": uid, "caller_name": caller_name, "title": title,
            })
        except Exception:
            pass
        try:
            asyncio.create_task(asyncio.to_thread(
                send_push_to_user, m,
                {"type": "group_call", "room": str(room_id),
                 "caller_name": caller_name, "title": title}))
        except Exception:
            pass


async def _group_join(room_id: int, uid: int):
    """A member accepts: add them, tell them who's already in, and tell the
    existing participants about the newcomer so the mesh can form."""
    members, _ = _room_members_and_title(room_id)
    if uid not in members:
        return
    existing = [x for x in _group_rooms.get(room_id, set()) if x != uid]
    _group_rooms.setdefault(room_id, set()).add(uid)
    try:
        await notify_user(uid, {
            "type": "group_call_participants", "room": room_id,
            "users": [{"id": x} for x in existing],
        })
    except Exception:
        pass
    for x in existing:
        try:
            await notify_user(x, {
                "type": "group_call_peer_joined", "room": room_id,
                "user_id": uid,
            })
        except Exception:
            pass


def _group_is_active(room_id: int) -> bool:
    """True if at least one member is currently in the room's call."""
    return bool(_group_rooms.get(room_id))


async def _broadcast_group_ended(room_id: int):
    """Tell EVERY member of the conversation the call is over, so any 'call in
    progress · Join' banner clears everywhere (not just for the participants)."""
    members, _ = _room_members_and_title(room_id)
    for m in members:
        try:
            await notify_user(m, {
                "type": "group_call_ended", "room": room_id,
            })
        except Exception:
            pass


async def _group_leave(room_id: int, uid: int):
    """A participant leaves: drop them and tell the rest to close that peer.
    When the room empties, broadcast group_call_ended to ALL members."""
    room = _group_rooms.get(room_id)
    if not room or uid not in room:
        return
    room.discard(uid)
    for x in list(room):
        try:
            await notify_user(x, {
                "type": "group_call_peer_left", "room": room_id,
                "user_id": uid,
            })
        except Exception:
            pass
    if not room:
        _group_rooms.pop(room_id, None)
        # Room is empty — the call is over. Clear the Join banner for everyone.
        await _broadcast_group_ended(room_id)


async def _group_cleanup_user(uid: int):
    """Remove a disconnected user from every group call they were in."""
    for room_id in list(_group_rooms.keys()):
        if uid in _group_rooms.get(room_id, set()):
            await _group_leave(room_id, uid)


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

    # Re-deliver any "listen together" invite that arrived while this user was
    # offline. The invite is otherwise a fire-and-forget WS event, so a listener
    # who was closed when it was sent never saw it and the host waited forever.
    try:
        from live_session import MANAGER as _LIVE
        for s in _LIVE.pending_invites_for(uid):
            await notify_user(uid, {
                "type": "live_invite",
                "data": {
                    "session_id": s.session_id,
                    "host_id": s.host_id,
                    "host_username": s.host_username,
                    "track": s.track,
                },
            })
    except Exception:
        pass

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
                    # A re-offer (killed-app rejoin re-negotiation) must NOT ring
                    # again — the callee is already online and connecting. Skip
                    # the push + reachability signals; the WS relay above is all
                    # it needs. Otherwise the callee gets a fresh ringing
                    # notification mid-call.
                    if etype == "call_offer" and not data.get("reoffer"):
                        # Give the caller honest feedback about whether the
                        # friend can even be rung, instead of a silent 45s
                        # ring-out. Two facts decide it:
                        #   ws_online  — the friend has a live app socket, so the
                        #                offer we just relayed will ring in-app
                        #                (their client also sends call_ringing).
                        #   has_token  — the friend has a device push token, so a
                        #                closed/backgrounded app can still be woken
                        #                to ring.
                        ws_online = bool(connected_users.get(int(to)))
                        try:
                            has_token = len(_tokens_for(int(to))) > 0
                        except Exception:
                            has_token = False

                        if not ws_online and not has_token:
                            # No live app AND no way to push — the friend is
                            # fully offline. Tell the caller now; it never rang.
                            try:
                                await notify_user(int(user_id), {
                                    "type": "call_unreachable",
                                    "to": int(to),
                                })
                            except Exception:
                                pass
                        else:
                            if not ws_online and has_token:
                                # Their app is closed; only a push can reach them.
                                # Let the caller know we're ringing their phone
                                # (we can't confirm it actually rings).
                                try:
                                    await notify_user(int(user_id), {
                                        "type": "call_delivered",
                                        "to": int(to),
                                    })
                                except Exception:
                                    pass
                            if has_token:
                                try:
                                    asyncio.create_task(asyncio.to_thread(
                                        send_push_to_user,
                                        int(to),
                                        {
                                            # NB: 'from' is a RESERVED FCM data
                                            # key — including it makes FCM reject
                                            # the whole message with HTTP 400, so
                                            # the ringing push never rings. Use
                                            # 'caller_id' instead.
                                            "type": "call_offer",
                                            "caller_id": str(user_id),
                                            "caller_name": caller_name,
                                        },
                                    ))
                                except Exception:
                                    pass
                    elif etype in (
                        "call_cancel", "call_end",
                        "call_decline", "call_busy",
                    ):
                        # The call ended: push a dismiss so a killed/backgrounded
                        # callee's ringing notification stops instead of ringing
                        # out the full 45s window.
                        try:
                            asyncio.create_task(asyncio.to_thread(
                                send_push_to_user,
                                int(to),
                                {"type": etype},
                            ))
                        except Exception:
                            pass
            elif etype == "group_call_start":
                room_id = _to_int(data.get("room"))
                if room_id is not None:
                    await _group_start(room_id, uid, caller_name)
            elif etype == "group_call_join":
                room_id = _to_int(data.get("room"))
                if room_id is not None:
                    await _group_join(room_id, uid)
            elif etype == "group_call_leave":
                room_id = _to_int(data.get("room"))
                if room_id is not None:
                    await _group_leave(room_id, uid)
            elif etype in _GROUP_RELAY:
                # Per-peer mesh negotiation (offer/answer/ice) → relay to `to`.
                to = data.get("to")
                if to is not None:
                    payload = {k: v for k, v in data.items() if k != "to"}
                    payload["from"] = uid
                    try:
                        await notify_user(int(to), payload)
                    except Exception:
                        pass
            # (Other event types are still accepted and ignored, keeping the
            #  socket alive as a heartbeat.)

    except WebSocketDisconnect:
        disconnect_user(user_id, websocket)
        # If this was the user's last socket, drop them from any group calls so
        # the remaining participants tear down that peer connection.
        if not connected_users.get(uid):
            try:
                await _group_cleanup_user(uid)
            except Exception:
                pass
