"""
In-memory live "listen together" session manager.

A live session lets a host stream a LOCAL audio file to invited listener(s) in
real time. Audio bytes and playback-control messages are relayed through this
process purely in memory and are NEVER written to disk or the database. When the
host ends the session (or disconnects), the session is torn down and nothing is
persisted.

This is intentionally ephemeral: sessions live only in `MANAGER.sessions` for the
lifetime of the process / session.
"""
from __future__ import annotations

import asyncio
import json
from typing import Dict, List, Optional
from fastapi import WebSocket


# How long the session survives after the HOST's socket drops before we give up
# and end it for everyone. A brief network glitch (WiFi blip, cell handover)
# should NOT kill a live session — the host reconnects within this window and
# playback resumes. Only a genuinely-gone host (closed app, long outage) lets
# the timer fire and ends the session.
HOST_GRACE_SECONDS = 45


class LiveSession:
    def __init__(self, session_id: str, host_id: int, invited_ids: List[int],
                 track: dict, host_username: str = "", open: bool = False):
        self.session_id = session_id
        self.host_id = host_id
        # Shown in the invite prompt (also when re-delivering a pending invite
        # to a listener who was offline when it was first sent).
        self.host_username = host_username
        self.invited_ids: List[int] = list(invited_ids)
        # Listeners who explicitly declined — don't re-deliver the invite to them.
        self.declined_ids: set[int] = set()
        # Everyone explicitly allowed (host + invited listeners). For OPEN rooms
        # this is just the seed — any friend of the host may also join (that
        # check happens at WS-connect time against the Friend table).
        self.allowed_ids: set[int] = {host_id, *invited_ids}
        # OPEN room ("Listening Room"): not a 1:1 invite but a drop-in space the
        # host's whole circle can join. Membership = host's friends, verified on
        # connect. A 1:1 "listen together" session has open=False.
        self.open: bool = open
        # The circle we announced this room to (host's friends at open time), so
        # we can tell them "room ended" even from the host-timeout path (which
        # has no DB/request context). Set by the room-create route.
        self.notify_ids: set[int] = set()
        # Metadata only — title/duration/mime. NOT the audio itself.
        self.track: dict = track or {}
        # Live socket connections, keyed by user id.
        self.connections: Dict[int, WebSocket] = {}
        # Last known playback state, so a listener that joins slightly late can
        # be told where the host currently is.
        self.is_playing: bool = False
        self.position_ms: int = 0
        # Pending "end the session because the host never came back" timer.
        # Set when the host drops, cancelled if the host reconnects in time.
        self.close_task: Optional["asyncio.Task"] = None

    def other_connections(self, sender_id: int) -> List[WebSocket]:
        return [ws for uid, ws in self.connections.items() if uid != sender_id]

    def snapshot(self) -> dict:
        """A small, safe description of the room for discovery/announce payloads."""
        return {
            "session_id": self.session_id,
            "host_id": self.host_id,
            "host_username": self.host_username,
            "track": self.track,
            "listeners": max(0, len(self.connections) - (1 if self.host_id in self.connections else 0)),
        }


class LiveSessionManager:
    def __init__(self) -> None:
        self.sessions: Dict[str, LiveSession] = {}

    # ---- lifecycle ---------------------------------------------------------
    def create(self, session_id: str, host_id: int, invited_ids: List[int],
               track: dict, host_username: str = "",
               open: bool = False) -> LiveSession:
        session = LiveSession(session_id, host_id, invited_ids, track,
                              host_username=host_username, open=open)
        self.sessions[session_id] = session
        return session

    def open_rooms_for(self, user_id: int, friend_ids: List[int]) -> List[LiveSession]:
        """Live OPEN rooms this user can drop into: hosted by one of their
        friends, host currently connected, and the user isn't the host. Used to
        tell a friend who comes online what rooms are already live."""
        friends = set(int(f) for f in friend_ids)
        out: List[LiveSession] = []
        for s in self.sessions.values():
            if (s.open
                    and s.host_id in friends
                    and s.host_id != user_id
                    and s.host_id in s.connections):
                out.append(s)
        return out

    def pending_invites_for(self, user_id: int) -> List[LiveSession]:
        """Open invites waiting for [user_id]: they're an invited listener (not
        the host), the host IS connected, and they haven't joined yet. Used to
        re-deliver an invite to a listener who was offline when it was sent."""
        out: List[LiveSession] = []
        for s in self.sessions.values():
            if (user_id in s.allowed_ids
                    and user_id != s.host_id
                    and user_id not in s.declined_ids
                    and user_id not in s.connections
                    and s.host_id in s.connections):
                out.append(s)
        return out

    def get(self, session_id: str) -> Optional[LiveSession]:
        return self.sessions.get(session_id)

    def remove(self, session_id: str) -> None:
        self.sessions.pop(session_id, None)

    # ---- connections -------------------------------------------------------
    def attach(self, session_id: str, user_id: int, websocket: WebSocket) -> None:
        session = self.sessions.get(session_id)
        if session is not None:
            session.connections[user_id] = websocket

    def detach(self, session_id: str, user_id: int) -> None:
        session = self.sessions.get(session_id)
        if session is not None:
            session.connections.pop(user_id, None)

    def host_connected(self, session_id: str) -> bool:
        session = self.sessions.get(session_id)
        return session is not None and session.host_id in session.connections

    # ---- host reconnection grace window ------------------------------------
    def schedule_host_timeout(self, session_id: str, seconds: int = HOST_GRACE_SECONDS) -> None:
        """Arm a timer that ends the session if the host doesn't return in time.

        Called when the host's socket drops. Cancels any timer already armed so
        repeated blips just keep extending the same grace window.
        """
        session = self.sessions.get(session_id)
        if session is None:
            return
        if session.close_task is not None and not session.close_task.done():
            session.close_task.cancel()
        session.close_task = asyncio.create_task(
            self._end_if_host_absent(session_id, seconds)
        )

    def cancel_host_timeout(self, session_id: str) -> None:
        """Host came back — stop the pending end-the-session timer."""
        session = self.sessions.get(session_id)
        if session is None:
            return
        task = session.close_task
        session.close_task = None
        if task is not None and not task.done():
            task.cancel()

    async def _end_if_host_absent(self, session_id: str, seconds: int) -> None:
        try:
            await asyncio.sleep(seconds)
        except asyncio.CancelledError:
            return
        session = self.sessions.get(session_id)
        if session is None:
            return
        # Host reconnected during the grace window → nothing to do.
        if session.host_id in session.connections:
            return
        # Host never came back — end the session for the remaining listener(s).
        await self.broadcast_text(
            session_id, json.dumps({"type": "end", "reason": "host_left"})
        )
        self.announce_room_ended(session)
        self.remove(session_id)

    def announce_room_ended(self, session: "LiveSession") -> None:
        """Tell the host's circle a live OPEN room has closed, so its card can
        disappear from their friend list. No-op for 1:1 sessions. Fire-and-forget
        over the home socket; safe to call from any context."""
        if session is None or not session.open or not session.notify_ids:
            return
        try:
            from websocket_manager import safe_notify_user
        except Exception:
            return
        payload = {"type": "live_room_ended",
                   "data": {"session_id": session.session_id,
                            "host_id": session.host_id}}
        for uid in session.notify_ids:
            safe_notify_user(uid, payload)

    # ---- relaying ----------------------------------------------------------
    async def relay_text(self, session_id: str, sender_id: int, message: str) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        for ws in session.other_connections(sender_id):
            try:
                await ws.send_text(message)
            except Exception:
                pass

    async def send_to_user(self, session_id: str, target_id: int, message: str) -> bool:
        """Deliver a message to ONE participant. This is what makes rooms work:
        WebRTC signaling (rtc_offer/answer/ice) is addressed to a specific peer
        via a `to` field, so with N listeners it must go only to that peer — a
        blind broadcast would cross-wire everyone's peer connections."""
        session = self.sessions.get(session_id)
        if session is None:
            return False
        ws = session.connections.get(int(target_id))
        if ws is None:
            return False
        try:
            await ws.send_text(message)
            return True
        except Exception:
            return False

    async def relay_bytes(self, session_id: str, sender_id: int, data: bytes) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        for ws in session.other_connections(sender_id):
            try:
                await ws.send_bytes(data)
            except Exception:
                pass

    async def broadcast_text(self, session_id: str, message: str) -> None:
        session = self.sessions.get(session_id)
        if session is None:
            return
        for ws in list(session.connections.values()):
            try:
                await ws.send_text(message)
            except Exception:
                pass


# Single process-wide manager instance.
MANAGER = LiveSessionManager()
